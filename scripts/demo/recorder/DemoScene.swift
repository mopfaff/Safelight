import Foundation

/// A demo shot as its scene file describes it (scripts/demo/scenes/*.json): what's on screen, the
/// settings the Mac has to begin with, and what the pointer does when. Times are in seconds from the
/// first frame; places are in points, from the top left of the canvas.
struct DemoScene: Decodable {
    /// What the shot shows, for whoever reads the file
    var about: String?
    var fps: Int = 60
    /// How long the shot is
    var duration: Double
    /// "dark" or "light"
    var appearance: String = "dark"
    /// macOS's accent colour (graphite, red, orange, yellow, green, blue, purple or pink), the language
    /// and the region's format for times. scripts/make-demo.sh passes them to the recorder as it opens,
    /// as only then does AppKit read them.
    var accentColor = "blue"
    var language = "en-US"
    var locale = "en_GB"
    /// The size of each frame, in points (drawn at twice that in pixels), and where the popover's
    /// window is on it. Left out, it's the popover's window.
    var canvas: Canvas?
    /// Whether the popover is shown on the desktop, open under Safelight's icon in the menu bar
    /// (Desktop.swift), rather than on the canvas: the canvas is then its surroundings there, and the
    /// whole desktop is written beside the frames, for scripts/demo/compose.py to put them on
    var desktop = false
    /// Whether the Mac's other displays are drawn as well, each with its own desktop, for compose.py to
    /// show them beside the popover's as they're arranged (for a scene on the desktop)
    var otherDisplays = false
    /// The Mac's settings as the shot begins, which Safelight reads as it opens
    var settings: Settings
    /// Where the pointer is to begin with, or nowhere (no pointer is drawn) if left out
    var pointer: Place?
    var actions: [Action] = []
    /// The Schedule's keyframes, with the Schedule switch on as the shot begins, so Safelight sets the
    /// Mac from them as the time of day moves on (`clock`), or off until the pointer clicks it on, if it
    /// does (`{"click": {"button": "Schedule"}}`); left out, the Schedule is off and its own
    var schedule: [Keyframe]?
    /// The time of day through the shot, which every clock on the main thread gives, the wall clock and
    /// the one the main queue and animations run on (Interposers.c), so time can run faster than it does
    /// in the shot; left out, it runs as the shot does, from 21:16:40, or from the scene's `time`. The
    /// pointer's actions come only while it runs as the shot does, as a press lasts as long on both
    var clock: [ClockKey]?
    /// The time of day the shot begins at, a whole minute ("17:15"), for a scene without a clock of its
    /// own: the menu bar's clock says it all through the shot, which is shorter than a minute, and the
    /// wall clock runs from it as the shot does. Left out, the menu bar's clock says 21:00, as the
    /// screenshots' does.
    var time: String?

