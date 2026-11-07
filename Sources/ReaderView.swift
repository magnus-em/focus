import AppKit
import FocusCore
import SwiftUI
import WebKit

/// Reading list window: `focus://reader`, More → Reading list, or Settings → Read later.
/// Layout after Apple Books and Readwise Reader: library sidebar, article list with
/// covers and excerpts, and a reader with Books-style themes, typefaces and sizes.
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
        w.setContentSize(NSSize(width: 1280, height: 820))
        w.minSize = NSSize(width: 940, height: 580)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.toolbarStyle = .unified
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

enum ReaderSection: Hashable {
    case location(ReadingItem.Location)
    case highlights

    var title: String {
        switch self {
        case .location(let l): l.title
        case .highlights: "Highlights"
        }
    }

    var icon: String {
        switch self {
        case .location(.inbox): "tray"
        case .location(.later): "clock"
        case .location(.archive): "archivebox"
        case .highlights: "highlighter"
        }
    }
}

/// Reader appearance, after the Books "Aa" menu.
struct ReaderStyle: Equatable {
    enum Theme: String, CaseIterable { case auto, white, sepia, night }
    enum Font: String, CaseIterable {
        case newYork, charter, iowan, sanFrancisco
        var name: String {
            switch self {
            case .newYork: "New York"
            case .charter: "Charter"
            case .iowan: "Iowan"
            case .sanFrancisco: "San Francisco"
            }
        }
        var css: String {
            switch self {
            case .newYork: #""New York", ui-serif, Georgia, serif"#
            case .charter: #"Charter, "Bitstream Charter", Georgia, serif"#
            case .iowan: #""Iowan Old Style", Palatino, Georgia, serif"#
            case .sanFrancisco: #"-apple-system, system-ui, sans-serif"#
            }
        }
        var swiftUI: SwiftUI.Font {
            switch self {
            case .newYork: .system(size: 15, design: .serif)
            case .charter: .custom("Charter", size: 15)
            case .iowan: .custom("Iowan Old Style", size: 15)
            case .sanFrancisco: .system(size: 15)
            }
        }
    }
    enum Width: String, CaseIterable { case narrow, medium, wide }

    var theme: Theme
    var font: Font
    var size: Int
    var width: Width

    var json: String {
        let px = ["narrow": 600, "medium": 690, "wide": 800][width.rawValue] ?? 690
        let o: [String: Any] = ["theme": theme.rawValue, "font": font.css, "size": size, "width": px]
        return (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    var background: NSColor {
        switch theme {
        case .white: NSColor(white: 1, alpha: 1)
        case .sepia: NSColor(srgbRed: 0.973, green: 0.945, blue: 0.890, alpha: 1)
        case .night: NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1)
        case .auto: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1) : .white }
        }
    }
}

struct ReaderView: View {
    @ObservedObject private var store = ReaderStore.shared
    @ObservedObject private var selection = ReaderSelection.shared
    @State private var section: ReaderSection? = .location(.inbox)
    @State private var query = ""
    @State private var adding = false
    @State private var newLink = ""
    @State private var showHighlights = false
    @AppStorage("reader.theme") private var theme = ReaderStyle.Theme.auto.rawValue
    @AppStorage("reader.font") private var font = ReaderStyle.Font.newYork.rawValue
    @AppStorage("reader.size") private var size = 19
    @AppStorage("reader.width") private var width = ReaderStyle.Width.medium.rawValue

    private var style: ReaderStyle {
        ReaderStyle(theme: .init(rawValue: theme) ?? .auto, font: .init(rawValue: font) ?? .newYork,
                    size: size, width: .init(rawValue: width) ?? .medium)
    }

    private var location: ReadingItem.Location {
        if case .location(let l) = section { return l }
        return .inbox
    }

