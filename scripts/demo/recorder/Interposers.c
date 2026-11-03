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
// - The main queue, on the scene's clock while it records. The recorder runs the frames from inside
//   work on the main queue, and never runs the run loop between them (its timers and SwiftUI's display
//   link would draw at the real time), so work put on the main queue would only run after the shot:
//   SwiftUI's animation completions, and the app's own `DispatchQueue.main.async` and `asyncAfter`.
//   While it's held, work the main thread puts on the main queue is kept here instead, due when it's
//   put there, or for `asyncAfter`, at the scene's time it's put off till, and the recorder runs what's
//   due as the scene's time reaches it (`scene_main_queue_run`), in the order it's due and then put
//   there. Work other threads put there still goes to the real main queue, as when they finish depends
//   on the real time.
#include "Interposers.h"
#include <Block.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
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

uint64_t scene_clock_now(void) {
    return sceneTime;
}

// MARK: - The main queue

extern void *objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void *pool);

/// Work put on the main queue while it's held: a block, copied, or a function and its argument, due at
/// a time on the scene's clock, in nanoseconds
typedef struct {
    uint64_t due;
    uint64_t order;
    void *block;
    dispatch_function_t function;
    void *context;
} Work;

static bool isHeld = false;
static Work *held = NULL;
static size_t heldCount = 0, heldCapacity = 0;
static uint64_t heldSoFar = 0;
static unsigned long workRun = 0;

void scene_main_queue_hold(void) {
    if (!timebase.denom) mach_timebase_info(&timebase);
    isHeld = true;
}

unsigned long scene_main_queue_work_run(void) {
    return workRun;
}

/// Whether work put on `queue` now is kept for the scene's clock
static bool holds(dispatch_queue_t queue) {
    return isHeld && queue == dispatch_get_main_queue() && pthread_main_np();
}

static void keep(uint64_t due, void *block, dispatch_function_t function, void *context) {
    if (heldCount == heldCapacity) {
        heldCapacity = heldCapacity ? 2 * heldCapacity : 64;
        held = realloc(held, heldCapacity * sizeof(Work));
    }
    held[heldCount++] = (Work){ due, heldSoFar++, block, function, context };
}

/// When work put off till `when` is due on the scene's clock: `when` is in the ticks of the clock that
/// mach_absolute_time gives, which is the scene's on the main thread while it records. Put off by the
/// wall clock or the clock that runs on while asleep (`when` negative), it's left to the real main queue.
static bool dueOnSceneClock(dispatch_time_t when, uint64_t *due) {
    if (when == DISPATCH_TIME_NOW) {
        *due = sceneTime;
        return true;
    }
    if ((int64_t)when < 0) return false;
    *due = (uint64_t)when * timebase.numer / timebase.denom;
    if (*due < sceneTime) *due = sceneTime;
    return true;
}

static void scene_dispatch_async(dispatch_queue_t queue, dispatch_block_t block) {
    if (!holds(queue)) return dispatch_async(queue, block);
    keep(sceneTime, Block_copy(block), NULL, NULL);
}

static void scene_dispatch_async_f(dispatch_queue_t queue, void *context, dispatch_function_t function) {
    if (!holds(queue)) return dispatch_async_f(queue, context, function);
    keep(sceneTime, NULL, function, context);
}

static void scene_dispatch_after(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    uint64_t due;
    if (!holds(queue) || !dueOnSceneClock(when, &due)) return dispatch_after(when, queue, block);
    keep(due, Block_copy(block), NULL, NULL);
}

static void scene_dispatch_after_f(dispatch_time_t when, dispatch_queue_t queue, void *context, dispatch_function_t function) {
    uint64_t due;
    if (!holds(queue) || !dueOnSceneClock(when, &due)) return dispatch_after_f(when, queue, context, function);
    keep(due, NULL, function, context);
}

