import Foundation
import ImageIO
import Project
import Render
import Surface
import UniformTypeIdentifiers

/// `import_image`: Soredemo fetches a picture the agent named, checks it is one, and puts it in
/// the project (`docs/design/2026-11-13-the-agent-may-search-the-web.md`). The address was already
/// checked by `ImageImport.refusal`; a redirect is checked again, before it is followed.
extension AgentEditorBridge {
    func importImage(_ address: String, use: String, reason: String) async -> MCPToolResult {
        let fetched = await PictureFetcher.fetch(address)
        switch fetched {
        case .failure(let refusal):
            return .failure(message: refusal.message, code: "notImported")
        case .success(let picture):
            return await adopt(picture, from: address, use: use, reason: reason)
        }
    }

    func adopt(_ picture: PictureFetcher.Picture, from address: String, use: String, reason: String) async -> MCPToolResult {
        guard let package = editor.mediaURL.map(ProjectStore.packageURL(forMediaAt:)) else {
            return .failure(message: "This recording has no project to put a picture in yet.", code: "noProject")
        }
        let name = ImageImport.filename(for: address, decodedAs: picture.fileExtension)
        // A directory of the system's own choosing, so no name is minted here (rule 3), and the
        // file is copied from it by the same code a person's chosen picture goes through.
        guard let scratch = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                         appropriateFor: package, create: true) else {
            return .failure(message: "There was nowhere to put the picture while it was checked.", code: "internal")
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appending(path: name)
        do { try picture.data.write(to: file) } catch {
            return .failure(message: "The picture could not be written: \(error.localizedDescription)", code: "internal")
        }
        // Into the library too, as from the web and by which host — so it can be found again, and a
        // person can see where it came from (`docs/design/2026-11-13-the-library.md`).
        let host = URL(string: address)?.host(percentEncoded: false) ?? "the web"
        let kept = await editor.library.add(file, origin: .web(host: host))
        if use == "background" {
            return recordLook(reason: reason) { editor.stageStyle.useImageBackground(file, inPackageAt: package) }
        }
        guard let adopted = editor.annotations.adoptPicture(file, packageURL: package) else {
            return .failure(message: editor.annotations.pictureFailure ?? "The picture could not be added.", code: "notImported")
        }
        let libraryID: Any = (try? kept.get().id) ?? NSNull()
        return json(["picture": adopted, "libraryItem": libraryID, "width": picture.width, "height": picture.height,
                     "next": "Place it with add_mark shape image, picture \(adopted)."])
    }
}

/// The fetch itself, off the main actor. Every limit is a refusal that says what it found.
enum PictureFetcher {
    struct Picture: Sendable {
        let data: Data
        let fileExtension: String
        let width: Int
        let height: Int
    }

    struct Refusal: Error, Sendable { let message: String }

    static func fetch(_ address: String) async -> Result<Picture, Refusal> {
        guard let url = URL(string: address) else { return .failure(Refusal(message: "That is not an address.")) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: RedirectCheck(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await session.bytes(from: url) } catch {
            return .failure(Refusal(message: "The address could not be fetched: \(error.localizedDescription)"))
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return .failure(Refusal(message: "The site answered \((response as? HTTPURLResponse)?.statusCode ?? 0), not a picture."))
        }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > ImageImport.largestBytes {
                    return .failure(Refusal(message: "The file is over \(ImageImport.largestBytes / 1_048_576) MB, so it was not kept."))
                }
            }
        } catch {
            return .failure(Refusal(message: "The download stopped: \(error.localizedDescription)"))
        }
        return check(data)
    }

    /// Whether `data` is a picture this app can draw, and what kind.
    static func check(_ data: Data) -> Result<Picture, Refusal> {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            let head = String(decoding: data.prefix(200), as: UTF8.self).lowercased()
            return .failure(Refusal(message: head.contains("<svg")
                ? "That is an SVG, which cannot be drawn here; find a PNG or JPEG of it."
                : "That is not a picture (\(data.count) bytes that do not decode as one)."))
        }
        guard max(width, height) <= ImageImport.largestSide else {
            return .failure(Refusal(message: "It is \(width)×\(height); the largest side may be \(ImageImport.largestSide)."))
        }
        let fileExtension = UTType(type)?.preferredFilenameExtension ?? "png"
        return .success(Picture(data: data, fileExtension: fileExtension, width: width, height: height))
    }
}

/// A redirect is an address too: checked by the same rule before it is followed, so a public page
/// cannot send the fetch to this Mac or its network.
///
/// **The completion-handler form, not the `async` one**: the `async` form crashed the compiler in
/// SIL generation of its Objective-C thunk (Xcode's toolchain on macOS 27.2, under the test build).
final class RedirectCheck: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let address = request.url?.absoluteString, ImageImport.refusal(for: address) == nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
