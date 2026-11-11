import AppKit

/// A transparent full-screen layer that shows one instruction line and, while
/// calibrating, a target dot. It never takes the mouse or keyboard.
final class Overlay {
    private var panel: NSPanel?
    private let card = CALayer()
    private let dot = CALayer()
    private let label = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    private func build() {
        guard panel == nil, let screen = NSScreen.main else { return }
        let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        p.contentView = view

        let w: CGFloat = 380, h: CGFloat = 86
        let vis = screen.visibleFrame
        card.frame = CGRect(x: screen.frame.width / 2 - w / 2, y: vis.maxY - screen.frame.minY - h - 12, width: w, height: h)
        card.backgroundColor = NSColor(white: 0.08, alpha: 0.94).cgColor
        card.cornerRadius = 22
        card.borderWidth = 1
        card.borderColor = NSColor(white: 1, alpha: 0.1).cgColor
        view.layer?.addSublayer(card)

        label.font = .systemFont(ofSize: 17, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: card.frame.minX + 12, y: card.frame.minY + 42, width: w - 24, height: 26)
        view.addSubview(label)
        sub.font = .systemFont(ofSize: 12.5)
        sub.textColor = NSColor(white: 1, alpha: 0.62)
        sub.alignment = .center
        sub.frame = NSRect(x: card.frame.minX + 12, y: card.frame.minY + 16, width: w - 24, height: 20)
        view.addSubview(sub)

        dot.bounds = CGRect(x: 0, y: 0, width: 34, height: 34)
        dot.cornerRadius = 17
        dot.backgroundColor = NSColor.systemRed.cgColor
        dot.isHidden = true
        view.layer?.addSublayer(dot)
        panel = p
    }

    /// `target` is in 0...1 screen coordinates, y downward (nil hides the dot).
    func show(_ title: String, _ subtitle: String, target: (x: Double, y: Double)? = nil, autoHide: Double? = nil) {
        hideWork?.cancel()
        build()
        guard let p = panel, let screen = NSScreen.main else { return }
        label.stringValue = title
        sub.stringValue = subtitle
        if let t = target {
            dot.isHidden = false
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dot.position = CGPoint(x: screen.frame.width * t.x, y: screen.frame.height * (1 - t.y))
            CATransaction.commit()
            if dot.animation(forKey: "pulse") == nil {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 1; a.toValue = 0.35; a.duration = 0.8; a.autoreverses = true; a.repeatCount = .infinity
                dot.add(a, forKey: "pulse")
            }
        } else {
            dot.isHidden = true
            dot.removeAllAnimations()
        }
        p.orderFrontRegardless()
        if let s = autoHide {
            let w = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
        }
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
        dot.removeAllAnimations()
        dot.removeFromSuperlayer()
        card.removeFromSuperlayer()
    }
}
