import AppKit
import QuartzCore
import CoreGraphics

/// Borderless full-display window that can take focus, so a break actually
/// interrupts you instead of quietly sitting behind the front app.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class OverlayScreen {
    let window: OverlayWindow
    let view: OverlayView
    let capture: ScreenCapture?
    let countdown: NSTextField?
    let caption: NSTextField?
    let hint: NSTextField?
    let panel: NSView?

    init(window: OverlayWindow, view: OverlayView, capture: ScreenCapture?,
         countdown: NSTextField?, caption: NSTextField?, hint: NSTextField?, panel: NSView?) {
        self.window = window; self.view = view; self.capture = capture
        self.countdown = countdown; self.caption = caption; self.hint = hint
        self.panel = panel
    }
}

private func sstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

/// Owns the break itself: the overlay windows, the swallow/hold/release arc and
/// the escape hatch.
final class BreakController {

    private enum Phase { case idle, waiting, swallow, hold, release }

    private let baseSwallowDur = 14.0
    private let baseReleaseDur = 8.0
    private let baseLoopPeriod = 75.0
    private let escHoldToSkip = 1.0
    /// How far the pointer must travel, in points, before the break gives way.
    private let mouseToDismiss: CGFloat = 45
    /// Ignore the pointer briefly at the start; a hand is usually still on it.
    private let mouseGrace = 1.5

    // Resolved per break from the speed setting.
    private var swallowDur = 14.0
    private var releaseDur = 8.0

    private var screens: [OverlayScreen] = []
    private var link: CADisplayLink?
    private var monitor: Any?

    private var phase: Phase = .idle
    private var phaseStart = CACurrentMediaTime()
    private var holdDur = 600.0
    private var escSince: CFTimeInterval?
    private var mouseAnchor: NSPoint?
    private var mouseArmedAt: CFTimeInterval = 0
    private var pendingCaptures = 0
    private var waitDeadline: CFTimeInterval = 0

    /// Called when the break finishes, with `true` if the user skipped it.
    var onEnd: ((Bool) -> Void)?

    var isRunning: Bool { phase != .idle }

    // MARK: - Lifecycle

    func begin(seconds: Double) {
        guard phase == .idle else { return }

        var sw = baseSwallowDur / speed
        var rl = baseReleaseDur / speed
        // A slow speed must not make the crossings outlast the break itself.
        let budget = max(seconds - 2, 1)
        if sw + rl > budget {
            let k = budget / (sw + rl)
            sw *= k; rl *= k
        }
        swallowDur = sw
        releaseDur = rl
        holdDur = max(seconds - sw - rl, 2)
        buildScreens()
        guard !screens.isEmpty else { onEnd?(false); return }

        NSApp.activate()
        screens.first?.window.makeKeyAndOrderFront(nil)
        EHLog.write("break begin: \(screens.count) screen(s), "
                    + "capture granted=\(CGPreflightScreenCaptureAccess()), "
                    + "speed=\(speed)x loop=\(loops) consume=\(consumeScreen) "
                    + String(format: "swallow=%.1fs release=%.1fs hold=%.1fs",
                             swallowDur, releaseDur, holdDur))

        installKeyMonitor()
        startLink()

        // The windows are already on screen (fully transparent) so the capture
        // filter can exclude our own app. Wait for real frames before the
        // swallow starts, otherwise it would eat an empty texture.
        phase = .waiting
        phaseStart = CACurrentMediaTime()
        waitDeadline = phaseStart + 1.5
        mouseAnchor = nil
        mouseArmedAt = phaseStart + mouseGrace
        startCaptures()
    }

    func skip() { endNow(skipped: true) }

    private func endNow(skipped: Bool) {
        guard phase != .idle else { return }
        phase = .idle
        escSince = nil
        mouseAnchor = nil
        link?.invalidate(); link = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        for s in screens {
            s.capture?.stop()
            s.window.orderOut(nil)
        }
        screens = []
        onEnd?(skipped)
    }

    // MARK: - Setup

    private func buildScreens() {
        let main = NSScreen.main
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }

            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.setFrame(screen.frame, display: false)

            let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            root.wantsLayer = true
            let view = OverlayView(frame: root.bounds)
            view.autoresizingMask = [.width, .height]
            view.phase = Float(screens.count) * 3.7
            view.resetClock()
            root.addSubview(view)

