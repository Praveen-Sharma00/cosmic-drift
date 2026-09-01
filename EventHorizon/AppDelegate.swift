import AppKit
import CoreGraphics
import IOKit

private enum Pref {
    static let work = "workMinutes"
    static let rest = "breakMinutes"
    static let ltr = "sweepLeftToRight"
    static let consume = "consumeScreen"
    static let speed = "animationSpeed"
    static let loop = "loopAnimation"
}

/// Seconds since the last keyboard or mouse input, straight from IOHIDSystem so
/// it needs no extra permission.
private func systemIdleSeconds() -> Double {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                       IOServiceMatching("IOHIDSystem"),
                                       &iterator) == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(iterator) }
    let entry = IOIteratorNext(iterator)
    guard entry != 0 else { return 0 }
    defer { IOObjectRelease(entry) }

    var dict: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(entry, &dict, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let props = dict?.takeRetainedValue() as? [String: Any],
          let ns = props["HIDIdleTime"] as? NSNumber else { return 0 }
    return Double(ns.int64Value) / 1_000_000_000
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var item: NSStatusItem!
    private var timer: Timer?
    private let breaks = BreakController()

    private var nextBreakAt = Date()
    private var paused = false

    private var workMinutes: Double {
        let v = UserDefaults.standard.double(forKey: Pref.work)
        return v > 0 ? v : 50
    }
    private var breakMinutes: Double {
        let v = UserDefaults.standard.double(forKey: Pref.rest)
        return v > 0 ? v : 10
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        UserDefaults.standard.register(defaults: [Pref.speed: 1.0, Pref.loop: true])

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "smallcircle.filled.circle",
                                     accessibilityDescription: "Event Horizon")
        item.button?.imagePosition = .imageLeading

        breaks.onEnd = { [weak self] _ in self?.scheduleNext() }
        scheduleNext()

        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        EHLog.write("launch: bundle=\(Bundle.main.bundlePath)")
        EHLog.write("launch: screenCaptureGranted=\(CGPreflightScreenCaptureAccess()) "
                    + "screens=\(NSScreen.screens.count)")
        if !CGPreflightScreenCaptureAccess() {
            EHLog.write("launch: requesting screen capture access")
            CGRequestScreenCaptureAccess()
        }
        rebuildMenu()
    }

    // MARK: - Timing

    private func scheduleNext() {
        nextBreakAt = Date().addingTimeInterval(workMinutes * 60)
    }

    private func tick() {
        guard !breaks.isRunning else { rebuildMenu(); return }

        // Being away from the keyboard is itself a break. Don't ambush someone
        // with a black hole the moment they sit back down.
        if systemIdleSeconds() >= breakMinutes * 60 { scheduleNext() }

        if !paused && Date() >= nextBreakAt {
            breaks.begin(seconds: breakMinutes * 60)
        }
        rebuildMenu()
    }

    private var remaining: TimeInterval { max(nextBreakAt.timeIntervalSinceNow, 0) }

    private func clock(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    // MARK: - Menu

    private func rebuildMenu() {
        if breaks.isRunning || paused {
            item.button?.title = paused ? " paused" : ""
        } else {
            item.button?.title = remaining < 300 ? " \(clock(remaining))" : ""
        }

        let m = NSMenu()
        let status: String
        if breaks.isRunning { status = "On a break" }
        else if paused { status = "Paused" }
        else { status = "Next break in \(clock(remaining))" }
        m.addItem(withTitle: status, action: nil, keyEquivalent: "")
        m.addItem(.separator())

        if breaks.isRunning {
            m.addItem(entry("End break now", #selector(endBreak)))
        } else {
            m.addItem(entry("Take a break now", #selector(breakNow)))
            m.addItem(entry("Reset the timer", #selector(resetTimer)))
            m.addItem(entry(paused ? "Resume" : "Pause", #selector(togglePause)))
        }

        m.addItem(.separator())
        let intervals = NSMenu()
        for (w, b) in [(20.0, 5.0), (25.0, 5.0), (50.0, 10.0), (60.0, 10.0), (90.0, 15.0)] {
            let it = entry("\(Int(w)) min work · \(Int(b)) min break", #selector(pickPreset(_:)))
            it.representedObject = [w, b]
            it.state = (w == workMinutes && b == breakMinutes) ? .on : .off
            intervals.addItem(it)
        }
        intervals.addItem(.separator())
        let custom = entry("Custom…", #selector(customInterval))
        custom.state = [20.0, 25.0, 50.0, 60.0, 90.0].contains(workMinutes) ? .off : .on
        intervals.addItem(custom)
        let host = NSMenuItem(title: "Interval", action: nil, keyEquivalent: "")
        host.submenu = intervals
        m.addItem(host)

        let dirs = NSMenu()
        let ltr = UserDefaults.standard.bool(forKey: Pref.ltr)
        for (title, isLTR) in [("Right to left", false), ("Left to right", true)] {
            let it = entry(title, #selector(pickDirection(_:)))
            it.representedObject = isLTR
            it.state = (isLTR == ltr) ? .on : .off
            dirs.addItem(it)
        }
        let dirHost = NSMenuItem(title: "Direction", action: nil, keyEquivalent: "")
        dirHost.submenu = dirs
        m.addItem(dirHost)

        let speeds = NSMenu()
        let current = UserDefaults.standard.double(forKey: Pref.speed)
        for v in [0.25, 0.5, 1.0, 1.5] {
            let label = v == 1.0 ? "1x (normal)" : "\(v == floor(v) ? String(Int(v)) : String(v))x"
            let it = entry(label, #selector(pickSpeed(_:)))
            it.representedObject = v
            it.state = abs(v - current) < 0.001 ? .on : .off
            speeds.addItem(it)
        }
        let speedHost = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        speedHost.submenu = speeds
        m.addItem(speedHost)

        let loop = entry("Loop the crossing", #selector(toggleLoop))
        loop.state = UserDefaults.standard.bool(forKey: Pref.loop) ? .on : .off
        m.addItem(loop)

        let consume = entry("Clear the whole screen", #selector(toggleConsume))
        consume.state = UserDefaults.standard.bool(forKey: Pref.consume) ? .on : .off
        m.addItem(consume)

        if !CGPreflightScreenCaptureAccess() {
            m.addItem(.separator())
            m.addItem(entry("⚠ Allow Screen Recording…", #selector(openPrivacy)))
        }

        m.addItem(.separator())
        m.addItem(entry("Quit Event Horizon", #selector(quit)))
        item.menu = m
    }

    private func entry(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    // MARK: - Actions

    @objc private func breakNow() { breaks.begin(seconds: breakMinutes * 60) }
    @objc private func endBreak() { breaks.skip() }
    @objc private func resetTimer() { scheduleNext(); rebuildMenu() }
    @objc private func togglePause() { paused.toggle(); scheduleNext(); rebuildMenu() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func pickSpeed(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        UserDefaults.standard.set(v, forKey: Pref.speed)
        rebuildMenu()
    }

    @objc private func toggleLoop() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: Pref.loop), forKey: Pref.loop)
        rebuildMenu()
    }

    @objc private func toggleConsume() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: Pref.consume), forKey: Pref.consume)
        rebuildMenu()
    }

    @objc private func pickDirection(_ sender: NSMenuItem) {
        guard let ltr = sender.representedObject as? Bool else { return }
        UserDefaults.standard.set(ltr, forKey: Pref.ltr)
        rebuildMenu()
    }

    @objc private func pickPreset(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? [Double], v.count == 2 else { return }
        save(work: v[0], rest: v[1])
    }

    @objc private func customInterval() {
        let a = NSAlert()
        a.messageText = "Custom interval"
        a.informativeText = "How long do you want to work between breaks, and how long should each break last?"
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 56))
        let fields: [NSTextField] = [workMinutes, breakMinutes].map {
            let f = NSTextField(frame: .zero)
            f.stringValue = String(Int($0))
            f.alignment = .right
            return f
        }
        for (i, caption) in ["Work for", "Break for"].enumerated() {
            let y = CGFloat(i == 0 ? 30 : 2)
            let l = NSTextField(labelWithString: caption)
            l.frame = NSRect(x: 0, y: y + 3, width: 110, height: 18)
            l.alignment = .right
            let unit = NSTextField(labelWithString: "min")
            unit.frame = NSRect(x: 182, y: y + 3, width: 40, height: 18)
            fields[i].frame = NSRect(x: 120, y: y, width: 56, height: 22)
            box.addSubview(l); box.addSubview(fields[i]); box.addSubview(unit)
        }
        a.accessoryView = box
        a.window.initialFirstResponder = fields[0]

        if a.runModal() == .alertFirstButtonReturn {
            let w = min(max(Double(fields[0].stringValue) ?? workMinutes, 1), 600)
            let b = min(max(Double(fields[1].stringValue) ?? breakMinutes, 1), 120)
            save(work: w, rest: b)
        }
    }

    private func save(work: Double, rest: Double) {
        UserDefaults.standard.set(work, forKey: Pref.work)
        UserDefaults.standard.set(rest, forKey: Pref.rest)
        scheduleNext()
        rebuildMenu()
    }
}
