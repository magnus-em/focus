import SwiftUI
import AppKit

enum CompletionAction { case keepGoing, takeBreak, timedOut }

class CompletionPanel {
    private var panel: NSPanel?
    private var timeoutWork: DispatchWorkItem?

    func show(label: String?, onAction: @escaping (CompletionAction) -> Void) {
        dismiss()

        // Guard so onAction fires at most once
        var fired = false
        let once: (CompletionAction) -> Void = { action in
            guard !fired else { return }
            fired = true
            onAction(action)
        }

        let hosting = NSHostingView(rootView: CompletionToast(
            label: label,
            onKeepGoing: { [weak self] in self?.dismiss(); once(.keepGoing) },
            onTakeBreak: { [weak self] in self?.dismiss(); once(.takeBreak) }
        ))
        hosting.autoresizingMask = [.width, .height]

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 104),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        p.contentView = hosting
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.center()
        // orderFront (not makeKeyAndOrderFront) so the MenuBarExtra popover stays open
        p.orderFront(nil)
        panel = p

        let work = DispatchWorkItem { [weak self] in self?.dismiss(); once(.timedOut) }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.0, execute: work)
    }

    func dismiss() {
        timeoutWork?.cancel()
        timeoutWork = nil
        panel?.close()
        panel = nil
    }
}

private struct CompletionToast: View {
    let label: String?
    let onKeepGoing: () -> Void
    let onTakeBreak: () -> Void

    private let red  = Color(red: 0.96, green: 0.36, blue: 0.36)
    private let blue = Color(red: 0.27, green: 0.62, blue: 0.83)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color(red: 0.25, green: 0.72, blue: 0.53))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session complete")
                        .font(.system(size: 13, weight: .semibold))
                    if let label, !label.isEmpty {
                        Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Button(action: onKeepGoing) {
                    Text("Keep Going")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(red.opacity(0.12))
                        .foregroundStyle(red)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onTakeBreak) {
                    Text("Take a Break")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(blue.opacity(0.10))
                        .foregroundStyle(blue)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.15), radius: 16, x: 0, y: 6)
    }
}

/// Brief non-interactive confirmation for global hotkeys, so a keypress
/// from inside another app has visible feedback.
final class HotKeyToast {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(icon: String, title: String, detail: String) {
        hideWork?.cancel()
        panel?.close()

        let hosting = NSHostingView(rootView: HotKeyToastView(icon: icon, title: title, detail: detail))
        let size = hosting.fittingSize
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered, defer: false
        )
        p.contentView = hosting
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.level = .floating
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let screen = NSScreen.underMouse?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 24))
        }
        p.orderFrontRegardless()
        panel = p

        let work = DispatchWorkItem { [weak self] in
            self?.panel?.close()
            self?.panel = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }
}

private struct HotKeyToastView: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 0.96, green: 0.36, blue: 0.36))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .fixedSize()
    }
}