            var countdown: NSTextField?
            var caption: NSTextField?
            var hint: NSTextField?
            var panel: NSView?
            if screen == main {
                countdown = Self.label(size: 84, weight: .thin, alpha: 0.92, mono: true)
                caption = Self.label(size: 17, weight: .regular, alpha: 0.5, mono: false)
                caption?.stringValue = "Look away from the screen"
                hint = Self.label(size: 12, weight: .regular, alpha: 0.32, mono: false)
                hint?.stringValue = "move the mouse to end the break"
                let h = root.bounds.height, w = root.bounds.width
                // The desktop stays visible behind the text now, so it needs its
                // own backdrop to stay readable over arbitrary content.
                let box = NSView(frame: NSRect(x: w / 2 - 300, y: h * 0.085 - 26,
                                               width: 600, height: h * 0.115 + 154))
                box.wantsLayer = true
                box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
                box.layer?.cornerRadius = 24
                box.alphaValue = 0
                root.addSubview(box)
                panel = box
                for (l, y, hh) in [(countdown!, h * 0.20, 110.0), (caption!, h * 0.155, 26.0),
                                   (hint!, h * 0.085, 18.0)] {
                    l.alphaValue = 0
                    l.frame = NSRect(x: 0, y: y, width: w, height: hh)
                    root.addSubview(l)
                }
            }

            w.contentView = root
            w.orderFrontRegardless()

