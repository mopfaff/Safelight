// What the recorder changes in how the system frameworks behave in its own process, by interposing:
// dyld sends the frameworks' calls to these functions instead. The recorder links this as a dylib of
// its own, as dyld only interposes for images other than the one doing it.
//
// - The clocks, set to the scene's while it records. The private Gestures framework, which recognises
//   the mouse events SwiftUI's sliders get on macOS 27 and moves their knob's glass with them, reads the
//   real time as it handles each one (clock_gettime_nsec_np), and other main-thread code reads it too
//   (Core Animation's transactions, AppKit's display cycle), so a knob followed a little differently
//   whenever the frames came at another pace. Once the recorder has set the scene's time, every clock
//   read on the main thread gives that, a tenth of a microsecond later for each read since, as time
//   moves on while code runs. Other threads (writing PNGs, Metal) keep the real time.
// - The popover's key appearance, kept from the window server. The window server lets one window at a
//   time look key, across every app, so telling it the popover does (SLSTransactionSetWindowHasKeyAppearance)
//   took that look from the user's own window, and clicking another window took it back from the
//   popover, which then drew its controls grey.
// - So the window server draws the popover's shadow as a window's that doesn't look key, whose inner
//   rim is fainter (0.08 against 0.1). Every window of the recorder's is given its key look's shadow
//   for both, so the window server's pictures of it have the shadow the active app's popover has.
#include "Interposers.h"
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <sys/time.h>
#include <time.h>

// MARK: - The scene's clock

extern double CACurrentMediaTime(void);

/// The scene's wall clock starts at 21:00 on 21 December 2026 in Central Europe (20:00 UTC), as the
/// screenshots' does, in seconds since 1970
static const uint64_t wallClockStart = 1797883200;

static bool isSet = false;
static uint64_t sceneTime = 0;
static uint64_t readsSinceSet = 0;
static unsigned long readings = 0;
static mach_timebase_info_data_t timebase;

void scene_clock_set(uint64_t nanoseconds) {
    if (!timebase.denom) mach_timebase_info(&timebase);
    sceneTime = nanoseconds;
    readsSinceSet = 0;
    isSet = true;
}

unsigned long scene_clock_readings(void) {
    return readings;
}

/// The scene's time for a read on the main thread, in nanoseconds, or false for the real time
static bool sceneNow(uint64_t *nanoseconds) {
    if (!isSet || !pthread_main_np()) return false;
    readings++;
    *nanoseconds = sceneTime + 100 * readsSinceSet++;
    return true;
}

static uint64_t scene_mach_absolute_time(void) {
    uint64_t now;
    return sceneNow(&now) ? now * timebase.denom / timebase.numer : mach_absolute_time();
}

static uint64_t scene_mach_continuous_time(void) {
    uint64_t now;
    return sceneNow(&now) ? now * timebase.denom / timebase.numer : mach_continuous_time();
}

static uint64_t scene_mach_approximate_time(void) {
    uint64_t now;
    return sceneNow(&now) ? now * timebase.denom / timebase.numer : mach_approximate_time();
}

static uint64_t scene_clock_gettime_nsec_np(clockid_t clock) {
    uint64_t now;
    if (!sceneNow(&now)) return clock_gettime_nsec_np(clock);
    return clock == CLOCK_REALTIME ? wallClockStart * 1000000000 + now : now;
}

static int scene_clock_gettime(clockid_t clock, struct timespec *time) {
    uint64_t now;
    if (!time || !sceneNow(&now)) return clock_gettime(clock, time);
    if (clock == CLOCK_REALTIME) now += wallClockStart * 1000000000;
    time->tv_sec = (time_t)(now / 1000000000);
    time->tv_nsec = (long)(now % 1000000000);
    return 0;
}

static int scene_gettimeofday(struct timeval *time, void *zone) {
    uint64_t now;
    if (!time || !sceneNow(&now)) return gettimeofday(time, zone);
    time->tv_sec = (time_t)(wallClockStart + now / 1000000000);
    time->tv_usec = (suseconds_t)(now % 1000000000 / 1000);
    return 0;
}

