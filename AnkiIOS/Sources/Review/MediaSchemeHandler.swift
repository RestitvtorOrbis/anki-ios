// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import Foundation
import WebKit

/// WKURLSchemeHandler for the "anki-media" custom URL scheme.
///
/// The reviewer HTML uses `anki-media:///filename.ext` URLs for card media (images,
/// audio etc.). This handler resolves those paths against the collection's media
/// folder so WKWebView can load them from the app container without needing an
/// HTTP server.
///
/// Registration:
///   config.setURLSchemeHandler(MediaSchemeHandler(mediaFolder: url), forURLScheme: "anki-media")
final class MediaSchemeHandler: NSObject, WKURLSchemeHandler {
    private let mediaFolder: URL
    private var activeTasks: Set<ObjectIdentifier> = []

    init(mediaFolder: URL) {
        self.mediaFolder = mediaFolder
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        activeTasks.insert(id)

        guard let host = urlSchemeTask.request.url?.lastPathComponent,
              !host.isEmpty
        else {
            fail(urlSchemeTask, id: id)
            return
        }

        let fileURL = mediaFolder.appendingPathComponent(host)
        guard activeTasks.contains(id) else { return }

        guard let data = try? Data(contentsOf: fileURL) else {
            fail(urlSchemeTask, id: id)
            return
        }

        guard activeTasks.contains(id) else { return }
        let mimeType = mimeType(for: fileURL.pathExtension)
        let response = URLResponse(
            url: urlSchemeTask.request.url!,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
        activeTasks.remove(id)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        activeTasks.remove(ObjectIdentifier(urlSchemeTask))
    }

    private func fail(_ task: WKURLSchemeTask, id: ObjectIdentifier) {
        guard activeTasks.contains(id) else { return }
        task.didFailWithError(URLError(.fileDoesNotExist))
        activeTasks.remove(id)
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "mp3": return "audio/mpeg"
        case "ogg": return "audio/ogg"
        case "wav": return "audio/wav"
        case "mp4": return "video/mp4"
        case "webm": return "video/webm"
        default: return "application/octet-stream"
        }
    }
}
