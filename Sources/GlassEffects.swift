import SwiftUI
import AppKit

// Makes the hosting NSWindow AND its NSHostingView transparent so glassEffect
// refracts the actual desktop behind the popover, not a white panel.
struct WindowTransparencyConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            // NSHostingView (the SwiftUI host) sits as a subview of contentView
            // and has its own opaque background — clear it too.
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
            window.contentView?.subviews.forEach { sub in
                sub.wantsLayer = true
                sub.layer?.backgroundColor = NSColor.clear.cgColor
            }
            // The MenuBarExtra panel ships its own NSVisualEffectView; left in place it
            // frosts the desktop before our clear glass ever sees it.
            if let frame = window.contentView?.superview { Self.hideVibrancy(in: frame, sparing: view) }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    // Only hides blur views that don't contain our own content, so a panel whose
    // content lives inside its NSVisualEffectView is left alone.
    private static func hideVibrancy(in root: NSView, sparing ours: NSView) {
        for sub in root.subviews {
            if let fx = sub as? NSVisualEffectView, !ours.isDescendant(of: fx) {
                fx.isHidden = true
                continue
            }
            hideVibrancy(in: sub, sparing: ours)
        }
    }
}

extension View {
    @ViewBuilder
    func glassCard<S: InsettableShape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.clear, in: shape)
        } else {
            self
                .background(shape.fill(.thinMaterial))
                .overlay(shape.strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        }
    }

    func glassCard(cornerRadius: CGFloat = 12) -> some View {
        glassCard(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // No panel glass at all: the desktop shows straight through and only the
    // cards/chips/controls are (clear) glass. A second glass layer under them
    // is what made the popover read as frosted.
    @ViewBuilder
    func popoverBackground() -> some View {
        if #available(macOS 26.0, *) {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            self
                .background(WindowTransparencyConfigurator().frame(width: 0, height: 0))
                .contentShape(shape)
                .overlay(shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.08)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75))
        } else {
            self.background(.regularMaterial)
        }
    }

    /// The popover itself is the one glass layer (a Maps-style sheet); inside
    /// it everything is plain fills, tinted by the running category's wash.
    @ViewBuilder
    func popoverPanel(tint: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        if #available(macOS 26.0, *) {
            self
                .background { CategoryWash(color: tint).clipShape(shape) }
                .background(WindowTransparencyConfigurator().frame(width: 0, height: 0))
                .glassEffect(.regular, in: shape)
                .contentShape(shape)
        } else {
            self
                .background { CategoryWash(color: tint) }
                .background(.regularMaterial)
        }
    }

    // Kept for any other callers.
    @ViewBuilder
    func glassChrome() -> some View {
        if #available(macOS 26.0, *) {
            self.background(.clear)
        } else {
            self.background(.regularMaterial)
        }
    }

    @ViewBuilder
    func glassChip(in shape: some InsettableShape = Capsule(), selected: Bool = false, tint: Color = .accentColor) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(selected ? .clear.tint(tint.opacity(0.35)).interactive() : .clear.interactive(), in: shape)
        } else {
            self.background(shape.fill(selected ? AnyShapeStyle(tint.opacity(0.15)) : AnyShapeStyle(.thinMaterial)))
        }
    }

    // Tab chip: only the selected tab gets the tinted glass pill.
    // Unselected tabs are plain icons — matches iOS 26 tab bar best practice.
    @ViewBuilder
    func glassTabChip(selected: Bool, tint: Color = Color.accentColor) -> some View {
        if selected {
            if #available(macOS 26.0, *) {
                self.glassEffect(.clear.interactive().tint(tint.opacity(0.5)), in: Capsule())
            } else {
                self.background(Capsule().fill(tint.opacity(0.12)))
            }
        } else {
            self
        }
    }
}

@ViewBuilder
func glassChipGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    if #available(macOS 26.0, *) {
        GlassEffectContainer { content() }
    } else {
        content()
    }
}

/// Slow-drifting colour field that sits behind glass surfaces. Liquid Glass
/// only reads as glass when there is something vivid behind it to refract;
/// over a flat panel (or over other glass) it renders as a plain tint.
struct AmbientBackdrop: View {
    var colors: [Color]
    var intensity: Double = 0.6
    var speed: Double = 0.15
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if #available(macOS 15.0, *) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                MeshGradient(width: 3, height: 3, points: Self.points(t), colors: meshColors)
            }
            .opacity(intensity)
        } else {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(intensity * 0.6)
        }
    }

    private var meshColors: [Color] {
        let c = colors.isEmpty ? [Color.accentColor] : colors
        func at(_ i: Int) -> Color { c[i % c.count] }
        let clear = Color.clear
        return [at(0), clear, at(1),
                clear, at(2), clear,
                at(1), clear, at(0)]
    }

    private static func points(_ t: Double) -> [SIMD2<Float>] {
        func w(_ phase: Double, _ amp: Double) -> Float { Float(sin(t + phase) * amp) }
        return [
            [0, 0], [0.5 + w(0, 0.25), 0], [1, 0],
            [0, 0.5 + w(1.3, 0.25)], [0.5 + w(2.1, 0.22), 0.5 + w(0.7, 0.22)], [1, 0.5 + w(2.9, 0.25)],
            [0, 1], [0.5 + w(3.7, 0.25), 1], [1, 1],
        ]
    }
}