    private enum Keys: String, CodingKey { case about, fps, duration, appearance, accentColor, language, locale, canvas, desktop, otherDisplays, settings, pointer, actions, schedule, clock, time }

    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: Keys.self)
        about = try keys.decodeIfPresent(String.self, forKey: .about)
        fps = try keys.decodeIfPresent(Int.self, forKey: .fps) ?? fps
        duration = try keys.decode(Double.self, forKey: .duration)
        appearance = try keys.decodeIfPresent(String.self, forKey: .appearance) ?? appearance
        accentColor = try keys.decodeIfPresent(String.self, forKey: .accentColor) ?? accentColor
        language = try keys.decodeIfPresent(String.self, forKey: .language) ?? language
        locale = try keys.decodeIfPresent(String.self, forKey: .locale) ?? locale
        canvas = try keys.decodeIfPresent(Canvas.self, forKey: .canvas)
        desktop = try keys.decodeIfPresent(Bool.self, forKey: .desktop) ?? desktop
        otherDisplays = try keys.decodeIfPresent(Bool.self, forKey: .otherDisplays) ?? otherDisplays
        settings = try keys.decode(Settings.self, forKey: .settings)
        pointer = try keys.decodeIfPresent(Place.self, forKey: .pointer)
        actions = try keys.decodeIfPresent([Action].self, forKey: .actions) ?? actions
        schedule = try keys.decodeIfPresent([Keyframe].self, forKey: .schedule)
        clock = try keys.decodeIfPresent([ClockKey].self, forKey: .clock)
        if let clock {
            guard clock.first?.at == 0, let last = clock.last, last.at >= duration, zip(clock, clock.dropFirst()).allSatisfy({ $0.at < $1.at }) else {
                throw DecodingError.dataCorruptedError(forKey: .clock, in: keys, debugDescription: "The clock's keys go from 0 to the shot's end, one after another")
            }
            guard clock[0].seconds == clock[0].seconds.rounded() else {
                throw DecodingError.dataCorruptedError(forKey: .clock, in: keys, debugDescription: "The clock starts on a whole second")
            }
            // The pointer's events are timed by the scene's clock, as everything the app does is, and a
            // press lasts as long as the action does in the shot: so the two run in step meanwhile
            for action in actions where !clockKeepsTime(from: action.at, to: action.end) {
                throw DecodingError.dataCorruptedError(forKey: .clock, in: keys, debugDescription: "The pointer's action at \(action.at) s comes while the clock runs faster or slower than the shot: give the clock keys as far apart in the time of day as in the shot round it, with no easing")
            }
        } else if schedule != nil {
            throw DecodingError.dataCorruptedError(forKey: .schedule, in: keys, debugDescription: "A shot with a schedule has a clock of its own, for the time of day the Schedule follows")
        }
        time = try keys.decodeIfPresent(String.self, forKey: .time)
        if let time {
            guard clock == nil else {
                throw DecodingError.dataCorruptedError(forKey: .time, in: keys, debugDescription: "A shot with a clock of its own begins at its first key's time, not at a time of its own")
            }
            let seconds = try ClockKey.secondsOfDay(time)
            guard seconds.truncatingRemainder(dividingBy: 60) == 0, duration < 60 else {
                throw DecodingError.dataCorruptedError(forKey: .time, in: keys, debugDescription: "A shot's time is a whole minute, \(time) isn't, and the shot is shorter than a minute, as the menu bar's clock says that minute all through it: a longer one has a clock of its own")
            }
        }
    }

    /// The time of day at the first frame, in seconds after midnight: the clock's first key's, or the
    /// scene's `time`; neither, and the scene has no time of day of its own
    var startOfDay: Double? {
        if let first = clock?.first { return first.seconds }
        return time.flatMap { try? ClockKey.secondsOfDay($0) }
    }

    /// Whether the scene's clock runs in step with the shot from `start` to `end`, in seconds of the shot:
    /// every pair of keys either side of any of that time as far apart in the time of day as in the shot,
    /// with nothing easing between them. Without a clock of its own, it always does.
    func clockKeepsTime(from start: Double, to end: Double) -> Bool {
        guard let clock else { return true }
        for (earlier, later) in zip(clock, clock.dropFirst()) where later.at > start && earlier.at < end {
            var seconds = later.seconds - earlier.seconds
            if seconds < 0 { seconds += 86400 }
            guard later.easing == .linear, abs(seconds - (later.at - earlier.at)) < 1e-9 else { return false }
        }
        return true
    }

    /// A keyframe of the Schedule, as its row in the Schedule window has it: the time of day it's
    /// reached ("19:30"), the Color filters switch, Intensity (0.25...1), Tint (degrees), Brightness
    /// and Appearance ("light" or "dark")
    struct Keyframe: Decodable {
        var time: String
        var colorFilter: Bool
        var intensity: Double
        var tint: Double
        var brightness: Double
        var appearance: String

        /// Minutes after midnight
        func minute() throws -> Int {
            let seconds = try ClockKey.secondsOfDay(time)
            guard seconds.truncatingRemainder(dividingBy: 60) == 0, seconds < 86400 else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "A keyframe's time is a minute of the day, not \(time)"))
            }
            return Int(seconds / 60)
        }
    }

    /// A time of day the clock reads `at` a time in the shot ("20:30", "20:30:03" or "20:30:03.5", on 21
    /// December 2026, as the menu bar's clock has it in every shot, in the Mac's time zone; a time
    /// earlier than the key before's is the next day's). From the key before, it gets there along
    /// `easing`'s curve, linear unless given, so the clock runs as fast as the time between them over
    /// the shot's: in step with the shot where they're as far apart, faster where they're further.
    struct ClockKey: Decodable {
        var at: Double
        var time: String
        var easing: Easing = .linear
        /// Seconds after the midnight that starts the scene's day
        let seconds: Double

        private enum Keys: String, CodingKey { case at, time, easing }

        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: Keys.self)
            at = try keys.decode(Double.self, forKey: .at)
            time = try keys.decode(String.self, forKey: .time)
            easing = try keys.decodeIfPresent(Easing.self, forKey: .easing) ?? easing
            seconds = try Self.secondsOfDay(time)
        }

        /// "HH:MM", "HH:MM:SS" or "HH:MM:SS.s…" as seconds after midnight
        static func secondsOfDay(_ time: String) throws -> Double {
            let parts = time.split(separator: ":").map(String.init)
            guard (2...3).contains(parts.count), let hours = Int(parts[0]), let minutes = Int(parts[1]), (0..<24).contains(hours), (0..<60).contains(minutes) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "\(time) isn't a time of day, HH:MM or HH:MM:SS"))
            }
            let seconds = parts.count == 3 ? Double(parts[2]) : 0
            guard let seconds, (0..<60).contains(seconds) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "\(time) isn't a time of day, HH:MM or HH:MM:SS"))
            }
            return Double(hours * 3600 + minutes * 60) + seconds
        }
    }

    /// The scene's day: 21 December 2026, as the menu bar's clock has it in every shot, at midnight in
    /// the Mac's time zone, in seconds since 1970
    static let day: Double = {
        guard let midnight = DateComponents(calendar: Calendar.current, year: 2026, month: 12, day: 21).date else { fatalError("There's no 21 December 2026") }
        return midnight.timeIntervalSince1970
    }()

    /// How far the clock has run `time` into the shot, in seconds from its first frame, with a clock of
    /// its own: from the first key's time of day to the time it reads then. Without, the shot's time.
    func clockTime(at time: Double) -> Double {
        guard let clock else { return time }
        // Each key's time of day, a day later for one that's earlier than the key before's
        var times: [Double] = []
        for key in clock {
            var seconds = key.seconds
            while let last = times.last, seconds < last { seconds += 86400 }
            times.append(seconds)
        }
        guard let later = clock.indices.first(where: { clock[$0].at > time }) else { return times[times.count - 1] - times[0] }
        if later == 0 { return 0 }
        let (from, to) = (clock[later - 1], clock[later])
        let progress = to.easing((time - from.at) / (to.at - from.at))
        return times[later - 1] + (times[later] - times[later - 1]) * progress - times[0]
    }

    struct Canvas: Decodable {
        var width: Double
        var height: Double
        /// The top left of the popover's window
        var popover: [Double] = [0, 0]
        /// A picture behind the popover, the size of the canvas, which its glass shows through: the
        /// desktop. Left out, the canvas is see-through.
        var backdrop: String?

        private enum Keys: String, CodingKey { case width, height, popover, backdrop }

        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: Keys.self)
            width = try keys.decode(Double.self, forKey: .width)
            height = try keys.decode(Double.self, forKey: .height)
            popover = try keys.decodeIfPresent([Double].self, forKey: .popover) ?? popover
            backdrop = try keys.decodeIfPresent(String.self, forKey: .backdrop)
        }
    }

    struct Settings: Decodable {
        var colorFilter = false
        /// Degrees round the colour wheel, 0 for red, as the Tint slider has it
        var tint: Double = 0
        /// Color Tint's intensity, 0.25 (Low) to 1 (High), as macOS stores it
        var intensity: Double = 1
        /// Every display's brightness, 0 to 1
        var brightness: Double = 1
        /// The wallpaper: a file whose pictures for Light and Dark the desktop and the Wallpaper row show,
        /// or `{"light": file, "dark": file}`, one file's picture for Light and another's for Dark, put
        /// in one wallpaper as Safelight's Wallpaper row makes it when each is chosen
        var wallpaper = Wallpaper.file("/System/Library/Desktop Pictures/Sonoma.heic")

        private enum Keys: String, CodingKey { case colorFilter, tint, intensity, brightness, wallpaper }

        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: Keys.self)
            colorFilter = try keys.decodeIfPresent(Bool.self, forKey: .colorFilter) ?? colorFilter
            tint = try keys.decodeIfPresent(Double.self, forKey: .tint) ?? tint
            intensity = try keys.decodeIfPresent(Double.self, forKey: .intensity) ?? intensity
            brightness = try keys.decodeIfPresent(Double.self, forKey: .brightness) ?? brightness
            wallpaper = try keys.decodeIfPresent(Wallpaper.self, forKey: .wallpaper) ?? wallpaper
        }
    }

    enum Wallpaper: Decodable {
        case file(String)
        case pair(light: String, dark: String)

        private enum Keys: String, CodingKey { case light, dark }

        init(from decoder: Decoder) throws {
            if let file = try? decoder.singleValueContainer().decode(String.self) {
                self = .file(file)
            } else {
                let keys = try decoder.container(keyedBy: Keys.self)
                self = .pair(light: try keys.decode(String.self, forKey: .light), dark: try keys.decode(String.self, forKey: .dark))
            }
        }
    }

    /// A place for the pointer: a point on the canvas, a slider's knob, where it is or where it would
    /// be at `value`, or the middle of a button, by its name as VoiceOver reads it (`{"button": "Dark"}`,
    /// or a switch, `{"button": "Adjust independently"}`)
    enum Place: Decodable {
        case point(x: Double, y: Double)
        case knob(control: String, value: Double?)
        case button(name: String)

        private enum Keys: String, CodingKey { case control, value, button }

        init(from decoder: Decoder) throws {
            if var point = try? decoder.unkeyedContainer() {
                self = .point(x: try point.decode(Double.self), y: try point.decode(Double.self))
            } else {
                let keys = try decoder.container(keyedBy: Keys.self)
                if let button = try keys.decodeIfPresent(String.self, forKey: .button) {
                    self = .button(name: button)
                } else {
                    self = .knob(control: try keys.decode(String.self, forKey: .control), value: try keys.decodeIfPresent(Double.self, forKey: .value))
                }
            }
        }
    }

    /// Something the pointer does, from `at` for `duration`, along the `easing` curve:
    /// - `move`: moves to that `Place`
    /// - `drag`: presses where it is, which must be on that control's knob, moves the knob to the value
    ///   `to`, and lets go. `from`, if given, is the value the control must have to begin with.
    /// - `click`: presses where it is, which must be on that `Place` (inside a button), and lets go
    ///   `duration` later, without moving
    struct Action: Decodable {
        var at: Double
        var duration: Double = 0
        var easing: Easing = .easeInOut
        var move: Place?
        var drag: String?
        var click: Place?
        var from: Double?
        var to: Double?

        private enum Keys: String, CodingKey { case at, duration, easing, move, drag, click, from, to }

        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: Keys.self)
            at = try keys.decode(Double.self, forKey: .at)
            duration = try keys.decodeIfPresent(Double.self, forKey: .duration) ?? duration
            easing = try keys.decodeIfPresent(Easing.self, forKey: .easing) ?? easing
            move = try keys.decodeIfPresent(Place.self, forKey: .move)
            drag = try keys.decodeIfPresent(String.self, forKey: .drag)
            click = try keys.decodeIfPresent(Place.self, forKey: .click)
            from = try keys.decodeIfPresent(Double.self, forKey: .from)
            to = try keys.decodeIfPresent(Double.self, forKey: .to)
        }

        var end: Double { at + duration }
    }

    /// Whether the pointer clicks the button or switch `name` at some point
    func clicks(_ name: String) -> Bool {
        actions.contains { action in
            if case let .button(clicked)? = action.click { return clicked == name }
            return false
        }
    }

    /// Core Animation's timing curves, by the names it gives them
    enum Easing: String, Decodable {
        case linear, easeIn, easeOut, easeInOut

        /// How far along the curve is `progress` of the way through its time
        func callAsFunction(_ progress: Double) -> Double {
            let t = min(max(progress, 0), 1)
            switch self {
            case .linear: return t
            case .easeIn: return Self.bezier(0.42, 0, 1, 1, t)
            case .easeOut: return Self.bezier(0, 0, 0.58, 1, t)
            case .easeInOut: return Self.bezier(0.42, 0, 0.58, 1, t)
            }
        }

        /// The cubic Bézier from (0, 0) to (1, 1) with these control points, at time `x`: its x solved
        /// for by bisection, which always gives the same answer
        private static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
            func point(_ a: Double, _ b: Double, _ s: Double) -> Double {
                3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s
            }
            var (low, high) = (0.0, 1.0)
            for _ in 0..<60 {
                let middle = (low + high) / 2
                if point(x1, x2, middle) < x { low = middle } else { high = middle }
            }
            return point(y1, y2, (low + high) / 2)
        }
    }

    /// AppKit's number for each accent colour, `AppleAccentColor`
    static let accentColors = ["graphite": -1, "red": 0, "orange": 1, "yellow": 2, "green": 3, "blue": 4, "purple": 5, "pink": 6]

    static func load(_ url: URL) throws -> DemoScene {
        try JSONDecoder().decode(DemoScene.self, from: Data(contentsOf: url))
    }
}
