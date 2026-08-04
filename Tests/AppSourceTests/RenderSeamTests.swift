import CheckerLexer
import Foundation
import Testing

/// **The compositor protocol may not name Core Image or Metal.**
///
/// A seam that speaks `CIImage` has already chosen Core Image, and the Metal implementation behind
/// it would be a translation layer rather than an alternative — at which point the 4K frame-time
/// measurement can no longer change the answer, which is the only reason the choice was deferred.
@Test func theFrameRendererProtocolNamesNeitherCoreImageNorMetal() throws {
    let url = repositoryRoot.appending(path: "Soredemo/Render/FrameRenderer.swift")
    let source = try String(contentsOf: url, encoding: .utf8)
    let code = SwiftSourceLexer.codeViewLines(of: source).joined(separator: "\n")
    // CVPixelBuffer is deliberately NOT banned: it is CoreVideo, which both a Core Image path
    // and a Metal path already speak, so it names no winner. Banning it would force `AnyObject`
    // and a downcast in every implementation — cost with no property bought.
    for banned in ["CIImage", "CIContext", "CIFilter", "MTLTexture", "MTLDevice",
                   "MTLCommandBuffer"] {
        #expect(!code.contains(banned),
                """
                FrameRenderer.swift names '\(banned)'. The seam must not name a winner: a
                protocol that speaks one framework's vocabulary has chosen it, and the
                alternative becomes a translation layer. Express the frame as a CVPixelBuffer,
                which both paths already speak.
                """)
    }
}
