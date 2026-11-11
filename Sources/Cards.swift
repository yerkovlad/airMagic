import SwiftUI

// The setup cards: an animated "how it works", calibration, the three-knock test
// and the practice pad where the pointer is virtual (nothing on the Mac is clicked).

// MARK: how it works

/// A looping drawing of the four things to do: open the lid, close it, set the case
/// upright, point and knock. `fixed` pins one of them.
struct DemoView: View {
    var fixed: Int? = nil
    /// 0 aim in the air, 1 gyro mouse, 2 slide on a surface
    var kind = 0

    private var captions: [String] {
        switch kind {
        case 2: return ["Open the lid", "Close the lid", "Lay it flat on the desk", "Slide it like a mouse, knock to click"]
        case 1: return ["Open the lid", "Close the lid", "Hold it upright, light facing you", "Turn it to move the cursor, knock to click"]
        default: return ["Open the lid", "Close the lid", "Set it upright, light facing you", "Point at the screen, knock to click"]
        }
    }
    private var hints: [String] {
        switch kind {
        case 2: return ["Both AirPods inside, near your Mac.", "The case keeps sending motion with the lid shut.",
                        "Any smooth surface works, like a mousepad.", "Slide it to move the cursor. Lift it to pause."]
        case 1: return ["Both AirPods inside, near your Mac.", "The case keeps sending motion with the lid shut.",
                        "Like a small remote.", "Like an air mouse: the cursor moves while you turn it."]
        default: return ["Both AirPods inside, near your Mac.", "The case keeps sending motion with the lid shut.",
                         "Hold it like a small remote.", "Move the case to move the cursor."]
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let length = 3.4
            let step = fixed ?? (Int(t / length) % 4)
            let p = t.truncatingRemainder(dividingBy: length) / length
            VStack(spacing: 6) {
                Canvas { ctx, size in DemoView.draw(ctx, size, step, p, t, kind) }
                    .frame(height: 150)
                Text(captions[step]).font(.headline)
                Text(hints[step]).font(.caption).foregroundStyle(.secondary)
                if fixed == nil {
                    HStack(spacing: 6) {
                        ForEach(0..<4, id: \.self) { i in
                            Circle().fill(step == i ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    static func draw(_ ctx: GraphicsContext, _ size: CGSize, _ step: Int, _ p: Double, _ t: Double, _ kind: Int) {
        let ink = Color.primary.opacity(0.85)
        let soft = Color.secondary.opacity(0.3)
        let cx = size.width / 2, cy = size.height / 2
        let e = ease((p - 0.15) / 0.55)

        if kind == 2 && step >= 2 {
            drawDesk(ctx, size, step, p, t, e, ink, soft)
            return
        }


        switch step {
        case 0, 1:
            // side view: the lid swings on a hinge at the back
            let open = step == 0 ? e : 1 - e
            let top = cy + 16
            let body = CGRect(x: cx - 45, y: top, width: 90, height: 40)
            ctx.fill(Path(roundedRect: body, cornerRadius: 11), with: .color(soft))
            ctx.stroke(Path(roundedRect: body, cornerRadius: 11), with: .color(ink), lineWidth: 2)
            if open > 0.25 {
                for dx in [-17.0, 17.0] {
                    let bud = CGRect(x: cx + dx - 8, y: top - 12, width: 16, height: 20)
                    ctx.fill(Path(ellipseIn: bud), with: .color(Color.white.opacity(0.92)))
                    ctx.stroke(Path(ellipseIn: bud), with: .color(ink), lineWidth: 1.5)
                }
            }
            var lidContext = ctx
            lidContext.translateBy(x: cx - 45, y: top)
            lidContext.rotate(by: .degrees(-115 * open))
            let lid = CGRect(x: 0, y: -14, width: 90, height: 14)
            lidContext.fill(Path(roundedRect: lid, cornerRadius: 7), with: .color(Color.accentColor.opacity(0.3)))
            lidContext.stroke(Path(roundedRect: lid, cornerRadius: 7), with: .color(ink), lineWidth: 2)
        case 2:
            // front view: the case stands up from lying on its side
            var c = ctx
            c.translateBy(x: cx, y: cy)
            c.rotate(by: .degrees(-90 * (1 - e)))
            let body = CGRect(x: -34, y: -48, width: 68, height: 96)
            c.fill(Path(roundedRect: body, cornerRadius: 24), with: .color(soft))
            c.stroke(Path(roundedRect: body, cornerRadius: 24), with: .color(ink), lineWidth: 2)
            var seam = Path()
            seam.move(to: CGPoint(x: -34, y: -18)); seam.addLine(to: CGPoint(x: 34, y: -18))
            c.stroke(seam, with: .color(ink.opacity(0.6)), lineWidth: 1.5)
            let led = CGRect(x: -4, y: 24, width: 8, height: 8)
            c.fill(Path(ellipseIn: led), with: .color(e > 0.6 ? Color.green : Color.secondary.opacity(0.4)))
        default:
            // the screen on the right, the case on the left, a knock at the end
            let screen = CGRect(x: cx + 6, y: cy - 50, width: 134, height: 84)
            ctx.fill(Path(roundedRect: screen, cornerRadius: 8), with: .color(soft))
            ctx.stroke(Path(roundedRect: screen, cornerRadius: 8), with: .color(ink), lineWidth: 2)
            let sway = sin(t * 1.5)
            let dot = CGPoint(x: screen.midX + sway * 46, y: screen.midY + cos(t * 1.1) * 18)
            ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 6, y: dot.y - 6, width: 12, height: 12)), with: .color(Color.accentColor))

            var c = ctx
            c.translateBy(x: cx - 74, y: cy + 2)
            c.rotate(by: .degrees(sway * 14))
            let body = CGRect(x: -17, y: -27, width: 34, height: 54)
            c.fill(Path(roundedRect: body, cornerRadius: 12), with: .color(Color.white.opacity(0.9)))
            c.stroke(Path(roundedRect: body, cornerRadius: 12), with: .color(ink), lineWidth: 2)
            if p > 0.72 {
                let k = (p - 0.72) / 0.28
                for ring in 0..<2 {
                    let r = 24 + 26 * k + Double(ring) * 12
                    c.stroke(Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)),
                             with: .color(Color.accentColor.opacity(0.7 * (1 - k))), lineWidth: 2)
                }
                let r = 8 + 16 * k
                ctx.stroke(Path(ellipseIn: CGRect(x: dot.x - r, y: dot.y - r, width: r * 2, height: r * 2)),
                           with: .color(Color.accentColor.opacity(1 - k)), lineWidth: 2)
            }
        }
    }
}

private func ease(_ x: Double) -> Double {
    let c = min(max(x, 0), 1)
    return c * c * (3 - 2 * c)
}

// MARK: recording

/// Shown while the sliding test is being recorded: what to do now, and how long is left.
struct RecordCard: View {
    @ObservedObject var m: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Label("Recording", systemImage: "record.circle").font(.headline).foregroundStyle(.red)
            Text(m.recordPrompt)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(minHeight: 56)
            ProgressView(value: m.recordProgress) {
                Text(String(format: "%.0f s left", m.recordRemaining)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Button("Stop and save", action: m.actions.stopRecording)
        }
        .frame(maxWidth: .infinity)
    }
}

extension DemoView {
    /// The slide-mode pictures: a desk seen from the side, the case on it, a small screen above.
    fileprivate static func drawDesk(_ ctx: GraphicsContext, _ size: CGSize, _ step: Int, _ p: Double, _ t: Double,
                                     _ e: Double, _ ink: Color, _ soft: Color) {
        let cx = size.width / 2, cy = size.height / 2
        let deskY = cy + 34
        var line = Path()
        line.move(to: CGPoint(x: cx - 140, y: deskY)); line.addLine(to: CGPoint(x: cx + 140, y: deskY))
        ctx.stroke(line, with: .color(ink.opacity(0.6)), lineWidth: 2)

        let body = CGSize(width: 76, height: 22)
        if step == 2 {
            let lift = 34 * (1 - e)
            let rect = CGRect(x: cx - body.width / 2, y: deskY - body.height - lift, width: body.width, height: body.height)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 9), with: .color(Color.white.opacity(0.9)))
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 9), with: .color(ink), lineWidth: 2)
        } else {
            let sway = sin(t * 1.4)
            let x = cx - 40 + sway * 46
            let rect = CGRect(x: x - body.width / 2, y: deskY - body.height, width: body.width, height: body.height)
            for k in 1...3 {
                let trail = rect.offsetBy(dx: -(sway < 0 ? -1.0 : 1.0) * Double(k) * 10, dy: 0)
                ctx.fill(Path(roundedRect: trail, cornerRadius: 9), with: .color(Color.accentColor.opacity(0.12 / Double(k))))
            }
            ctx.fill(Path(roundedRect: rect, cornerRadius: 9), with: .color(Color.white.opacity(0.9)))
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 9), with: .color(ink), lineWidth: 2)

            let screen = CGRect(x: cx + 40, y: cy - 62, width: 100, height: 62)
            ctx.fill(Path(roundedRect: screen, cornerRadius: 8), with: .color(soft))
            ctx.stroke(Path(roundedRect: screen, cornerRadius: 8), with: .color(ink), lineWidth: 2)
            let dot = CGPoint(x: screen.midX + sway * 34, y: screen.midY)
            ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 6, y: dot.y - 6, width: 12, height: 12)), with: .color(Color.accentColor))
            if p > 0.78 {
                let k = (p - 0.78) / 0.22
                let r = 8 + 18 * k
                ctx.stroke(Path(ellipseIn: CGRect(x: dot.x - r, y: dot.y - r, width: r * 2, height: r * 2)),
                           with: .color(Color.accentColor.opacity(1 - k)), lineWidth: 2)
            }
        }
    }
}