            let cap = ScreenCapture(device: MTLCreateSystemDefaultDevice()!)
            view.capture = cap
            screens.append(OverlayScreen(window: w, view: view, capture: cap,
                                         countdown: countdown, caption: caption,
                                         hint: hint, panel: panel))
            _ = id
        }
    }

    private static func label(size: CGFloat, weight: NSFont.Weight,
                              alpha: CGFloat, mono: Bool) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = mono
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        l.textColor = NSColor.white.withAlphaComponent(alpha)
        l.alignment = .center
        l.backgroundColor = .clear
        l.isBezeled = false
        l.isEditable = false
        return l
    }

    private func startCaptures() {
        pendingCaptures = screens.count
        for s in screens {
            guard let cap = s.capture,
                  let id = s.window.screen?.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                pendingCaptures -= 1
                continue
            }
            let scale = s.window.screen?.backingScaleFactor ?? 2
            Task { @MainActor in
                do {
                    try await cap.start(displayID: CGDirectDisplayID(id.uint32Value), scale: scale) {
                        DispatchQueue.main.async { [weak self] in
                            self?.pendingCaptures -= 1
                        }
                    }
                } catch {
                    EHLog.write("capture FAILED: \(error.localizedDescription)")
                    self.pendingCaptures -= 1
                }
            }
        }
    }

    /// Without capture the overlay is just an opaque starfield, which is
    /// indistinguishable from a lock screen. Say what is actually wrong.
    private func showCaptureNotice() {
        for s in screens {
            s.caption?.stringValue = "Screen Recording permission needed"
            s.hint?.stringValue = "menu bar → Allow Screen Recording, then relaunch"
        }
    }

    private func installKeyMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] e in
            guard let self, self.phase != .idle else { return e }
            if e.type != .keyDown && e.type != .keyUp {
                if CACurrentMediaTime() >= self.mouseArmedAt {
                    EHLog.write("break dismissed by click")
                    self.skip()
                }
                return nil
            }
            if e.keyCode == 53 {                       // esc
                if e.type == .keyDown {
                    if self.escSince == nil { self.escSince = CACurrentMediaTime() }
                } else {
                    self.escSince = nil
                }
            }
            return nil                                  // swallow everything else
        }
    }

    /// Right to left unless the user has flipped it.
    private var leftToRight: Bool { UserDefaults.standard.bool(forKey: "sweepLeftToRight") }

    /// Off by default: the hole travels over your screen and only touches what
    /// it is passing. Turn it on to have it clear the whole display instead.
    private var consumeScreen: Bool { UserDefaults.standard.bool(forKey: "consumeScreen") }

    /// 1.0 is normal; lower is slower. Scales the crossings and the disk alike.
    private var speed: Double {
        let v = UserDefaults.standard.double(forKey: "animationSpeed")
        return v > 0 ? v : 1
    }

    /// Whether the hole keeps crossing for the whole break or parks after one pass.
    private var loops: Bool { UserDefaults.standard.bool(forKey: "loopAnimation") }

    /// Positions the hole for one pass across the display and sets which side of
    /// its trailing front still holds desktop. `eating` consumes behind it,
    /// otherwise it hands the desktop back.
    private func sweep(_ q: Double, eating: Bool, into arc: inout ArcState) {
        let ltr = leftToRight
        let e = sstep(0, 1, q)
        arc.holeX = ltr ? CGFloat(-0.18 + 1.36 * e) : CGFloat(1.18 - 1.36 * e)
        arc.frontX = arc.holeX + (ltr ? -0.09 : 0.09)
        guard consumeScreen else {
            arc.mixLeft = 1; arc.mixRight = 1      // desktop stays, everywhere
            return
        }
        let behind: Float = eating ? 0 : 1     // side it has already crossed
        let ahead: Float = eating ? 1 : 0
        arc.mixLeft = ltr ? behind : ahead
        arc.mixRight = ltr ? ahead : behind
    }

    private func startLink() {
        guard let v = screens.first?.view else { return }
        let l = v.displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    // MARK: - Arc

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = now - phaseStart

        if let since = escSince, now - since >= escHoldToSkip { skip(); return }

        // Moving the pointer ends the break. Anchored only after the grace
        // period, so a hand resting on the mouse when it starts is not a skip.
        if now >= mouseArmedAt {
            let p = NSEvent.mouseLocation
            if let anchor = mouseAnchor {
                if hypot(p.x - anchor.x, p.y - anchor.y) >= mouseToDismiss {
                    EHLog.write("break dismissed by pointer movement")
                    skip(); return
                }
            } else {
                mouseAnchor = p
            }
        }

        var arc = ArcState()
        var labelAlpha = 0.0
        var remaining = 0.0

        switch phase {
        case .idle:
            return

        case .waiting:
            if pendingCaptures <= 0 || now >= waitDeadline {
                let live = screens.filter { $0.capture?.texture != nil }.count
                EHLog.write("swallow start: \(live)/\(screens.count) screens have desktop"
                            + (now >= waitDeadline ? " (timed out waiting)" : ""))
                if live == 0 { showCaptureNotice() }
                phase = .swallow
                phaseStart = now
            }
            arc.fade = 0

        case .swallow:
            // Crosses the screen eating as it goes. Only the neighbourhood of
            // the hole is distorted at any instant; what it has already passed
            // is left as empty sky, so the desktop empties left to right.
            let q = min(elapsed / swallowDur, 1)
            arc.fade = Float(sstep(0, 0.06, q))
            sweep(q, eating: true, into: &arc)
            arc.holePoints = 40 + 55 * sstep(0, 0.10, q)
            arc.swirl = Float(2.4 * sstep(0.04, 0.16, q))
            labelAlpha = sstep(0.86, 1.0, q)
            remaining = holdDur + releaseDur
            if q >= 1 { phase = .hold; phaseStart = now }

        case .hold:
            // Nothing left to eat, so it just keeps crossing, slowly.
            arc.fade = 1
            if loops {
                let period = baseLoopPeriod / speed
                sweep((elapsed / period).truncatingRemainder(dividingBy: 1), eating: true, into: &arc)
            } else {
                sweep(0.5, eating: true, into: &arc)     // parks mid-screen
            }
            if consumeScreen { arc.mixLeft = 0; arc.mixRight = 0 }
            arc.holePoints = 95 + 5 * sin(elapsed * 0.28)
            arc.swirl = 0
            labelAlpha = 1
            remaining = max(holdDur - elapsed, 0) + releaseDur
            if elapsed >= holdDur { phase = .release; phaseStart = now }

        case .release:
            // Same traversal, handing the desktop back in its wake.
            let q = min(elapsed / releaseDur, 1)
            sweep(q, eating: false, into: &arc)
            arc.holePoints = 95
            arc.swirl = Float(2.4 * (1 - sstep(0.55, 1.0, q)))
            arc.fade = Float(1 - sstep(0.90, 1.0, q))
            labelAlpha = 1 - sstep(0, 0.18, q)
            if q >= 1 { endNow(skipped: false); return }
        }

        // Esc progress shows up in the hint so holding it feels responsive.
        var hintText = "move the mouse to end the break"
        if let since = escSince {
            let p = min((now - since) / escHoldToSkip, 1)
            hintText = "skipping " + String(repeating: "▮", count: Int(p * 10))
                + String(repeating: "▯", count: 10 - Int(p * 10))
        }

        arc.timeScale = Float(speed)

        let mins = Int(remaining) / 60, secs = Int(remaining) % 60
        for s in screens {
            s.view.arc = arc
            s.view.render()
            s.countdown?.stringValue = String(format: "%d:%02d", mins, secs)
            s.hint?.stringValue = hintText
            for v in [s.panel, s.countdown, s.caption, s.hint].compactMap({ $0 }) {
                v.alphaValue = CGFloat(labelAlpha)
            }
        }
    }
}
