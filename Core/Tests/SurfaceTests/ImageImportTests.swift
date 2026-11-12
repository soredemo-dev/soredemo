import Foundation
import Testing
@testable import Surface

// What `import_image` will fetch, decided before anything is fetched
// (`docs/design/2026-11-13-the-agent-may-search-the-web.md`).

@Suite struct ImageImportTests {
    @Test func aPublicHttpsAddressPasses() {
        #expect(ImageImport.refusal(for: "https://www.nthu.edu.tw/img/logo.png") == nil)
    }

    /// Each refusal says what was found, so the agent can find another address.
    @Test(arguments: [
        ("http://example.com/a.png", "Only an https address can be imported; this is http."),
        ("file:///Users/me/secret.png", "Only an https address can be imported; this is file."),
        ("https://localhost/a.png", "localhost is this Mac, not the web."),
        ("https://printer.local/a.png", "printer.local is on this network, not the web."),
        ("https://192.168.1.1/a.png", "192.168.1.1 is an address, not a site's name; give the page's own address."),
        ("https://[::1]/a.png", "[::1] is an address, not a site's name; give the page's own address."),
        ("https://user:pw@example.com/a.png", "That address carries a name and password; give one without."),
        ("https://example.com:8443/a.png", "That address names a port, 8443; give one on the usual https port."),
        ("not a url", "That is not an address."),
    ])
    func anAddressThatIsNotAPublicSiteIsRefused(url: String, message: String) {
        #expect(ImageImport.refusal(for: url) == message)
    }

    /// The name it is saved under: the URL's own, made safe, with the extension of what decoded.
    @Test func theSavedNameIsTheAddressesOwnMadeSafe() {
        #expect(ImageImport.filename(for: "https://x.edu/img/NTHU Logo (2).PNG?v=3", decodedAs: "png") == "NTHU-Logo-2.png")
        #expect(ImageImport.filename(for: "https://x.edu/", decodedAs: "jpg") == "imported.jpg")
        // An encoded climb out of the directory decodes to `/../../etc/passwd`; only its last part
        // is kept, and no separator or dot survives into the name.
        let climbed = ImageImport.filename(for: "https://x.edu/..%2F..%2Fetc%2Fpasswd", decodedAs: "png")
        #expect(climbed == "passwd.png")
        #expect(!climbed.dropLast(4).contains(".") && !climbed.contains("/"))
        #expect(ImageImport.filename(for: "https://x.edu/photo.jpeg", decodedAs: "png") == "photo.png",
                "the extension is what it decoded as, not what it was called")
    }
}
