// Renders an SVG with WebKit (no third-party tools needed) to PNGs of the given sizes.
// Usage: render <in.svg> <outdir> <size> [<size>...]  -> writes <outdir>/icon_<size>.png
// Used by make-icon.sh.
import Cocoa
import WebKit

let args = CommandLine.arguments
let svgURL = URL(fileURLWithPath: args[1]).standardizedFileURL
let outDir = URL(fileURLWithPath: args[2])
let sizes = args.dropFirst(3).compactMap { Int($0) }
let htmlURL = svgURL.deletingLastPathComponent().appendingPathComponent(".render-\(getpid()).html")

class Loader: NSObject, WKNavigationDelegate {
    let web: WKWebView
    init(_ w: WKWebView) { web = w }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.snap() }
    }
    func snap() {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        cfg.snapshotWidth = 1024
        web.takeSnapshot(with: cfg) { img, err in
            guard let img = img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                print("snapshot failed: \(String(describing: err))"); exit(1)
            }
            for s in sizes {
                let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: s, height: s))
                let out = ctx.makeImage()!
                let rep = NSBitmapImageRep(cgImage: out)
                let data = rep.representation(using: .png, properties: [:])!
                try! data.write(to: outDir.appendingPathComponent("icon_\(s).png"))
            }
            try? FileManager.default.removeItem(at: htmlURL)
            exit(0)
        }
    }
}

let app = NSApplication.shared
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
web.setValue(false, forKey: "drawsBackground")
let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1024, height: 1024), styleMask: [.borderless], backing: .buffered, defer: false)
win.backgroundColor = .clear
win.isOpaque = false
win.contentView = web
win.orderBack(nil)
let loader = Loader(web)
web.navigationDelegate = loader
let html = """
<!doctype html><html><head><style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}img{display:block;width:1024px;height:1024px}</style></head>
<body><img src="\(svgURL.lastPathComponent)"></body></html>
"""
try! html.write(to: htmlURL, atomically: true, encoding: .utf8)
web.loadFileURL(htmlURL, allowingReadAccessTo: svgURL.deletingLastPathComponent())
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("timeout"); exit(2) }
app.setActivationPolicy(.prohibited)
app.run()