    private var list: [ReadingItem] { store.items(in: location, matching: query) }
    private var current: ReadingItem? { selection.selected.flatMap(store.item) }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } content: {
            Group {
                if section == .highlights { AllHighlightsList(query: query, open: openFromHighlights) } else { articleList }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search")
            .navigationSplitViewColumnWidth(min: 360, ideal: 400, max: 520)
        } detail: {
            if let item = current {
                ArticleDetail(item: item, style: style, showHighlights: $showHighlights, next: selectNext)
                    .id(item.id)
            } else {
                ContentUnavailableView("Nothing open", systemImage: "book",
                                       description: Text("Pick an article to read it here."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { adding = true } label: { Label("Save a link", systemImage: "plus") }
                    .help("Save a link")
                    .popover(isPresented: $adding, arrowEdge: .bottom) { addLinkPopover }
            }
        }
        .onChange(of: section) { _, _ in
            if section != .highlights { selection.selected = list.first?.id }
        }
        .onAppear { if current == nil { selection.selected = list.first?.id } }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $section) {
            Section("Library") {
                ForEach(ReadingItem.Location.allCases, id: \.self) { loc in
                    let s = ReaderSection.location(loc)
                    Label(s.title, systemImage: s.icon)
                        .badge(loc == .archive ? 0 : store.items(in: loc).count)
                        .tag(s)
                }
            }
            Section("Notes") {
                Label("Highlights", systemImage: "highlighter")
                    .badge(store.items.reduce(0) { $0 + $1.highlights.count })
                    .tag(ReaderSection.highlights)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if let status = store.importStatus, store.importing || !status.hasPrefix("Imported") {
                HStack(alignment: .top, spacing: 6) {
                    if store.importing { ProgressView().controlSize(.small) }
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
            }
        }
    }

    private var addLinkPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Save a link").font(.system(size: 13, weight: .semibold))
            TextField("https://", text: $newLink)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(addLink)
            HStack {
                Spacer()
                Button("Cancel") { adding = false }
                Button("Save", action: addLink)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newLink.isEmpty)
            }
        }
        .padding(16)
    }

    // MARK: Article list

    @ViewBuilder private var articleList: some View {
        if list.isEmpty {
            ContentUnavailableView {
                Label(query.isEmpty ? "\(location.title) is empty" : "No matches",
                      systemImage: ReaderSection.location(location).icon)
            } description: {
                if query.isEmpty && location == .inbox {
                    Text("Save from Chrome with the block page's Save for later, the Focus toolbar button, right-click → Save to reading list, or ⌥R.")
                } else if query.isEmpty && location == .archive {
                    Text("Press E while reading to archive what you've finished.")
                }
            }
        } else {
            List(selection: $selection.selected) {
                ForEach(list) { item in
                    ReadingRow(item: item, fetching: store.fetching.contains(item.id))
                        .tag(item.id)
                        .contextMenu { rowMenu(item) }
                        .listRowSeparator(.visible)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .navigationTitle(location.title)
            .navigationSubtitle(subtitle)
        }
    }

    private var subtitle: String {
        let n = list.count
        let minutes = list.compactMap(\.readingMinutes).reduce(0, +)
        let time = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        return "\(n) article\(n == 1 ? "" : "s")" + (minutes > 0 ? " · \(time) of reading" : "")
    }

    @ViewBuilder private func rowMenu(_ item: ReadingItem) -> some View {
        ForEach(ReadingItem.Location.allCases.filter { $0 != item.location }, id: \.self) { loc in
            Button("Move to \(loc.title)") { store.move(item.id, to: loc) }
        }
        Divider()
        Button("Open original") { if let u = URL(string: item.url) { NSWorkspace.shared.open(u) } }
        Button("Copy link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url, forType: .string)
        }
        Button("Fetch the article again") { store.refetch(item.id) }
        Divider()
        Button("Delete", role: .destructive) { store.delete(item.id) }
    }

    private func addLink() {
        guard !newLink.isEmpty else { return }
        store.addLink(newLink)
        newLink = ""
        adding = false
        section = .location(.inbox)
    }

    private func openFromHighlights(_ id: UUID) {
        if let loc = store.item(id)?.location { section = .location(loc) }
        DispatchQueue.main.async { selection.selected = id }
    }

    /// After archiving or moving, open the next one in the same list.
    private func selectNext(after id: UUID) {
        let ids = list.map(\.id)
        guard let i = ids.firstIndex(of: id) else { selection.selected = ids.first; return }
        let rest = ids.filter { $0 != id }
        selection.selected = rest.isEmpty ? nil : rest[min(i, rest.count - 1)]
    }
}

// MARK: - Rows

private struct ReadingRow: View {
    let item: ReadingItem
    let fetching: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Cover(item: item)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(item.location == .archive ? .secondary : .primary)
                if let excerpt = item.summary, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if item.openedAt == nil {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                            .accessibilityLabel("Unread")
                    }
                    Text(meta)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    trailing
                        .fixedSize()
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .help(item.wasFocus == true && item.label != nil ? "Saved during \(item.label!)" : "")
    }

    private var meta: String {
        item.siteName ?? item.host
    }

    private var age: String {
        let s = Date().timeIntervalSince(item.savedAt)
        switch s {
        case ..<3600: return "now"
        case ..<86400: return "\(Int(s / 3600))h"
        case ..<(7 * 86400): return "\(Int(s / 86400))d"
        case ..<(60 * 86400): return "\(Int(s / (7 * 86400)))w"
        default: return item.savedAt.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    @ViewBuilder private var trailing: some View {
        if fetching {
            ProgressView().controlSize(.mini)
        } else if item.contentError != nil && !item.hasContent {
            Image(systemName: "exclamationmark.triangle").help(item.contentError ?? "")
        } else if item.progress >= 0.97 {
            Text("Finished")
        } else if item.progress > 0.02 {
            Text(item.readingMinutes.map { "\(max(1, Int((Double($0) * (1 - item.progress)).rounded()))) min left" }
                 ?? "\(Int(item.progress * 100))% read")
                .foregroundStyle(Color.accentColor)
                .help("\(Int(item.progress * 100))% read")
        } else {
            Text(item.readingMinutes.map { "\($0) min · \(age)" } ?? age)
                .help("Saved " + item.savedAt.formatted(date: .abbreviated, time: .shortened))
        }
    }
}

/// Lead image, else a Books-like cover with the site's initial.
private struct Cover: View {
    let item: ReadingItem

    var body: some View {
        ZStack {
            placeholder
            if let s = item.imageURL, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }

    private var placeholder: some View {
        let name = item.siteName ?? item.host
        let hue = Double(name.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }) / 360
        return ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.35, brightness: 0.85),
                                    Color(hue: hue, saturation: 0.45, brightness: 0.65)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: 24, weight: .semibold, design: .serif))
                .foregroundStyle(.white.opacity(0.95))
        }
    }
}

