import AppKit
import Foundation

/// **Everything this app puts on the clipboard, and it only ever puts.** The pasteboard is on
/// the content rule's banned list because it READS what a person copied; writing is allowed at
/// the one line below, and `theClipboardIsWrittenInExactlyOnePlaceAndNeverRead` counts it.
///
/// Two things are written, each because a person pressed a button that says Copy: a finished
/// export, and a list of chapters for a video description. Nothing is sent anywhere.
enum Clipboard {
    private static var board: NSPasteboard { .general }

    /// **The FILE, not its path.** Pasting into Mail, Slack or Messages then attaches the
    /// video; a string of the path would paste as text and attach nowhere. `as NSURL` because
    /// `URL` is not an `NSPasteboardWriting`, and the bridged type carries the file-URL flavour.
    static func put(file url: URL) {
        // `clearContents()` first, because the pasteboard accumulates otherwise and a paste
        // would carry whatever was copied before this alongside it.
        board.clearContents()
        board.writeObjects([url as NSURL])
    }

    static func put(text: String) {
        board.clearContents()
        board.setString(text, forType: .string)
    }
}
