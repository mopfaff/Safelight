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
    /// The Mac's settings as the shot begins, which Safelight reads as it opens
    var settings: Settings
    /// Where the pointer is to begin with, or nowhere (no pointer is drawn) if left out
    var pointer: Place?
    var actions: [Action] = []

    private enum Keys: String, CodingKey { case about, fps, duration, appearance, accentColor, language, locale, canvas, desktop, settings, pointer, actions }

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
        settings = try keys.decode(Settings.self, forKey: .settings)
        pointer = try keys.decodeIfPresent(Place.self, forKey: .pointer)
        actions = try keys.decodeIfPresent([Action].self, forKey: .actions) ?? actions
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
    /// be at `value`, or the middle of a button, by its name as VoiceOver reads it (`{"button": "Dark"}`)
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
