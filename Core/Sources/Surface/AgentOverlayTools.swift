import Foundation

// Titles, chapters, marks, hidden regions and the camera's place, as the agent changes them.
// **One picture convention for all of them**: x from the left and y from the TOP, 0…1 of the
// frame. The app's types disagree — a title's y runs up from the bottom, a hidden region's down
// from the top — and an agent handed both would place half of everything upside down. The app
// converts, once, where it performs the request.

/// What a title is, or what to change about one. `nil` leaves a field as it is, or takes the
/// default when adding.
public struct TitleFields: Equatable, Sendable {
    public var text: String?
    public var startNanos: Int64?
    public var seconds: Double?
    public var x: Double?
    public var y: Double?
    public var size: Double?
    public var bold: Bool?
    public var color: String?

    public init(text: String? = nil, startNanos: Int64? = nil, seconds: Double? = nil, x: Double? = nil,
                y: Double? = nil, size: Double? = nil, bold: Bool? = nil, color: String? = nil) {
        self.text = text
        self.startNanos = startNanos
        self.seconds = seconds
        self.x = x
        self.y = y
        self.size = size
        self.bold = bold
        self.color = color
    }
}

/// A mark drawn on the picture: an arrow, a line, a box, an ellipse or a callout.
public struct MarkFields: Equatable, Sendable {
    public var shape: String
    public var fromX: Double, fromY: Double, toX: Double, toY: Double
    public var startNanos: Int64
    public var seconds: Double
    public var text: String?
    /// A picture's name, from `import_image` or the project's pictures, for the `image` shape.
    public var picture: String?

    public init(shape: String, fromX: Double, fromY: Double, toX: Double, toY: Double,
                startNanos: Int64, seconds: Double, text: String? = nil, picture: String? = nil) {
        self.picture = picture
        self.shape = shape
        self.fromX = fromX
        self.fromY = fromY
        self.toX = toX
        self.toY = toY
        self.startNanos = startNanos
        self.seconds = seconds
        self.text = text
    }
}

/// A region of the recording hidden for a span.
public struct HiddenRegion: Equatable, Sendable {
    public var startNanos: Int64, endNanos: Int64
    public var x: Double, y: Double, width: Double, height: Double
    public var oval: Bool

    public init(startNanos: Int64, endNanos: Int64, x: Double, y: Double, width: Double, height: Double,
                oval: Bool = false) {
        self.startNanos = startNanos
        self.endNanos = endNanos
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.oval = oval
    }
}

/// A change to where and how the camera sits.
public struct CameraFields: Equatable, Sendable {
    public var shape: String?
    public var size: Double?
    public var x: Double?
    public var y: Double?
    public var hidden: Bool?
    public var mirrored: Bool?

    public init(shape: String? = nil, size: Double? = nil, x: Double? = nil, y: Double? = nil,
                hidden: Bool? = nil, mirrored: Bool? = nil) {
        self.shape = shape
        self.size = size
        self.x = x
        self.y = y
        self.hidden = hidden
        self.mirrored = mirrored
    }
}

/// One change to the things drawn over the recording.
public enum OverlayEdit: Equatable, Sendable {
    case addTitle(TitleFields)
    case editTitle(id: Int, TitleFields)
    case removeTitle(id: Int)
    case addChapter(atNanos: Int64, title: String)
    case renameChapter(id: Int, title: String)
    case removeChapter(id: Int)
    case addMark(MarkFields)
    case removeMark(id: Int)
    case hideRegion(HiddenRegion)
    case removeHiddenRegion(id: Int)
    case setCamera(CameraFields)
}

extension AgentTools {
    public static let overlays = "overlays"
    public static let markShapes = ["arrow", "line", "rectangle", "ellipse", "callout", "image"]
    public static let cameraShapes = ["circle", "rounded", "square"]
    /// Longest title: two lines of a headline.
    public static let longestTitle = 120

    private static func opt(_ name: String, _ kind: ToolParameter.Kind, _ description: String) -> ToolParameter {
        ToolParameter(name, kind, description: description, required: false)
    }
    private static func req(_ name: String, _ kind: ToolParameter.Kind, _ description: String) -> ToolParameter {
        ToolParameter(name, kind, description: description)
    }
    private static let unit = ToolParameter.Kind.number(minimum: 0, maximum: 1)
    private static let at = ToolParameter.Kind.integer(minimum: 0)
    private static func id(_ what: String) -> ToolParameter {
        ToolParameter("id", .integer(minimum: 0), description: "The \(what)'s id, from overlays.",
                      invalid: "`id` must be a \(what)'s id from overlays.")
    }
    private static let titleFields: [ToolParameter] = [
        opt("startNanos", at, "When it appears, nanoseconds on the recording's clock."),
        opt("seconds", .number(minimum: 0.5, maximum: 30), "How long it stays."),
        opt("x", unit, "Across, 0 at the left; the title is centred on it."),
        opt("y", unit, "Down, 0 at the top."),
        opt("size", .number(minimum: 0.02, maximum: 0.25), "Type size, as a fraction of the frame's height."),
        opt("bold", .boolean, "Bold."),
        opt("color", .color, "Its colour, #RRGGBB."),
    ]

