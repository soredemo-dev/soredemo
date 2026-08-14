import CheckerLexer
import Foundation
import Testing

/// **The compositor protocol may not name Core Image or Metal.** A seam that speaks `CIImage`
/// has already chosen Core Image, and the deferred 4K frame-time measurement could no longer
/// change the answer.
@Test func theFrameRendererProtocolNamesNeitherCoreImageNorMetal() throws {
    let url = repositoryRoot.appending(path: "Sources/Compositing/FrameRenderer.swift")
    let source = try String(contentsOf: url, encoding: .utf8)
    let code = SwiftSourceLexer.codeViewLines(of: source).joined(separator: "\n")
    // CVPixelBuffer is deliberately NOT banned: it is CoreVideo, which both paths already speak,
    // so it names no winner. Banning it would force `AnyObject` and a downcast for nothing.
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