// MARK: - All highlights

private struct AllHighlightsList: View {
    let query: String
    let open: (UUID) -> Void
    @ObservedObject private var store = ReaderStore.shared

    private var groups: [ReadingItem] {
        let q = query.lowercased()
        return store.items
            .filter { !$0.highlights.isEmpty }
            .filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.highlights.contains { $0.text.lowercased().contains(q) } }
            .sorted { ($0.highlights.map(\.createdAt).max() ?? .distantPast) > ($1.highlights.map(\.createdAt).max() ?? .distantPast) }
    }

    var body: some View {
        if groups.isEmpty {
            ContentUnavailableView("No highlights yet", systemImage: "highlighter",
                                   description: Text("Select text while reading and press H."))
        } else {
            List {
                ForEach(groups) { item in
                    Section {
                        ForEach(item.highlights) { h in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(h.text)
                                    .font(.system(size: 13, design: .serif))
                                    .padding(.leading, 10)
                                    .overlay(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 1.5).fill(Color.yellow).frame(width: 3)
                                    }
                                if let note = h.note {
                                    Text(note).font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 10)
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .onTapGesture { open(item.id) }
                        }
                    } header: {
                        Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    }
                }
            }
            .listStyle(.inset)
            .navigationTitle("Highlights")
        }
    }
}

