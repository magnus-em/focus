import SwiftUI
import WebKit
import AppKit

/// SwiftUI wrapper around WKWebView that renders Markdown-ish text with
/// LaTeX-style math via KaTeX. Use it for problem solutions where
/// `$inline$` and `$$display$$` delimiters should look like real math.
///
/// Usage:
///   MathView(content: "By Bayes, $P(A|B) = \\frac{P(B|A)P(A)}{P(B)}$.",
///            fontSize: 14)
///
/// The KaTeX bundle is shipped in `Sources/Resources/katex/`. Loaded
/// once via WKWebView and auto-render scans the document for `$...$` and
/// `$$...$$` delimiters.
/// WKWebView subclass that forwards scroll-wheel events up to the
/// enclosing SwiftUI ScrollView. Without this, mousing over a math
/// block inside a long scroll trapped the scroll inside the WebView
/// (which has nothing to scroll, since we size it to its content) and
/// the outer page wouldn't move.
final class ScrollPassingWKWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

struct MathView: NSViewRepresentable {
    let content: String
    var fontSize: CGFloat = 14
    /// Optional theme override — when nil, follows the SwiftUI color
    /// scheme (light / dark).
    var darkMode: Bool? = nil
    /// Reported back when content layout stabilizes so callers can
    /// size the view correctly.
    var onHeightChange: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Allow loading the KaTeX assets from the app bundle. Without this
        // bundle-relative URLs (the font @font-face entries) won't resolve.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // CRITICAL: by default WKWebView treats each file:// URL as its own
        // origin, so a `loadHTMLString(_:, baseURL: file://.../katex/x.html)`
        // page cannot fetch its sibling `katex.min.js` / `katex.min.css`
        // due to same-origin policy. Without these two flags, KaTeX's
        // auto-render script never executes and all $...$ / $$...$$ blocks
        // render as literal source. Private prefs, but stable for years.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        // Bridge for the JS side to report content height back to Swift
        // *after* KaTeX has actually rendered (and after fonts settle).
        // Without this, height is read at didFinish — before auto-render —
        // and math content gets clipped to the unrendered text height.
        config.userContentController.add(context.coordinator, name: "heightChange")

        let webView = ScrollPassingWKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")    // transparent — sits over SwiftUI bg
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let isDark = darkMode ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        // Always refresh the parent reference so the height callback
        // posts back to the *current* SwiftUI closure (which lives in
        // a fresh struct on every re-render).
        context.coordinator.parent = self
        let html = Self.makeHTML(content: content, fontSize: fontSize, dark: isDark)
        // Skip reload if the HTML hasn't actually changed. SwiftUI calls
        // updateNSView whenever the parent re-evaluates — and because
        // AutoSizingMathView reports height into a @State that drives a
        // frame() change, this fires on every height tick. Without this
        // guard each height report restarted the WebView, which restarted
        // KaTeX, and content with long bodies never finished settling
        // (so $...$ stayed as raw text on screen).
        let signature = html.hashValue
        if context.coordinator.lastHTMLHash == signature { return }
        context.coordinator.lastHTMLHash = signature