    static let overlaySpecs: [ToolSpec] = [
        ToolSpec(overlays, title: "Titles, chapters, marks, hidden regions and the camera",
                 description: "Everything drawn over the recording, with ids: titles, chapters, marks (arrows, boxes, callouts), hidden regions, and the camera's shape and place. Positions are 0…1 of the frame, x from the left and y from the top.",
                 readOnly: true),
        ToolSpec("add_title", title: "Add a title", description: "Put a title on the picture for a span, as one undo step.",
                 readOnly: false,
                 parameters: [req("text", .string(longest: longestTitle, allowsEmpty: false), "The words.")] + titleFields + [.reason]),
        ToolSpec("edit_title", title: "Change a title", description: "Change any of a title's fields, as one undo step; fields not given stay.",
                 readOnly: false,
                 parameters: [id("title"), opt("text", .string(longest: longestTitle, allowsEmpty: false), "The words.")] + titleFields + [.reason]),
        ToolSpec("remove_title", title: "Remove a title", description: "Remove a title, as one undo step.",
                 readOnly: false, parameters: [id("title"), .reason]),
        ToolSpec("add_chapter", title: "Add a chapter", description: "Start a chapter at a moment, as one undo step. Chapters are written into an exported MP4 or MOV.",
                 readOnly: false, parameters: [req("atNanos", at, "Where it starts, nanoseconds on the recording's clock."),
                                               req("title", .string(longest: 80, allowsEmpty: false), "Its title."), .reason]),
        ToolSpec("rename_chapter", title: "Rename a chapter", description: "Give a chapter a new title, as one undo step.",
                 readOnly: false, parameters: [id("chapter"), req("title", .string(longest: 80, allowsEmpty: false), "Its title."), .reason]),
        ToolSpec("remove_chapter", title: "Remove a chapter", description: "Remove a chapter, as one undo step.",
                 readOnly: false, parameters: [id("chapter"), .reason]),
        ToolSpec("add_mark", title: "Draw a mark", description: "Draw an arrow, line, box, ellipse or callout on the picture for a span, as one undo step. An arrow points from `from` to `to`; a box spans them.",
                 readOnly: false, parameters: [
                    req("shape", .choice(markShapes), "What to draw."),
                    req("fromX", unit, "Start, across."), req("fromY", unit, "Start, down."),
                    req("toX", unit, "End, across."), req("toY", unit, "End, down."),
                    req("startNanos", at, "When it appears, nanoseconds on the recording's clock."),
                    opt("seconds", .number(minimum: 0.5, maximum: 30), "How long it stays; 3 if not given."),
                    opt("text", .string(longest: longestTitle, allowsEmpty: false), "A callout's words."),
                    opt("picture", .string(longest: 200, allowsEmpty: false), "For shape image: the picture's name, from import_image; it fills the box from `from` to `to`."),
                    .reason]),
        ToolSpec("remove_mark", title: "Remove a mark", description: "Remove a mark, as one undo step.",
                 readOnly: false, parameters: [id("mark"), .reason]),
        ToolSpec("hide_region", title: "Hide a region", description: "Hide a rectangle of the recording for a span — a password, a name, a notification — as one undo step. It is pinned to the recording, so it stays over the same pixels as the camera moves.",
                 readOnly: false, parameters: [
                    req("startNanos", at, "From, nanoseconds on the recording's clock."),
                    req("endNanos", at, "To, nanoseconds on the recording's clock."),
                    req("x", unit, "Left edge."), req("y", unit, "Top edge."),
                    req("width", unit, "Width."), req("height", unit, "Height."),
                    opt("oval", .boolean, "Hide an ellipse inside the rectangle, for a face."),
                    .reason]),
        ToolSpec("remove_hidden_region", title: "Stop hiding a region", description: "Remove a hidden region, as one undo step.",
                 readOnly: false, parameters: [id("hidden region"), .reason]),
        ToolSpec("set_camera", title: "Place the camera", description: "Change the camera's shape, size and place, or hide it, as one undo step; fields not given stay. Only for a recording with a camera.",
                 readOnly: false, parameters: [
                    opt("shape", .choice(cameraShapes), "Its outline."),
                    opt("size", .number(minimum: 0.05, maximum: 0.5), "Its width, as a fraction of the frame's."),
                    opt("x", unit, "Its centre, across."), opt("y", unit, "Its centre, down."),
                    opt("hidden", .boolean, "Hide it."), opt("mirrored", .boolean, "Mirror it."),
                    .reason]),
    ]

