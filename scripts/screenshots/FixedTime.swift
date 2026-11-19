import SwiftUI

/// The time of day it always is: 21:00, unless the demo recorder's scene begins at another
/// (scripts/demo/recorder/, a scene's "time")
enum FixedTime {
    static var hour = 21
    static var minute = 0
}

/// Stands in for SwiftUI's in the screenshot app's copy of Safelight.swift, as NoSystemChanges.swift's
/// functions do for the system's: it's always 21:00, so the Schedule's line at the current time is
/// where the popover's evening settings are, and the screenshots only change when the app does.
struct TimelineView<Schedule: TimelineSchedule, Content: View>: View {
    private let content: (FixedTimelineContext) -> Content

    init(_ schedule: Schedule, @ViewBuilder content: @escaping (FixedTimelineContext) -> Content) {
        self.content = content
    }

    var body: some View {
        content(FixedTimelineContext(date: Calendar.current.date(bySettingHour: FixedTime.hour, minute: FixedTime.minute, second: 0, of: Date()) ?? Date()))
    }
}

/// What the content of a `TimelineView` is given. Not nested in it, which would leave the type of its
/// content to be worked out from itself.
struct FixedTimelineContext {
    let date: Date
}