        // The previous approach used `loadHTMLString(_:baseURL:)` with a
        // file:// baseURL. That works for *navigation* but modern WKWebView
        // still treats the resulting page as a unique origin and blocks
        // fetches of sibling CSS/JS — so KaTeX's auto-render script never
        // loaded, and all $...$ rendered as literal source.
        //
        // The robust fix is `loadFileURL(_:allowingReadAccessTo:)`. That
        // requires a real on-disk HTML file plus a directory the WebView
        // is granted read access to. The bundle is read-only, so we copy
        // KaTeX into a writable temp dir once per app launch and write
        // the HTML file alongside it.
        guard let writableDir = Self.writableKatexDir else {
            webView.loadHTMLString(html, baseURL: nil)
            return
        }
        let htmlName = "render-\(ObjectIdentifier(context.coordinator).hashValue).html"
        let htmlFile = writableDir.appendingPathComponent(htmlName)
        do {
            try html.write(to: htmlFile, atomically: true, encoding: .utf8)
            webView.loadFileURL(htmlFile, allowingReadAccessTo: writableDir)
        } catch {
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    /// Shared writable copy of the KaTeX bundle assets. SPM resources live
    /// inside the app bundle which is read-only on signed builds, and
    /// `loadFileURL(_:allowingReadAccessTo:)` needs both the HTML file
    /// and the assets reachable under one writable root. So we copy once
    /// per launch into `NSTemporaryDirectory()/focus-katex-<pid>/` and
    /// reuse for every MathView render.
    private static let writableKatexDir: URL? = {
        let resourceBundle = Bundle.focusResources
        guard let bundled = resourceBundle?.url(forResource: "katex", withExtension: nil)
                ?? Bundle.main.url(forResource: "katex", withExtension: nil) else {
            return nil
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-katex-\(pid)", isDirectory: true)
        // Best-effort wipe — previous run's dir (same pid is rare, but
        // defend against it). Then copy the whole katex/ tree.
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: bundled, to: dest)
            return dest
        } catch {
            return nil
        }
    }()