void scene_main_queue_run(uint64_t until) {
    for (;;) {
        // The work due first, of what's due by then, and of that, what was put there first
        size_t next = SIZE_MAX;
        for (size_t i = 0; i < heldCount; i++) {
            if (held[i].due > until) continue;
            if (next == SIZE_MAX || held[i].due < held[next].due || (held[i].due == held[next].due && held[i].order < held[next].order)) next = i;
        }
        if (next == SIZE_MAX) return;
        Work work = held[next];
        memmove(&held[next], &held[next + 1], (heldCount - next - 1) * sizeof(Work));
        heldCount--;
        // Run at the time it's due, unless the clock's past it
        if (work.due > sceneTime) scene_clock_set(work.due);
        void *pool = objc_autoreleasePoolPush();
        if (work.block) {
            ((dispatch_block_t)work.block)();
            Block_release(work.block);
        } else {
            work.function(work.context);
        }
        objc_autoreleasePoolPop(pool);
        workRun++;
    }
}

size_t scene_main_queue_release(void) {
    isHeld = false;
    size_t left = heldCount;
    for (size_t i = 0; i < heldCount; i++) {
        if (held[i].block) {
            dispatch_async(dispatch_get_main_queue(), held[i].block);
            Block_release(held[i].block);
        } else {
            dispatch_async_f(dispatch_get_main_queue(), held[i].context, held[i].function);
        }
    }
    heldCount = 0;
    return left;
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
    { (const void *)scene_dispatch_async, (const void *)dispatch_async },
    { (const void *)scene_dispatch_async_f, (const void *)dispatch_async_f },
    { (const void *)scene_dispatch_after, (const void *)dispatch_after },
    { (const void *)scene_dispatch_after_f, (const void *)dispatch_after_f },
};

// --- AppKit's switches ----------------------------------------------------------------------------

// An NSSwitch is drawn by a SwiftUI view of AppKit's in a hosting view of its own (_NSCoreHostingView),
// whose graph SwiftUI moves on from a display link, which never fires while a shot is recorded, as the
// run loop isn't run. So it's moved on a frame at a time as the popover's is (_renderForTest): with
// SwiftUI's own ViewGraphRootValueUpdater.render(interval:updateDisplayList:targetTimestamp:), which
// SwiftUICore exports and which the hosting view conforms to, called as SwiftUI calls it (2026-11-03,
// from ViewGraphHost.displayLinkTimer): the interval in d0, whether to update the display list in w0,
// the target time (an optional Time, 9 bytes, passed by address; its last byte 1 for none) in x1, the
// hosting view's type and its conformance in x2 and x3, and the hosting view itself in x20.

#include <dlfcn.h>
#include <objc/runtime.h>

int scene_render_core_host(const void *host, double interval) {
    static const void *(*conformsToProtocol)(const void *, const void *) = NULL;
    static const void *render = NULL, *updater = NULL;
    if (!render) {
        conformsToProtocol = dlsym(RTLD_DEFAULT, "swift_conformsToProtocol");
        render = dlsym(RTLD_DEFAULT, "$s7SwiftUI25ViewGraphRootValueUpdaterPAAE6render8interval17updateDisplayList15targetTimestampySd_SbAA4TimeVSgtF");
        updater = dlsym(RTLD_DEFAULT, "$s7SwiftUI25ViewGraphRootValueUpdaterMp");
        if (!conformsToProtocol || !render || !updater) return -1;
    }
    const void *type = (const void *)object_getClass((id)host);
    const void *conformance = conformsToProtocol(type, updater);
    if (!conformance) return -2;
    uint64_t noTime[2] = {0, 1};
    register double d0 __asm__("d0") = interval;
    register uint64_t x0 __asm__("x0") = 1;
    register void *x1 __asm__("x1") = noTime;
    register const void *x2 __asm__("x2") = type;
    register const void *x3 __asm__("x3") = conformance;
    register const void *x16 __asm__("x16") = render;
    register const void *x20 __asm__("x20") = host;
    __asm__ volatile("blr x16"
                     : "+w"(d0), "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x3), "+r"(x16), "+r"(x20)
                     :
                     : "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x17", "x30",
                       "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23",
                       "v24", "v25", "v26", "v27", "v28", "v29", "v30", "v31", "memory", "cc");
    return 0;
}