// MARK: permissions

struct PermissionsCard: View {
    @ObservedObject var m: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allow two things first").font(.headline)
            Text("AirMagic needs Bluetooth to talk to your AirPods and Accessibility to move the cursor.")
                .font(.callout).foregroundStyle(.secondary)
            row("Accessibility", ok: m.accessibilityOK, action: m.actions.openAccessibility)
            row("Bluetooth", ok: m.bluetoothOK, action: m.actions.openBluetooth)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ name: String, ok: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(name)
            Spacer()
            if !ok { Button("Open Settings", action: action) }
        }
    }
}

// MARK: sliding

/// The two calibration strokes of slide mode: to the right, then away from you.
struct SlideCard: View {
    @ObservedObject var m: AppModel
    let step: Int

    var body: some View {
        VStack(spacing: 10) {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    let cx = size.width / 2, cy = size.height / 2
                    let desk = CGRect(x: cx - 120, y: cy - 62, width: 240, height: 124)
                    ctx.fill(Path(roundedRect: desk, cornerRadius: 14), with: .color(Color.secondary.opacity(0.12)))
                    ctx.stroke(Path(roundedRect: desk, cornerRadius: 14), with: .color(Color.secondary.opacity(0.5)), lineWidth: 1)
                    let direction = step == 0 ? CGPoint(x: 1, y: 0) : CGPoint(x: 0, y: -1)
                    let phase = (t.truncatingRemainder(dividingBy: 1.8)) / 1.8
                    let e = ease(phase / 0.7)
                    let reach = step == 0 ? 70.0 : 36.0
                    let from = CGPoint(x: cx - direction.x * reach * 0.5, y: cy - direction.y * reach * 0.5)
                    let pos = CGPoint(x: from.x + direction.x * reach * e, y: from.y + direction.y * reach * e)
                    var arrow = Path()
                    let a = CGPoint(x: cx - direction.x * 90, y: cy - direction.y * 50)
                    let b = CGPoint(x: cx + direction.x * 90, y: cy + direction.y * 50)
                    arrow.move(to: a); arrow.addLine(to: b)
                    let head = 9.0
                    arrow.move(to: b)
                    arrow.addLine(to: CGPoint(x: b.x - direction.x * head - direction.y * head, y: b.y - direction.y * head + direction.x * head))
                    arrow.move(to: b)
                    arrow.addLine(to: CGPoint(x: b.x - direction.x * head + direction.y * head, y: b.y - direction.y * head - direction.x * head))
                    ctx.stroke(arrow, with: .color(Color.accentColor.opacity(0.7)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    let rect = CGRect(x: pos.x - 30, y: pos.y - 18, width: 60, height: 36)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 14), with: .color(Color.white.opacity(0.92)))
                    ctx.stroke(Path(roundedRect: rect, cornerRadius: 14), with: .color(Color.primary.opacity(0.8)), lineWidth: 2)
                }
                .frame(height: 150)
            }
            Text(step == 0 ? "Slide the case to the right" : "Now slide it away from you").font(.headline)
            Text("About 10 cm along the desk, flat on the surface, in one smooth push, then stop.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let hint = m.mouseHint {
                Label(hint, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }
            ProgressView(value: min(m.slideLevel / 0.12, 1)) {
                Text("Motion: \(m.slideState)").font(.caption).foregroundStyle(.secondary)
            }
            Button("Start over", action: m.actions.recalibrate)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: turning

/// The two calibration turns of the gyro mouse: to the right, then up.
struct GyroCard: View {
    @ObservedObject var m: AppModel
    let step: Int

    var body: some View {
        VStack(spacing: 10) {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    let cx = size.width / 2, cy = size.height / 2
                    let phase = (t.truncatingRemainder(dividingBy: 2.0)) / 2.0
                    let swing = phase < 0.5 ? ease(phase / 0.5) : 1 - ease((phase - 0.5) / 0.5)
                    // the case, turning: squeezed sideways for a turn to the right, squashed for a tip up
                    var c = ctx
                    c.translateBy(x: cx, y: cy)
                    let squeeze = 1 - 0.35 * swing
                    if step == 0 { c.scaleBy(x: squeeze, y: 1) } else { c.scaleBy(x: 1, y: squeeze) }
                    let body = CGRect(x: -32, y: -48, width: 64, height: 96)
                    c.fill(Path(roundedRect: body, cornerRadius: 22), with: .color(Color.white.opacity(0.92)))
                    c.stroke(Path(roundedRect: body, cornerRadius: 22), with: .color(Color.primary.opacity(0.8)), lineWidth: 2)
                    // the arrow it follows
                    var arrow = Path()
                    let head = 10.0
                    if step == 0 {
                        let a = CGPoint(x: cx + 56, y: cy), b = CGPoint(x: cx + 120, y: cy)
                        arrow.move(to: a); arrow.addLine(to: b)
                        arrow.move(to: b); arrow.addLine(to: CGPoint(x: b.x - head, y: b.y - head))
                        arrow.move(to: b); arrow.addLine(to: CGPoint(x: b.x - head, y: b.y + head))
                    } else {
                        let a = CGPoint(x: cx, y: cy - 60), b = CGPoint(x: cx, y: cy - 66 - 18)
                        arrow.move(to: a); arrow.addLine(to: b)
                        arrow.move(to: b); arrow.addLine(to: CGPoint(x: b.x - head, y: b.y + head))
                        arrow.move(to: b); arrow.addLine(to: CGPoint(x: b.x + head, y: b.y + head))
                    }
                    ctx.stroke(arrow, with: .color(Color.accentColor.opacity(0.4 + 0.5 * swing)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
                .frame(height: 150)
            }
            Text(step == 0 ? "Turn the case to the right" : "Now tip the top of the case up").font(.headline)
            Text("Hold it upright, pointing at the screen. Turn about 30\u{00B0}, then hold still for a moment.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let hint = m.mouseHint {
                Label(hint, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }
            ProgressView(value: min(m.mouseSpin / 25, 1)) {
                Text(String(format: "Turned %.0f\u{00B0}", m.mouseSpin)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Button("Start over", action: m.actions.recalibrate)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: calibration

struct CalibrationCard: View {
    @ObservedObject var m: AppModel
    let step: Int

    private static let targets: [CGPoint] = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.97, y: 0.5), CGPoint(x: 0.5, y: 0.04)]
    private static let names = ["the middle", "the right edge", "the top edge"]

    var body: some View {
        VStack(spacing: 10) {
            Canvas { ctx, size in
                let r = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                ctx.fill(Path(roundedRect: r, cornerRadius: 10), with: .color(Color.black.opacity(0.3)))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 10), with: .color(Color.secondary.opacity(0.5)), lineWidth: 1)
                for (i, t) in Self.targets.enumerated() {
                    let c = CGPoint(x: r.minX + 6 + t.x * (r.width - 12), y: r.minY + 6 + t.y * (r.height - 12))
                    if i < step {
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(Color.green))
                    } else if i == step {
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)), with: .color(Color.red))
                        var arc = Path()
                        arc.addArc(center: c, radius: 13, startAngle: .degrees(-90),
                                   endAngle: .degrees(-90 + 360 * m.holdProgress), clockwise: false)
                        ctx.stroke(arc, with: .color(Color.accentColor), lineWidth: 3)
                    } else {
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)),
                                   with: .color(Color.secondary.opacity(0.6)), lineWidth: 1.5)
                    }
                }
            }
            .aspectRatio(1.6, contentMode: .fit)
            .frame(maxHeight: 170)