// MARK: - Reader

private struct ArticleDetail: View {
    let item: ReadingItem
    let style: ReaderStyle
    @Binding var showHighlights: Bool
    let next: (UUID) -> Void
    @ObservedObject private var store = ReaderStore.shared
    @StateObject private var bridge = ReaderBridge()
    @State private var showStyle = false
    @AppStorage("reader.theme") private var theme = ReaderStyle.Theme.auto.rawValue
    @AppStorage("reader.font") private var font = ReaderStyle.Font.newYork.rawValue
    @AppStorage("reader.size") private var size = 19
    @AppStorage("reader.width") private var width = ReaderStyle.Width.medium.rawValue

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: style.background).ignoresSafeArea()
            content
            if item.hasContent {
                GeometryReader { g in
                    Rectangle().fill(Color.accentColor.opacity(0.7))
                        .frame(width: g.size.width * item.progress, height: 2)
                }
                .frame(height: 2)
            }
        }
        .inspector(isPresented: $showHighlights) {
            HighlightsPane(item: item, bridge: bridge)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
        .toolbar { toolbar }
        .navigationTitle(item.title)
        .navigationSubtitle(subtitle)
        .onAppear {
            store.markOpened(item.id)
            if !item.hasContent || store.articleHTML(item.id) == nil { store.refetch(item.id) }
            bridge.onKey = { key in
                switch key {
                case "e": move(to: item.location == .archive ? .inbox : .archive)
                case "l": move(to: .later)
                case "o": if let u = URL(string: item.url) { NSWorkspace.shared.open(u) }
                default: break
                }
            }
        }
        .onChange(of: style) { _, s in bridge.apply(s) }
    }

    @ViewBuilder private var content: some View {
        if item.hasContent, let html = store.articleHTML(item.id) {
            ArticleWebView(item: item, body: html, style: style, bridge: bridge)
        } else if store.fetching.contains(item.id) {
            ProgressView("Getting the article…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label(item.contentError ?? "No article text yet", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Focus couldn't get this page's text. The original is still there.")
            } actions: {
                Button("Open original") { if let u = URL(string: item.url) { NSWorkspace.shared.open(u) } }
                    .buttonStyle(.borderedProminent)
                Button("Try again") { store.refetch(item.id) }
            }
        }
    }

    private var subtitle: String {
        var parts = [item.siteName ?? item.host]
        if let m = item.readingMinutes {
            let left = Int((Double(m) * (1 - item.progress)).rounded())
            parts.append(item.progress >= 0.97 ? "Finished" : item.progress > 0.02 ? "\(max(1, left)) min left" : "\(m) min read")
        }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showStyle.toggle() } label: { Label("Appearance", systemImage: "textformat.size") }
                .help("Theme, typeface and text size")
                .popover(isPresented: $showStyle, arrowEdge: .bottom) { stylePopover }
            Button { bridge.highlightSelection() } label: { Label("Highlight", systemImage: "highlighter") }
                .help("Highlight the selected text (H)")
                .disabled(!item.hasContent)
            Button { showHighlights.toggle() } label: { Label("Highlights", systemImage: "sidebar.right") }
                .help("Highlights and notes")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if item.location != .later {
                Button { move(to: .later) } label: { Label("Later", systemImage: "clock") }.help("Read later (L)")
            }
            if item.location == .archive {
                Button { move(to: .inbox) } label: { Label("Back to Inbox", systemImage: "tray.and.arrow.up") }.help("Back to Inbox (E)")
            } else {
                Button { move(to: .archive) } label: { Label("Archive", systemImage: "archivebox") }.help("Archive (E)")
            }
            Button { if let u = URL(string: item.url) { NSWorkspace.shared.open(u) } } label: {
                Label("Open original", systemImage: "safari")
            }
            .help("Open the original page (O)")
        }
    }

    private var stylePopover: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 0) {
                Button { size = max(14, size - 1) } label: {
                    Text("A").font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: 32)
                }
                .help("Smaller text")
                Divider().frame(height: 20)
                Button { size = min(30, size + 1) } label: {
                    Text("A").font(.system(size: 20)).frame(maxWidth: .infinity, minHeight: 32)
                }
                .help("Larger text")
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))

            HStack(spacing: 14) {
                ForEach(ReaderStyle.Theme.allCases, id: \.self) { t in
                    Button { theme = t.rawValue } label: { ThemeSwatch(theme: t, selected: theme == t.rawValue) }
                        .buttonStyle(.plain)
                        .help(t.rawValue.capitalized)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 2) {
                ForEach(ReaderStyle.Font.allCases, id: \.self) { f in
                    Button { font = f.rawValue } label: {
                        HStack {
                            Text(f.name).font(f.swiftUI)
                            Spacer()
                            if font == f.rawValue { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)) }
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Picker("Width", selection: $width) {
                Text("Narrow").tag(ReaderStyle.Width.narrow.rawValue)
                Text("Medium").tag(ReaderStyle.Width.medium.rawValue)
                Text("Wide").tag(ReaderStyle.Width.wide.rawValue)
            }
            .pickerStyle(.segmented)
        }
        .padding(16)
        .frame(width: 260)
    }

    private func move(to loc: ReadingItem.Location) {
        let id = item.id
        next(id)
        store.move(id, to: loc)
    }
}

