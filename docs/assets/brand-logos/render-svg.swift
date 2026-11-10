import AppKit
import WebKit
import Foundation
import Darwin
class Renderer: NSObject, WKNavigationDelegate {
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 24, height: 24), styleMask: .borderless, backing: .buffered, defer: false)
    func run() throws {
        let svg = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        window.contentView = view
        view.loadHTMLString("<html><head><meta name='viewport' content='width=24'></head><body style='margin:0;background:transparent;width:24px;height:24px'>" + svg + "</body></html>", baseURL: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 256
        config.rect = CGRect(x: 0, y: 0, width: 24, height: 24)
        webView.takeSnapshot(with: config) { result, error in
            do {
                guard let image = result else { throw error ?? NSError(domain: "Snapshot", code: 1) }
                let bitmap = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
                let data = bitmap.representation(using: .png, properties: [:])!
                print("snapshot", bitmap.pixelsWide, bitmap.pixelsHigh, "corner alpha", bitmap.colorAt(x: 0, y: 0)!.alphaComponent)
                try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
                print("Rendered PNG", data.count)
                exit(0)
            } catch { print(error); exit(1) }
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let renderer = Renderer()
try renderer.run()
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(1) }
app.run()