            Text("Point at \(Self.names[min(step, 2)])").font(.headline)
            Text("Aim the case at the red dot on your screen and hold steady. It confirms by itself.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            ProgressView(value: m.holdProgress)
            HStack {
                Button("Confirm now", action: m.actions.confirmStep)
                Button("Start over", action: m.actions.recalibrate)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: three knocks

struct TapTestCard: View {
    @ObservedObject var m: AppModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 18) {
                ForEach(0..<3, id: \.self) { i in
                    ZStack {
                        Circle().fill(i < m.tapTestCount ? Color.green : Color.secondary.opacity(0.22))
                        if i < m.tapTestCount {
                            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 38, height: 38)
                    .animation(.easeOut(duration: 0.2), value: m.tapTestCount)
                }
            }
            Text("Knock on the front of the case three times").font(.headline)
            Text("Keep the case still between knocks. A short, sharp tap with a fingertip counts; moving it around does not.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            ProgressView(value: min(m.noise / 1.0, 1)) {
                Text(String(format: "Sensor now %.2f g \u{00B7} last knock %.2f g", m.noise, m.lastKnock))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Button("Skip", action: m.actions.skipTapTest)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: practice

/// A small screen where the pointer is virtual. Knocks and holds land on the circles;
/// nothing on the Mac is clicked until you press Start pointing.
struct PracticePad: View {
    @ObservedObject var m: AppModel

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let r = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                ctx.fill(Path(roundedRect: r, cornerRadius: 12), with: .color(Color.black.opacity(0.35)))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 12), with: .color(Color.secondary.opacity(0.5)), lineWidth: 1)
                let radius = size.height * 0.075
                for (i, t) in AppModel.practiceTargets.enumerated() {
                    let c = CGPoint(x: t.x * size.width, y: t.y * size.height)
                    let box = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
                    let hit = m.practiceHits.contains(i)
                    ctx.fill(Path(ellipseIn: box), with: .color(hit ? Color.green.opacity(0.85) : Color.secondary.opacity(0.16)))
                    ctx.stroke(Path(ellipseIn: box), with: .color(hit ? Color.green : Color.secondary.opacity(0.6)), lineWidth: 2)
                }
                if let click = m.practiceClick {
                    let age = timeline.date.timeIntervalSince(click.time)
                    if age >= 0, age < 0.7 {
                        let k = age / 0.7
                        let c = CGPoint(x: click.pos.x * size.width, y: click.pos.y * size.height)
                        let rr = 8 + 26 * k
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                                   with: .color(Color.accentColor.opacity(1 - k)), lineWidth: 3)
                    }
                }
                if let p = m.pos {
                    let x = min(max(p.x, 0), 1) * size.width, y = min(max(p.y, 0), 1) * size.height
                    let off = p.x < 0 || p.x > 1 || p.y < 0 || p.y > 1
                    let color = off ? Color.orange : Color.accentColor
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 14, y: y - 14, width: 28, height: 28)), with: .color(color.opacity(0.2)))
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 6, y: y - 6, width: 12, height: 12)), with: .color(color))
                }
            }
        }
        .aspectRatio(1.6, contentMode: .fit)
    }
}