private struct ThemeSwatch: View {
    let theme: ReaderStyle.Theme
    let selected: Bool

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().fill(fill)
                if theme == .auto {
                    Circle().trim(from: 0.25, to: 0.75).fill(Color(white: 0.11)).rotationEffect(.degrees(90))
                }
                Text("Aa").font(.system(size: 12, weight: .medium, design: .serif)).foregroundStyle(ink)
            }
            .frame(width: 40, height: 40)
            .overlay(Circle().strokeBorder(selected ? Color.accentColor : .primary.opacity(0.15), lineWidth: selected ? 2.5 : 1))
            Text(theme.rawValue.capitalized).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var fill: Color {
        switch theme {
        case .auto, .white: .white
        case .sepia: Color(red: 0.973, green: 0.945, blue: 0.890)
        case .night: Color(white: 0.11)
        }
    }

    private var ink: Color {
        switch theme {
        case .night: Color(white: 0.9)
        case .sepia: Color(red: 0.29, green: 0.23, blue: 0.16)
        case .auto: .gray
        case .white: .black
        }
    }
}

private struct HighlightsPane: View {
    let item: ReadingItem
    let bridge: ReaderBridge

    var body: some View {
        Group {
            if item.highlights.isEmpty {
                ContentUnavailableView("No highlights", systemImage: "highlighter",
                                       description: Text("Select text and press H."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(item.highlights) { h in
                            HighlightCard(itemID: item.id, highlight: h, bridge: bridge)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Highlights")
    }
}

private struct HighlightCard: View {
    let itemID: UUID
    let highlight: ReadingHighlight
    let bridge: ReaderBridge
    @State private var note: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(highlight.text)
                .font(.system(size: 13, design: .serif))
                .padding(.leading, 10)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(Color.yellow).frame(width: 3) }
                .contentShape(Rectangle())
                .onTapGesture { bridge.scrollTo(highlight.id) }
                .help("Show in the article")
            TextField("Add a note", text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onChange(of: note) { _, v in ReaderStore.shared.setNote(itemID, highlight: highlight.id, note: v) }
            HStack {
                Text(highlight.createdAt.formatted(date: .abbreviated, time: .omitted))
                Spacer()
                Button("Remove") {
                    bridge.unmark(highlight.id)
                    ReaderStore.shared.removeHighlight(itemID, highlight: highlight.id)
                }
                .buttonStyle(.borderless)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
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

    func apply(_ style: ReaderStyle) {
        webView?.underPageBackgroundColor = style.background
        run("focusReader.setStyle(\(style.json))")
    }

    private func run(_ js: String) {
        webView?.evaluateJavaScript(js, in: nil, in: .defaultClient, completionHandler: nil)
    }
}

private struct ArticleWebView: NSViewRepresentable {
    let item: ReadingItem
    let body: String
    let style: ReaderStyle
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
        if Self.hasMath(body), let math = Self.mathScript {
            ucc.addUserScript(WKUserScript(source: math, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        }
        ucc.addUserScript(WKUserScript(source: "window.focusBoot = \(bootJSON);\n" + Self.readerJS,
                                       injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.underPageBackgroundColor = style.background
        bridge.webView = web
        web.loadHTMLString(page, baseURL: URL(string: item.url))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    static func hasMath(_ html: String) -> Bool {
        html.contains("\\(") || html.contains("\\[") || html.contains("$$")
    }

    /// KaTeX from the app bundle, rendering LaTeX as MathML (WebKit draws it natively,
    /// so the KaTeX font files aren't needed). Pages like Karpathy's blog use MathJax,
    /// which never runs here, so their math arrives as \( … \) source.
    static let mathScript: String? = {
        guard let dir = Bundle.focusResources?.url(forResource: "katex", withExtension: nil)
                ?? Bundle.main.url(forResource: "katex", withExtension: nil),
              let katex = try? String(contentsOf: dir.appendingPathComponent("katex.min.js"), encoding: .utf8),
              let auto = try? String(contentsOf: dir.appendingPathComponent("auto-render.min.js"), encoding: .utf8) else { return nil }
        let run = #"""
        try {
          renderMathInElement(document.getElementById('focus-body') || document.body, {
            delimiters: [{left: '$$', right: '$$', display: true}, {left: '\\[', right: '\\]', display: true}, {left: '\\(', right: '\\)', display: false}],
            output: 'mathml', throwOnError: false, ignoredTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code']
          });
        } catch {}
        """#
        return katex + "\n" + auto + "\n" + run
    }()

    private var page: String {
        let esc: (String) -> String = {
            $0.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var byline: [String] = []
        if let a = item.author, !a.isEmpty { byline.append(esc(a)) }
        if let p = item.publishedAt { byline.append(p.formatted(date: .long, time: .omitted)) }
        let minutes = item.readingMinutes.map { "\($0) min read" } ?? ""
        let px = ["narrow": 600, "medium": 690, "wide": 800][style.width.rawValue] ?? 690
        return """
        <!doctype html><html data-theme="\(style.theme.rawValue)" style="--font: \(esc(style.font.css)); --size: \(style.size)px; --width: \(px)px">
        <head><meta charset="utf-8"><style>\(Self.css)</style></head><body>
        <article>
        <header>
          <p class="site">\(esc(item.siteName ?? item.host))</p>
          <h1>\(esc(item.title))</h1>
          \(byline.isEmpty ? "" : "<p class=\"byline\">\(byline.joined(separator: " · "))</p>")
          \(minutes.isEmpty ? "" : "<p class=\"minutes\">\(minutes)</p>")
        </header>
        <div id="focus-body">\(body)</div>
        <footer class="end">
          <div class="fin">Finished?</div>
          <button id="focus-archive">Archive <kbd>E</kbd></button>
          <a href="\(esc(item.url))">Original page</a>
        </footer>
        </article></body></html>
        """
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let itemID: UUID
        let bridge: ReaderBridge
        init(itemID: UUID, bridge: ReaderBridge) { self.itemID = itemID; self.bridge = bridge }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let o = message.body as? [String: Any], let type = o["type"] as? String else { return }
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
    :root { --bg: #ffffff; --fg: #1b1c21; --muted: #6e6e73; --link: #0a5bd6; --mark: rgba(255, 204, 0, .38); --rule: rgba(0,0,0,.1); --code: rgba(0,0,0,.05); --btn: rgba(0,0,0,.06); }
    :root[data-theme=sepia] { --bg: #f8f1e3; --fg: #4a3b2a; --muted: #8a7660; --link: #8a4b14; --mark: rgba(230, 170, 40, .4); --rule: rgba(74,59,42,.15); --code: rgba(74,59,42,.07); --btn: rgba(74,59,42,.08); }
    :root[data-theme=night] { --bg: #1c1c1e; --fg: #e6e3dd; --muted: #9a9a9f; --link: #7cb8ff; --mark: rgba(255, 204, 0, .3); --rule: rgba(255,255,255,.12); --code: rgba(255,255,255,.07); --btn: rgba(255,255,255,.08); }
    @media (prefers-color-scheme: dark) { :root[data-theme=auto] { --bg: #1c1c1e; --fg: #e6e3dd; --muted: #9a9a9f; --link: #7cb8ff; --mark: rgba(255, 204, 0, .3); --rule: rgba(255,255,255,.12); --code: rgba(255,255,255,.07); --btn: rgba(255,255,255,.08); } }
    html { background: var(--bg); transition: background .25s; }
    body { margin: 0; padding: 72px 40px 140px; color: var(--fg); font-family: var(--font); font-size: var(--size); line-height: 1.65; -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility; hanging-punctuation: first; }
    article { max-width: var(--width); margin: 0 auto; }
    header { margin-bottom: 44px; }
    .site { font: 600 12px/1.3 -apple-system, system-ui, sans-serif; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); margin: 0 0 14px; }
    header h1 { font-family: var(--font); font-size: calc(var(--size) * 1.85); line-height: 1.15; font-weight: 700; margin: 0 0 16px; letter-spacing: -.012em; text-wrap: balance; }
    .byline { font: 15px/1.4 -apple-system, system-ui, sans-serif; color: var(--fg); margin: 0 0 4px; }
    .minutes { font: 13px/1.4 -apple-system, system-ui, sans-serif; color: var(--muted); margin: 0; }
    #focus-body h1, h2, h3, h4 { font-family: var(--font); line-height: 1.3; margin: 1.8em 0 .6em; text-wrap: balance; }
    #focus-body h1 { font-size: 1.6em; } h2 { font-size: 1.45em; } h3 { font-size: 1.2em; } h4 { font-size: 1.05em; }
    p, ul, ol, blockquote, pre, figure, table { margin: 0 0 1.15em; }
    p { text-wrap: pretty; }
    li { margin-bottom: .35em; }
    a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
    img, video { max-width: 100%; height: auto; border-radius: 8px; display: block; margin: 1.6em auto; }
    figure { margin: 1.8em 0; text-align: center; } figure img { margin: 0 auto; }
    img[width$="%"] { display: inline-block; margin: .4em .2%; vertical-align: top; }
    math { font-family: "STIX Two Math", math; font-size: 1.05em; } math[display=block] { margin: 1em 0; overflow-x: auto; }
    figcaption { font: 14px/1.5 -apple-system, system-ui, sans-serif; color: var(--muted); margin: .7em auto 0; max-width: 92%; text-align: center; text-wrap: pretty; }
    blockquote { border-left: 3px solid var(--rule); margin-left: 0; padding-left: 20px; font-style: italic; color: var(--muted); }
    pre, code { font: .8em/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--code); border-radius: 6px; }
    code { padding: 1px 5px; } pre { padding: 14px 16px; overflow-x: auto; } pre code { background: none; padding: 0; font-size: 1em; }
    table { border-collapse: collapse; font-size: .85em; display: block; overflow-x: auto; } td, th { border: 1px solid var(--rule); padding: 6px 10px; }
    hr { border: 0; text-align: center; margin: 2.4em 0; } hr::after { content: "· · ·"; color: var(--muted); letter-spacing: .5em; }
    ::selection { background: var(--mark); }
    mark.focus-hl { background: var(--mark); color: inherit; border-radius: 3px; padding: 0 1px; box-decoration-break: clone; -webkit-box-decoration-break: clone; }
    .end { margin-top: 72px; padding-top: 28px; border-top: 1px solid var(--rule); text-align: center; font: 13px -apple-system, system-ui, sans-serif; color: var(--muted); }
    .end .fin { font-family: var(--font); font-size: 17px; color: var(--fg); margin-bottom: 14px; }
    .end button { font: 600 14px -apple-system, system-ui, sans-serif; color: var(--fg); background: var(--btn); border: 0; border-radius: 999px; padding: 9px 18px; cursor: pointer; }
    .end button:hover { filter: brightness(.95); }
    .end kbd { font: 11px ui-monospace, Menlo, monospace; color: var(--muted); margin-left: 6px; }
    .end a { display: block; margin-top: 16px; color: var(--muted); }
    """

    private static let readerJS = #"""
    (() => {
      const boot = window.focusBoot || {};
      const post = (m) => { try { window.webkit.messageHandlers.focus.postMessage(m); } catch {} };
      const root = document.getElementById('focus-body') || document.body;
      const maxScroll = () => Math.max(1, document.documentElement.scrollHeight - innerHeight);

      // Wraps every text-node piece of `range` in <mark data-id>.
      function wrap(range, id) {
        const top = range.commonAncestorContainer.nodeType === 3 ? range.commonAncestorContainer.parentNode : range.commonAncestorContainer;
        const walker = document.createTreeWalker(top, NodeFilter.SHOW_TEXT);
        const nodes = [];
        while (walker.nextNode()) if (range.intersectsNode(walker.currentNode)) nodes.push(walker.currentNode);
        for (let node of nodes) {
          let start = node === range.startContainer ? range.startOffset : 0;
          let end = node === range.endContainer ? range.endOffset : node.length;
          if (end <= start || !node.data.slice(start, end).trim()) continue;
          if (start > 0) { node = node.splitText(start); end -= start; }
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
        setStyle(s) {
          const at = scrollY / maxScroll();
          const el = document.documentElement;
          el.dataset.theme = s.theme;
          el.style.setProperty('--font', s.font);
          el.style.setProperty('--size', s.size + 'px');
          el.style.setProperty('--width', s.width + 'px');
          requestAnimationFrame(() => scrollTo(0, at * maxScroll()));
        },
      };

      const archive = document.getElementById('focus-archive');
      if (archive) archive.addEventListener('click', () => post({ type: 'key', key: 'e' }));

      const restore = () => { if (boot.progress > 0.01 && boot.progress < 0.99) scrollTo(0, boot.progress * maxScroll()); };
      restore();
      addEventListener('load', restore);
      let t = null;
      addEventListener('scroll', () => {
        clearTimeout(t);
        t = setTimeout(() => post({ type: 'progress', value: Math.min(1, scrollY / maxScroll()) }), 500);
      }, { passive: true });

      addEventListener('keydown', (e) => {
        if (e.metaKey || e.ctrlKey || e.altKey) return;
        const k = e.key.toLowerCase();
        if (k === 'h') { focusReader.highlightSelection(); e.preventDefault(); }
        else if (k === 'j') scrollBy({ top: 140, behavior: 'smooth' });
        else if (k === 'k') scrollBy({ top: -140, behavior: 'smooth' });
        else if (['e', 'l', 'o'].includes(k)) { post({ type: 'key', key: k }); e.preventDefault(); }
      });
    })();
    """#
}
