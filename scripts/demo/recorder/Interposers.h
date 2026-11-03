#include <stddef.h>
#include <stdint.h>

/// From now on, every clock read on the main thread gives this time, in nanoseconds of the clock NSEvent
/// timestamps are in (CLOCK_UPTIME_RAW), a little later for each read
void scene_clock_set(uint64_t nanoseconds);

/// How many clock reads on the main thread have given the scene's time
unsigned long scene_clock_readings(void);

/// The scene's time as last set, in nanoseconds
uint64_t scene_clock_now(void);

/// From now on, work the main thread puts on the main queue is kept for the scene's clock
void scene_main_queue_hold(void);

/// Runs the work kept from the main queue that's due by `until` on the scene's clock, in nanoseconds,
/// in the order it's due, and then put there, including any that work puts there, with the clock at
/// the time each is due
void scene_main_queue_run(uint64_t until);

/// How much work kept from the main queue has run
unsigned long scene_main_queue_work_run(void);

/// Stops keeping the main queue's work, and puts what's kept back on it, to run once the run loop does;
/// how much that was
size_t scene_main_queue_release(void);

/// How many times AppKit would have told the window server a window has key appearance, or no longer has
unsigned long key_appearances_kept(void);

/// How many times AppKit gave a window its shadow, with its key look's rims for when it doesn't look key
unsigned long active_shadows_given(void);