static double scene_CACurrentMediaTime(void) {
    uint64_t now;
    return sceneNow(&now) ? now / 1e9 : CACurrentMediaTime();
}

static CFAbsoluteTime scene_CFAbsoluteTimeGetCurrent(void) {
    uint64_t now;
    return sceneNow(&now) ? wallClockStart - kCFAbsoluteTimeIntervalSince1970 + now / 1e9 : CFAbsoluteTimeGetCurrent();
}

// MARK: - Key appearance

/// SkyLight's, which isn't in the SDK: make-demo.sh links with `-undefined dynamic_lookup`, and dyld
/// finds it in SkyLight, which AppKit loads
extern int SLSTransactionSetWindowHasKeyAppearance(void *transaction, uint32_t window, bool hasKeyAppearance);

static unsigned long keyAppearancesKept = 0;

unsigned long key_appearances_kept(void) {
    return keyAppearancesKept;
}

static int keep_key_appearance(void *transaction, uint32_t window, bool hasKeyAppearance) {
    keyAppearancesKept++;
    return 0;
}

// MARK: - Shadows

extern int SLSTransactionSetWindowShadowProperties(void *transaction, uint32_t window, CFDictionaryRef properties);

static unsigned long activeShadowsGiven = 0;

unsigned long active_shadows_given(void) {
    return activeShadowsGiven;
}

/// Each of the shadow's properties for a window that doesn't look key (…Inactive, or …Inctive as
/// AppKit spells one) set to the one for a window that does (…Active)
static int give_active_shadow(void *transaction, uint32_t window, CFDictionaryRef properties) {
    if (!properties) return SLSTransactionSetWindowShadowProperties(transaction, window, properties);
    CFMutableDictionaryRef active = CFDictionaryCreateMutableCopy(NULL, 0, properties);
    CFIndex count = CFDictionaryGetCount(properties);
    const void **keys = malloc(sizeof(void *) * count);
    CFDictionaryGetKeysAndValues(properties, keys, NULL);
    bool changed = false;
    for (CFIndex i = 0; i < count; i++) {
        CFStringRef key = keys[i];
        if (CFGetTypeID(key) != CFStringGetTypeID()) continue;
        CFStringRef suffix = CFStringHasSuffix(key, CFSTR("Inactive")) ? CFSTR("Inactive") : CFStringHasSuffix(key, CFSTR("Inctive")) ? CFSTR("Inctive") : NULL;
        if (!suffix) continue;
        CFStringRef stem = CFStringCreateWithSubstring(NULL, key, CFRangeMake(0, CFStringGetLength(key) - CFStringGetLength(suffix)));
        CFStringRef activeKey = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@Active"), stem);
        const void *value = CFDictionaryGetValue(properties, activeKey);
        if (value) {
            CFDictionarySetValue(active, key, value);
            changed = true;
        }
        CFRelease(activeKey);
        CFRelease(stem);
    }
    free(keys);
    if (changed) activeShadowsGiven++;
    int result = SLSTransactionSetWindowShadowProperties(transaction, window, active);
    CFRelease(active);
    return result;
}

__attribute__((used, section("__DATA,__interpose"))) static const struct { const void *replacement, *original; } interposers[] = {
    { (const void *)scene_mach_absolute_time, (const void *)mach_absolute_time },
    { (const void *)scene_mach_continuous_time, (const void *)mach_continuous_time },
    { (const void *)scene_mach_approximate_time, (const void *)mach_approximate_time },
    { (const void *)scene_clock_gettime_nsec_np, (const void *)clock_gettime_nsec_np },
    { (const void *)scene_clock_gettime, (const void *)clock_gettime },
    { (const void *)scene_gettimeofday, (const void *)gettimeofday },
    { (const void *)scene_CACurrentMediaTime, (const void *)CACurrentMediaTime },
    { (const void *)scene_CFAbsoluteTimeGetCurrent, (const void *)CFAbsoluteTimeGetCurrent },
    { (const void *)keep_key_appearance, (const void *)SLSTransactionSetWindowHasKeyAppearance },
    { (const void *)give_active_shadow, (const void *)SLSTransactionSetWindowShadowProperties },
};
