#include <stdint.h>

/// From now on, every clock read on the main thread gives this time, in nanoseconds of the clock NSEvent
/// timestamps are in (CLOCK_UPTIME_RAW), a little later for each read
void scene_clock_set(uint64_t nanoseconds);

/// How many clock reads on the main thread have given the scene's time
unsigned long scene_clock_readings(void);

/// How many times AppKit would have told the window server a window has key appearance, or no longer has
unsigned long key_appearances_kept(void);
