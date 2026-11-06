import AppKit
import FocusCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Reading list window: `focus://reader`, More → Reading list, or Settings → Read later.
@MainActor
final class ReaderWindowController: NSObject, NSWindowDelegate {
    static let shared = ReaderWindowController()
    private var window: NSWindow?

    func open(select id: UUID? = nil) {
        if let id { ReaderSelection.shared.selected = id }
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: ReaderView()))
        w.title = "Reading list"
        w.setContentSize(NSSize(width: 1180, height: 800))
        w.minSize = NSSize(width: 860, height: 560)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("FocusReadingList")
        if !w.setFrameUsingName("FocusReadingList") { w.center() }
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        ReaderStore.shared.fetchMissing()
    }

    func windowWillClose(_ notification: Notification) { ReaderStore.shared.flush() }
}

@MainActor
final class ReaderSelection: ObservableObject {
    static let shared = ReaderSelection()
    @Published var selected: UUID?
}

struct ReaderView: View {
    @ObservedObject private var store = ReaderStore.shared
    @ObservedObject private var selection = ReaderSelection.shared
    @State private var location: ReadingItem.Location = .inbox
    @State private var query = ""
    @State private var adding = false
    @State private var newLink = ""
    @State private var showHighlights = false

    private var list: [ReadingItem] { store.items(in: location, matching: query) }
    private var current: ReadingItem? { selection.selected.flatMap(store.item) }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 460)
        } detail: {
            if let item = current {
                ArticleDetail(item: item, showHighlights: $showHighlights, next: selectNext)
                    .id(item.id)
            } else {
                ContentUnavailableView("Nothing open", systemImage: "book",
                                       description: Text("Pick something from the list. Pages you save from Chrome's block page land in the Inbox."))
            }
        }
        .onChange(of: location) { _, _ in selection.selected = list.first?.id }
        .onAppear { if current == nil { selection.selected = list.first?.id } }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("", selection: $location) {
                ForEach(ReadingItem.Location.allCases, id: \.self) { loc in
                    Text(loc == .archive ? loc.title : "\(loc.title) \(store.items(in: loc).count)").tag(loc)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search titles, sites, authors, tags", text: $query)
                    .textFieldStyle(.plain)
                Button { adding.toggle() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Save a link")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if adding {
                HStack(spacing: 6) {
                    TextField("Paste a link", text: $newLink)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addLink)
                    Button("Save", action: addLink).disabled(newLink.isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            if let status = store.importStatus {
                HStack(alignment: .top, spacing: 6) {
                    if store.importing { ProgressView().controlSize(.small) }
                    Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            Divider()
            if list.isEmpty {
                ContentUnavailableView(query.isEmpty ? "\(location.title) is empty" : "No matches",
                                       systemImage: location == .archive ? "archivebox" : "tray",
                                       description: Text(location == .inbox && query.isEmpty
                                                         ? "Save from Chrome: the block page's Save for later, the Focus toolbar button, right-click → Save to reading list, or ⌥R."
                                                         : ""))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection.selected) {
                    ForEach(list) { item in
                        ReadingRow(item: item, fetching: store.fetching.contains(item.id))
                            .tag(item.id)
                            .contextMenu { rowMenu(item) }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    @ViewBuilder private func rowMenu(_ item: ReadingItem) -> some View {
        ForEach(ReadingItem.Location.allCases.filter { $0 != item.location }, id: \.self) { loc in
            Button("Move to \(loc.title)") { store.move(item.id, to: loc) }
        }
        Button("Open original") { if let u = URL(string: item.url) { NSWorkspace.shared.open(u) } }
        Button("Copy link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url, forType: .string)
        }
        if !item.hasContent { Button("Fetch article again") { store.refetch(item.id) } }
        Divider()
        Button("Delete", role: .destructive) { store.delete(item.id) }
    }

    private func addLink() {
        store.addLink(newLink)
        newLink = ""
        adding = false
        location = .inbox
    }

    /// After archiving or moving, open the next one in the same list.
    private func selectNext(after id: UUID) {
        let ids = store.items(in: location, matching: query).map(\.id)
        selection.selected = ids.first { $0 != id }
    }
}

private struct ReadingRow: View {
    let item: ReadingItem
    let fetching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(.system(size: 13, weight: item.openedAt == nil ? .semibold : .regular))
                .lineLimit(2)
            Text(meta)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if item.progress > 0.02 {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .tint(.secondary)
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 3)
    }

    private var meta: String {
        var parts = [item.siteName ?? item.host]
        if let a = item.author, !a.isEmpty { parts.append(a) }
        if let m = item.readingMinutes { parts.append("\(m) min") }
        if fetching { parts.append("fetching…") } else if item.contentError != nil { parts.append("no text") }
        if item.wasFocus == true, let l = item.label { parts.append("saved during \(l)") }
        if !item.highlights.isEmpty { parts.append("\(item.highlights.count) highlight\(item.highlights.count == 1 ? "" : "s")") }
        parts.append(item.savedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}

private struct ArticleDetail: View {
    let item: ReadingItem
    @Binding var showHighlights: Bool
    let next: (UUID) -> Void
    @ObservedObject private var store = ReaderStore.shared
    @StateObject private var bridge = ReaderBridge()

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if item.hasContent, let html = store.articleHTML(item.id) {
                    ArticleWebView(item: item, body: html, bridge: bridge)
                } else if store.fetching.contains(item.id) {
                    ProgressView("Getting the article…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label(item.contentError ?? "No article text yet", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text(item.title)
                    } actions: {
                        Button("Open original") { if let u = URL(string: item.url) { NSWorkspace.shared.open(u) } }
                        Button("Try again") { store.refetch(item.id) }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            if showHighlights {
                Divider()
                HighlightsPane(item: item, bridge: bridge)
                    .frame(width: 280)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                ForEach(ReadingItem.Location.allCases.filter { $0 != item.location }, id: \.self) { loc in
                    Button { move(to: loc) } label: {
                        Label(loc.title, systemImage: loc == .archive ? "archivebox" : loc == .later ? "clock" : "tray")
                    }
                    .help(loc == .archive ? "Archive (E)" : loc == .later ? "Later (L)" : "Back to Inbox")
                }
                Button { bridge.highlightSelection() } label: { Label("Highlight", systemImage: "highlighter") }
                    .help("Highlight the selected text (H)")
                    .disabled(!item.hasContent)
                Button { showHighlights.toggle() } label: {
                    Label("Highlights", systemImage: "list.bullet.rectangle")
                }
                .help("Show highlights and notes")
                Button { if let u = URL(string: item.url) { NSWorkspace.shared.open(u) } } label: {
                    Label("Open original", systemImage: "safari")
                }
                .help("Open the original page (O)")
            }
        }
        .navigationTitle(item.title)
        .navigationSubtitle(item.siteName ?? item.host)
        .onAppear {
            store.markOpened(item.id)
            bridge.onKey = { key in
                switch key {
                case "e": move(to: item.location == .archive ? .inbox : .archive)
                case "l": move(to: .later)
                case "o": if let u = URL(string: item.url) { NSWorkspace.shared.open(u) }
                default: break
                }
            }
        }
    }

    private func move(to loc: ReadingItem.Location) {
        let id = item.id
        store.move(id, to: loc)
        next(id)
    }
}

private struct HighlightsPane: View {
    let item: ReadingItem
    let bridge: ReaderBridge
    @ObservedObject private var store = ReaderStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Highlights")
                .font(.system(size: 13, weight: .semibold))
                .padding(12)
            Divider()
            if item.highlights.isEmpty {
                Text("Select text and press H to highlight it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(12)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(item.highlights) { h in
                            HighlightCard(itemID: item.id, highlight: h, bridge: bridge)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

private struct HighlightCard: View {
    let itemID: UUID
    let highlight: ReadingHighlight
    let bridge: ReaderBridge
    @State private var note: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(highlight.text)
                .font(.system(size: 12, design: .serif))
                .padding(.leading, 8)
                .overlay(alignment: .leading) { Rectangle().fill(.yellow).frame(width: 3) }
                .onTapGesture { bridge.scrollTo(highlight.id) }
            TextField("Add a note", text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .onSubmit { ReaderStore.shared.setNote(itemID, highlight: highlight.id, note: note) }
                .onChange(of: note) { _, v in ReaderStore.shared.setNote(itemID, highlight: highlight.id, note: v) }
            HStack {
                Text(highlight.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("Remove") {
                    bridge.unmark(highlight.id)
                    ReaderStore.shared.removeHighlight(itemID, highlight: highlight.id)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
            }
        }
        .onAppear { note = highlight.note ?? "" }
    }
}

// MARK: - Web view

@MainActor
final class ReaderBridge: ObservableObject {
    weak var webView: WKWebView?
    var onKey: ((String) -> Void)?

    func highlightSelection() { run("focusReader.highlightSelection()") }
    func scrollTo(_ id: UUID) { run("focusReader.scrollToMark('\(id.uuidString)')") }
    func unmark(_ id: UUID) { run("focusReader.unmark('\(id.uuidString)')") }

    private func run(_ js: String) {
        webView?.evaluateJavaScript(js, in: nil, in: .defaultClient, completionHandler: nil)
    }
}

private struct ArticleWebView: NSViewRepresentable {
    let item: ReadingItem
    let body: String
    let bridge: ReaderBridge

    func makeCoordinator() -> Coordinator { Coordinator(itemID: item.id, bridge: bridge) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let ucc = config.userContentController
        ucc.add(context.coordinator, contentWorld: .defaultClient, name: "focus")
        let highlights = item.highlights.map { ["id": $0.id.uuidString, "text": $0.text] }
        let boot: [String: Any] = ["progress": item.progress, "highlights": highlights]
        let bootJSON = (try? JSONSerialization.data(withJSONObject: boot)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        ucc.addUserScript(WKUserScript(source: "window.focusBoot = \(bootJSON);\n" + Self.readerJS,
                                       injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        bridge.webView = web
        web.loadHTMLString(page, baseURL: URL(string: item.url))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    private var page: String {
        let esc: (String) -> String = {
            $0.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var meta = [esc(item.siteName ?? item.host)]
        if let a = item.author, !a.isEmpty { meta.append(esc(a)) }
        if let p = item.publishedAt { meta.append(p.formatted(date: .abbreviated, time: .omitted)) }
        if let m = item.readingMinutes { meta.append("\(m) min read") }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>\(Self.css)</style></head><body>
        <article>
        <header><h1>\(esc(item.title))</h1><p class="meta">\(meta.joined(separator: " · "))</p></header>
        <div id="focus-body">\(body)</div>
        <p class="end"><a href="\(esc(item.url))">Original page</a></p>
        </article></body></html>
        """
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let itemID: UUID
        let bridge: ReaderBridge
        init(itemID: UUID, bridge: ReaderBridge) { self.itemID = itemID; self.bridge = bridge }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let o = message.body as? [String: Any], let type = o["type"] as? String else { return }
            do {
                let store = ReaderStore.shared
                switch type {
                case "progress":
                    if let v = o["value"] as? Double { store.setProgress(itemID, v) }
                case "highlight":
                    if let text = o["text"] as? String, let h = store.addHighlight(itemID, text: text) {
                        bridge.webView?.evaluateJavaScript("focusReader.markPending('\(h.id.uuidString)')",
                                                           in: nil, in: .defaultClient, completionHandler: nil)
                    }
                case "key":
                    if let k = o["key"] as? String { bridge.onKey?(k) }
                default: break
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }

    private static let css = """
    :root { color-scheme: light dark; --fg: #1d1d1f; --muted: #6e6e73; --link: #0a5bd6; --mark: rgba(255, 214, 10, .45); --rule: rgba(0,0,0,.1); --code: rgba(0,0,0,.05); }
    @media (prefers-color-scheme: dark) { :root { --fg: #e8e6e1; --muted: #9a9a9f; --link: #6cb4ff; --mark: rgba(255, 214, 10, .32); --rule: rgba(255,255,255,.14); --code: rgba(255,255,255,.07); } }
    html { background: transparent; }
    body { margin: 0; padding: 56px 32px 120px; color: var(--fg); font: 19px/1.62 "New York", ui-serif, Georgia, serif; -webkit-font-smoothing: antialiased; }
    article { max-width: 680px; margin: 0 auto; }
    header h1 { font: 700 34px/1.18 "New York", ui-serif, Georgia, serif; margin: 0 0 10px; letter-spacing: -.01em; }
    .meta { font: 13px/1.4 -apple-system, system-ui, sans-serif; color: var(--muted); margin: 0 0 36px; }
    h2, h3, h4 { font-family: -apple-system, system-ui, sans-serif; line-height: 1.3; margin: 1.8em 0 .6em; }
    h2 { font-size: 24px; } h3 { font-size: 20px; } h4 { font-size: 17px; }
    p, ul, ol, blockquote, pre, figure, table { margin: 0 0 1.1em; }
    a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
    img, video { max-width: 100%; height: auto; border-radius: 6px; display: block; margin: 1.2em auto; }
    figure { margin-left: 0; margin-right: 0; } figcaption { font: 13px/1.45 -apple-system, system-ui, sans-serif; color: var(--muted); margin-top: -.4em; }
    blockquote { border-left: 3px solid var(--rule); margin-left: 0; padding-left: 18px; color: var(--muted); }
    pre, code { font: 15px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--code); border-radius: 5px; }
    code { padding: 1px 4px; } pre { padding: 12px 14px; overflow-x: auto; } pre code { background: none; padding: 0; }
    table { border-collapse: collapse; font-size: 16px; display: block; overflow-x: auto; } td, th { border: 1px solid var(--rule); padding: 6px 9px; }
    hr { border: 0; border-top: 1px solid var(--rule); margin: 2em 0; }
    mark.focus-hl { background: var(--mark); color: inherit; border-radius: 2px; padding: 0 1px; }
    .end { font: 13px -apple-system, system-ui, sans-serif; margin-top: 48px; padding-top: 16px; border-top: 1px solid var(--rule); }
    """

    private static let readerJS = #"""
    (() => {
      const boot = window.focusBoot || {};
      const post = (m) => { try { window.webkit.messageHandlers.focus.postMessage(m); } catch {} };
      const root = document.getElementById('focus-body') || document.body;
      const maxScroll = () => Math.max(1, document.documentElement.scrollHeight - innerHeight);

      // Wraps every text-node piece of `range` in <mark data-id>.
      function wrap(range, id) {
        const walker = document.createTreeWalker(range.commonAncestorContainer.nodeType === 3 ? range.commonAncestorContainer.parentNode : range.commonAncestorContainer, NodeFilter.SHOW_TEXT);
        const nodes = [];
        while (walker.nextNode()) if (range.intersectsNode(walker.currentNode)) nodes.push(walker.currentNode);
        for (let node of nodes) {
          let start = node === range.startContainer ? range.startOffset : 0;
          let end = node === range.endContainer ? range.endOffset : node.length;
          if (end <= start || !node.data.slice(start, end).trim()) continue;
          if (start > 0) node = node.splitText(start), end -= start;
          if (end < node.length) node.splitText(end);
          const m = document.createElement('mark');
          m.className = 'focus-hl';
          m.dataset.id = id;
          node.parentNode.insertBefore(m, node);
          m.appendChild(node);
        }
      }

      // Finds `text` in the article ignoring whitespace differences, returns a Range.
      function find(text) {
        const want = text.replace(/\s+/g, ' ').trim();
        if (!want) return null;
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        const map = [];
        let flat = '';
        let lastSpace = true;
        while (walker.nextNode()) {
          const n = walker.currentNode;
          for (let i = 0; i < n.data.length; i++) {
            const c = /\s/.test(n.data[i]) ? ' ' : n.data[i];
            if (c === ' ' && lastSpace) continue;
            lastSpace = c === ' ';
            flat += c;
            map.push([n, i]);
          }
        }
        let at = flat.indexOf(want);
        if (at < 0) at = flat.toLowerCase().indexOf(want.toLowerCase());
        if (at < 0) return null;
        const [sn, so] = map[at];
        const [en, eo] = map[at + want.length - 1];
        const r = document.createRange();
        r.setStart(sn, so);
        r.setEnd(en, eo + 1);
        return r;
      }

      for (const h of boot.highlights || []) {
        const r = find(h.text);
        if (r) wrap(r, h.id);
      }

      let pending = null;
      window.focusReader = {
        highlightSelection() {
          const sel = getSelection();
          if (!sel || sel.isCollapsed || !root.contains(sel.anchorNode)) return;
          const text = sel.toString().trim();
          if (!text) return;
          pending = sel.getRangeAt(0).cloneRange();
          sel.removeAllRanges();
          post({ type: 'highlight', text });
        },
        markPending(id) { if (pending) wrap(pending, id); pending = null; },
        scrollToMark(id) {
          const m = document.querySelector(`mark[data-id="${id}"]`);
          if (m) m.scrollIntoView({ behavior: 'smooth', block: 'center' });
        },
        unmark(id) {
          for (const m of document.querySelectorAll(`mark[data-id="${id}"]`)) {
            while (m.firstChild) m.parentNode.insertBefore(m.firstChild, m);
            m.remove();
          }
          root.normalize();
        },
      };

      const restore = () => { if (boot.progress > 0.01 && boot.progress < 0.99) scrollTo(0, boot.progress * maxScroll()); };
      restore();
      addEventListener('load', restore);
      let t = null;
      addEventListener('scroll', () => {
        clearTimeout(t);
        t = setTimeout(() => post({ type: 'progress', value: Math.min(1, scrollY / maxScroll()) }), 600);
      }, { passive: true });

      addEventListener('keydown', (e) => {
        if (e.metaKey || e.ctrlKey || e.altKey) return;
        const k = e.key.toLowerCase();
        if (k === 'h') { focusReader.highlightSelection(); e.preventDefault(); }
        else if (k === 'j') scrollBy({ top: 120, behavior: 'smooth' });
        else if (k === 'k') scrollBy({ top: -120, behavior: 'smooth' });
        else if (['e', 'l', 'o'].includes(k)) { post({ type: 'key', key: k }); e.preventDefault(); }
      });
    })();
    """#
}