    static func overlayRequest(_ name: String, _ a: ToolArguments, duration: Int64) -> Result<Request, MCPToolResultFailure>? {
        func edit(_ e: OverlayEdit) -> Result<Request, MCPToolResultFailure> { .success(.overlay(e, reason: a.string("reason"))) }
        func inside(_ field: String, _ value: Int64?) -> MCPToolResultFailure? {
            guard let value, value > duration else { return nil }
            return .init("`\(field)` \(value) is past the end of the recording, \(duration).")
        }
        func title(_ text: String?) -> TitleFields {
            TitleFields(text: text, startNanos: a.optionalInteger("startNanos"), seconds: a.optionalNumber("seconds"),
                        x: a.optionalNumber("x"), y: a.optionalNumber("y"), size: a.optionalNumber("size"),
                        bold: a.optionalBool("bold"), color: a.optionalString("color"))
        }
        switch name {
        case overlays: return .success(.overlays)
        case "add_title":
            if let failure = inside("startNanos", a.optionalInteger("startNanos")) { return .failure(failure) }
            return edit(.addTitle(title(a.string("text"))))
        case "edit_title":
            if let failure = inside("startNanos", a.optionalInteger("startNanos")) { return .failure(failure) }
            let fields = title(a.optionalString("text"))
            guard fields != TitleFields() else {
                return .failure(.init("Nothing to change: give at least one of text, startNanos, seconds, x, y, size, bold, color."))
            }
            return edit(.editTitle(id: Int(a.integer("id")), fields))
        case "remove_title": return edit(.removeTitle(id: Int(a.integer("id"))))
        case "add_chapter":
            if let failure = inside("atNanos", a.integer("atNanos")) { return .failure(failure) }
            return edit(.addChapter(atNanos: a.integer("atNanos"), title: a.string("title")))
        case "rename_chapter": return edit(.renameChapter(id: Int(a.integer("id")), title: a.string("title")))
        case "remove_chapter": return edit(.removeChapter(id: Int(a.integer("id"))))
        case "add_mark":
            if let failure = inside("startNanos", a.integer("startNanos")) { return .failure(failure) }
            let fields = MarkFields(shape: a.string("shape"), fromX: a.number("fromX"), fromY: a.number("fromY"),
                                    toX: a.number("toX"), toY: a.number("toY"), startNanos: a.integer("startNanos"),
                                    seconds: a.optionalNumber("seconds") ?? 3, text: a.optionalString("text"),
                                    picture: a.optionalString("picture"))
            guard (fields.shape == "image") == (fields.picture != nil) else {
                return .failure(.init(fields.shape == "image"
                    ? "Shape image needs `picture`: a name from import_image."
                    : "`picture` is only for shape image."))
            }
            guard fields.fromX != fields.toX || fields.fromY != fields.toY else {
                return .failure(.init("`from` and `to` are the same point, so there is nothing to draw."))
            }
            return edit(.addMark(fields))
        case "remove_mark": return edit(.removeMark(id: Int(a.integer("id"))))
        case "hide_region":
            let start = a.integer("startNanos"), end = a.integer("endNanos")
            if let failure = inside("endNanos", end) { return .failure(failure) }
            guard end > start else { return .failure(.init("`endNanos` \(end) is not after `startNanos` \(start).")) }
            let region = HiddenRegion(startNanos: start, endNanos: end, x: a.number("x"), y: a.number("y"),
                                      width: a.number("width"), height: a.number("height"), oval: a.optionalBool("oval") ?? false)
            guard region.width > 0, region.height > 0 else { return .failure(.init("A hidden region needs a width and a height above 0.")) }
            return edit(.hideRegion(region))
        case "remove_hidden_region": return edit(.removeHiddenRegion(id: Int(a.integer("id"))))
        case "set_camera":
            let fields = CameraFields(shape: a.optionalString("shape"), size: a.optionalNumber("size"),
                                      x: a.optionalNumber("x"), y: a.optionalNumber("y"),
                                      hidden: a.optionalBool("hidden"), mirrored: a.optionalBool("mirrored"))
            guard fields != CameraFields() else {
                return .failure(.init("Nothing to change: give at least one of shape, size, x, y, hidden, mirrored."))
            }
            return edit(.setCamera(fields))
        default: return nil
        }
    }
}