    /// Assemble the HTML page: KaTeX CSS, the user content as markdown-
    /// flavored body, and the KaTeX auto-render script that scans for
    /// $...$ and $$...$$ on DOMContentLoaded.
    private static func makeHTML(content: String, fontSize: CGFloat, dark: Bool) -> String {
        let bg = dark ? "#1c1c1e" : "#ffffff00"
        let fg = dark ? "#e0e0e0" : "#1a1a1a"
        let secondary = dark ? "#a0a0a0" : "#5a5a5a"
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width">
        <link rel="stylesheet" href="katex.min.css">
        <style>
          html, body {
            margin: 0;
            padding: 0;
            background: \(bg);
            color: \(fg);
            font-family: -apple-system, "New York", "Times New Roman", serif;
            font-size: \(fontSize)px;
            line-height: 1.55;
            -webkit-font-smoothing: antialiased;
          }
          .body { padding: 4px 2px; }
          p { margin: 0 0 0.6em 0; }
          p:last-child { margin-bottom: 0; }
          .katex-display { margin: 0.6em 0; }
          .katex { font-size: 1.05em; }
          .step-title {
            font-family: -apple-system, sans-serif;
            font-size: 0.78em;
            font-weight: 700;
            letter-spacing: 0.06em;
            text-transform: uppercase;
            color: \(secondary);
            margin: 0 0 0.3em 0;
          }
        </style>
        </head>
        <body>
        <div class="body">\(markdownToHTML(content))</div>
        <script src="katex.min.js"></script>
        <script src="auto-render.min.js"></script>
        <script>
          function reportHeight() {
            try {
              var h = Math.max(document.body.scrollHeight,
                               document.documentElement.scrollHeight,
                               document.body.offsetHeight,
                               document.documentElement.offsetHeight);
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.heightChange) {
                window.webkit.messageHandlers.heightChange.postMessage(h);
              }
            } catch (e) {}
          }
          document.addEventListener("DOMContentLoaded", function() {
            renderMathInElement(document.body, {
              delimiters: [
                {left: "$$", right: "$$", display: true},
                {left: "$",  right: "$",  display: false}
              ],
              throwOnError: false
            });
            // Initial post — KaTeX inline glyphs are already laid out.
            reportHeight();
            // Re-post once KaTeX webfonts have finished loading (display
            // math gets taller once fonts swap in).
            if (document.fonts && document.fonts.ready) {
              document.fonts.ready.then(reportHeight);
            }
            // Safety re-measures for late layout settling.
            setTimeout(reportHeight, 80);
            setTimeout(reportHeight, 320);
            setTimeout(reportHeight, 800);
            // NB: deliberately NOT using a ResizeObserver here. The
            // SwiftUI side sets our frame in response to height reports,
            // which triggers a reflow, which triggers another resize,
            // which oscillates forever. The fixed setTimeouts above
            // are enough to catch font-swap-driven height changes
            // without feeding back into our own frame updates.
          });
        </script>
        </body>
        </html>
        """
    }

    /// Convert a tiny subset of Markdown to HTML — only what we need for
    /// hint bodies. Avoids adding a dependency on swift-markdown.
    ///   • Blank line  → paragraph break
    ///   • `**bold**`  → <strong>
    ///   • `*italic*`  → <em>
    ///   • `\n`        → <br>
    /// Math passes through unchanged so KaTeX can see the $delimiters$.
    private static func markdownToHTML(_ s: String) -> String {
        // Split into paragraphs by blank-line.
        let paragraphs = s.components(separatedBy: "\n\n")
        return paragraphs.map { para -> String in
            var p = para
            p = p.replacingOccurrences(of: "&", with: "&amp;")
            // Don't escape < and > because users won't write raw HTML in
            // hints, and KaTeX may emit some via auto-render before this
            // pass (well, no — markdown runs first; we're fine).
            p = applyEmphasis(p, marker: "**", tag: "strong")
            p = applyEmphasis(p, marker: "*",  tag: "em")
            p = p.replacingOccurrences(of: "\n", with: "<br>")
            return "<p>\(p)</p>"
        }.joined(separator: "\n")
    }

    private static func applyEmphasis(_ s: String, marker: String, tag: String) -> String {
        var out = ""
        var rest = s[...]
        while let openRange = rest.range(of: marker) {
            out += rest[..<openRange.lowerBound]
            let afterOpen = openRange.upperBound
            if let closeRange = rest.range(of: marker, range: afterOpen..<rest.endIndex) {
                let inner = rest[afterOpen..<closeRange.lowerBound]
                out += "<\(tag)>\(inner)</\(tag)>"
                rest = rest[closeRange.upperBound...]
            } else {
                // unbalanced marker — preserve as-is
                out += rest[openRange.lowerBound...]
                return out
            }
        }
        out += rest
        return out
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MathView
        var lastHTMLHash: Int = 0
        init(_ parent: MathView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // didFinish fires before KaTeX renders, so don't size from
            // here — the JS bridge posts the real height once layout
            // settles. We keep this around in case the bridge fails to
            // attach (e.g. plain text with no math): fall back to the
            // raw DOM height so the view doesn't collapse to zero.
            webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, _ in
                guard let self = self else { return }
                if let h = result as? CGFloat { self.parent.onHeightChange?(h) }
                else if let n = result as? NSNumber { self.parent.onHeightChange?(CGFloat(n.doubleValue)) }
            }
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "heightChange" else { return }
            if let h = message.body as? CGFloat {
                parent.onHeightChange?(h)
            } else if let n = message.body as? NSNumber {
                parent.onHeightChange?(CGFloat(n.doubleValue))
            }
        }
    }
}

/// Convenience wrapper that auto-sizes the WebView to its content height.
/// Use this instead of MathView when you want it to grow with the math
/// rather than having a fixed frame.
struct AutoSizingMathView: View {
    let content: String
    var fontSize: CGFloat = 14
    @State private var height: CGFloat = 60

    var body: some View {
        MathView(content: content, fontSize: fontSize) { h in
            // Pad slightly to avoid scroll bars on borderline cases.
            let target = h + 4
            // Deadband — only commit if the new height differs meaningfully.
            // Without this, subpixel jitter from font-fallback layout would
            // shake the parent layout (you'd see chars / parens visibly
            // flicker as the frame oscillates by fractions of a point).
            if abs(target - self.height) > 1.0 {
                self.height = target
            }
        }
        .frame(height: height)
    }
}
