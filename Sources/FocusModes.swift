import Combine
import Foundation
import FocusCore

/// Turns on a macOS Focus mode for the running category. Apps can't set Focus
/// directly, so it runs a user-made shortcut per mode ("Focus School" = one
/// Set Focus action); with "Share across devices" on, iPhone/iPad follow.
/// Only acts when the wanted mode changes, so a mode you set by hand stays
/// until the next switch that wants a different one.
@MainActor
final class FocusModes: ObservableObject {
    static let shared = FocusModes()

    static let modes = ["School", "Personal", "Sleep", "Off"]
    private static let mapKey = "focusModeMap"
    static let enabledKey = "focusModesOn"

    @Published private(set) var installed: Set<String> = []
    @Published private(set) var lastResult = ""
    private var applied: String?
    /// Category whose "Scene <category>" shortcut last ran.
    private var appliedScene: String?

    /// Any shortcut named "Scene <category>" ("Scene Math", "Scene Break")
    /// runs when you switch to it: Home scenes on the HomePod, lights, music.
    static func sceneName(_ category: String) -> String { "Scene \(category)" }
    private var started = false
    private var bag: AnyCancellable?

    static func shortcutName(_ mode: String) -> String { "Focus \(mode)" }

    var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// "" = leave the mode alone.
    func mode(for category: String) -> String {
        if let m = (UserDefaults.standard.dictionary(forKey: Self.mapKey) as? [String: String])?[category] { return m }
        switch category {
        case "Break": return "Off"
        case "Sleep": return "Sleep"
        case "Class": return "School"
        default: return FocusCategories.isLife(category) ? "Personal" : "School"
        }
    }

    func setMode(_ mode: String, for category: String) {
        var m = UserDefaults.standard.dictionary(forKey: Self.mapKey) as? [String: String] ?? [:]
        m[category] = mode
        UserDefaults.standard.set(m, forKey: Self.mapKey)
        objectWillChange.send()
    }

    func start(timer: TimerManager) {
        guard !started else { return }
        started = true
        refreshInstalled()
        // Launching (or redeploying) mid-block shouldn't override what you set.
        applied = wanted(timer)
        appliedScene = timer.isActive ? (timer.isOnBreak ? "Break" : timer.currentLabel) : nil
        bag = Publishers.CombineLatest3(timer.$currentLabel, timer.$currentPhase, timer.$isRunning)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self, weak timer] _ in
                guard let self, let timer else { return }
                self.update(timer)
            }
    }

    private func wanted(_ timer: TimerManager) -> String? {
        guard timer.isActive else { return nil }
        let m = mode(for: timer.isOnBreak ? "Break" : timer.currentLabel)
        return m.isEmpty ? nil : m
    }

    private func update(_ timer: TimerManager) {
        runScene(timer)
        guard enabled, let m = wanted(timer), m != applied else { return }
        applied = m
        let name = Self.shortcutName(m)
        Task.detached {
            let err = Self.run(name)
            await MainActor.run {
                self.lastResult = err ?? "Turned on \(m) at \(Date().formatted(date: .omitted, time: .shortened))"
                if err != nil { self.refreshInstalled() }
            }
        }
    }

    private func runScene(_ timer: TimerManager) {
        guard timer.isActive else { appliedScene = nil; return }
        let category = timer.isOnBreak ? "Break" : timer.currentLabel
        guard category != appliedScene else { return }
        appliedScene = category
        let name = Self.sceneName(category)
        guard installed.contains(name) else { return }
        Task.detached {
            let err = Self.run(name)
            await MainActor.run {
                self.lastResult = err ?? "Ran \(name) at \(Date().formatted(date: .omitted, time: .shortened))"
            }
        }
    }

    func refreshInstalled() {
        Task.detached {
            let list = Self.run("", listing: true) ?? ""
            let names = Set(list.split(separator: "\n").map(String.init))
            await MainActor.run { self.installed = names }
        }
    }

    /// Runs a shortcut; returns an error message, or (when listing) stdout.
    nonisolated private static func run(_ name: String, listing: Bool = false) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = listing ? ["list"] : ["run", name]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return listing ? nil : "Couldn't run Shortcuts" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if listing { return String(data: data, encoding: .utf8) }
        guard p.terminationStatus != 0 else { return nil }
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return msg.isEmpty ? "“\(name)” failed" : msg
    }
}
