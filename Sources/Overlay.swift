import AppKit

/// A transparent full-screen layer that shows only the red calibration dot (there is no way to point at a
/// spot on the screen from inside the window). It has no text and takes neither the mouse nor the keyboard;
/// every message lives in the main window.
final class Overlay {
    private var panel: NSPanel?
    private let dot = CALayer()
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
        dot.bounds = CGRect(x: 0, y: 0, width: 34, height: 34)
        dot.cornerRadius = 17
        dot.backgroundColor = NSColor.systemRed.cgColor
        view.layer?.addSublayer(dot)
        panel = p
    }

    /// Shows the dot at `target` (0...1 screen coordinates, y downward). Without a target nothing is shown:
    /// the title and subtitle are kept only so callers need not change; the window carries the words.
    func show(_ title: String, _ subtitle: String, target: (x: Double, y: Double)? = nil, autoHide: Double? = nil) {
        hideWork?.cancel()
        guard let t = target else { hide(); return }
        build()
        guard let p = panel, let screen = NSScreen.main else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.position = CGPoint(x: screen.frame.width * t.x, y: screen.frame.height * (1 - t.y))
        CATransaction.commit()
        if dot.animation(forKey: "pulse") == nil {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1; a.toValue = 0.35; a.duration = 0.8; a.autoreverses = true; a.repeatCount = .infinity
            dot.add(a, forKey: "pulse")
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
    }
}
