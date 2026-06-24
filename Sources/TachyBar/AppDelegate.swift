import AppKit
import ServiceManagement
import Network

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let tickInterval: TimeInterval = 30      // local title refresh
    private let manualMinInterval: TimeInterval = 8  // anti-spam for manual/wake/network fetches
    private let defaultBackoff: TimeInterval = 120   // if a 429 has no Retry-After

    private var statusItem: NSStatusItem!
    private let poller = Poller()
    private let notifier = Notifier()
    private var timer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var lastPathSatisfied = true

    private var last: LiveUsage?
    private var statusNote: String?
    private var tokenExpired = false
    private var backoffUntil: Date?
    private var lastFetchAt: Date?

    private let barFont = NSFont.menuBarFont(ofSize: 0)
    private let consoleURL = URL(string: "https://claude.ai/settings/usage")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = "…"

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        notifier.setup()
        if Prefs.notificationsEnabled { notifier.requestAuthIfNeeded() }

        attemptFetch(manual: false, force: true)
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }

        // Refresh when the Mac wakes from sleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        // Refresh when network connectivity returns.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                let satisfied = path.status == .satisfied
                let was = self?.lastPathSatisfied ?? true
                self?.lastPathSatisfied = satisfied
                if satisfied && !was { self?.attemptFetch(manual: true, force: false) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.tachybar.net"))
        pathMonitor = monitor
    }

    @objc private func systemDidWake() { attemptFetch(manual: true, force: false) }

    private func tick() {
        updateTitle()
        attemptFetch(manual: false, force: false)
    }

    // MARK: - Fetching (throttled)

    private func attemptFetch(manual: Bool, force: Bool) {
        let now = Date()
        if !force, let until = backoffUntil, now < until { return }
        if !force, let lf = lastFetchAt {
            let minGap = manual ? manualMinInterval : Prefs.pollInterval
            if now.timeIntervalSince(lf) < minGap { return }
        }
        lastFetchAt = now
        poller.pollAsync { [weak self] usage in self?.handle(usage) }
    }

    private func handle(_ usage: LiveUsage) {
        let now = Date()
        if usage.rateLimited {
            backoffUntil = now.addingTimeInterval(usage.retryAfter ?? defaultBackoff)
            statusNote = "Limite richieste — riprovo alle \(Fmt.time(backoffUntil!))"
        } else if usage.tokenExpired {
            tokenExpired = true
            statusNote = usage.error
        } else if let err = usage.error {
            statusNote = err
        } else {
            last = usage
            statusNote = nil
            tokenExpired = false
            backoffUntil = nil
            checkNotifications(usage)
        }
        updateTitle()
    }

    // MARK: - Notifications

    private func checkNotifications(_ u: LiveUsage) {
        guard Prefs.notificationsEnabled, notifier.available else { return }
        let threshold = Double(Prefs.alertThreshold)
        var tracked: [LimitBar] = []
        if let s = u.session { tracked.append(s) }
        tracked.append(contentsOf: u.weekly)

        var notified = Prefs.notifiedKeys
        for bar in tracked where bar.percent >= threshold {
            // One notification per (limit, reset window, threshold).
            let resetKey = bar.resetAt.map { String(Int($0.timeIntervalSince1970)) } ?? "na"
            let key = "\(bar.label)@\(resetKey)@\(Prefs.alertThreshold)"
            guard !notified.contains(key) else { continue }
            let body = bar.resetAt.map { "Reset \(Fmt.smartReset($0))" } ?? ""
            notifier.notify(title: "Claude · \(bar.label) al \(Fmt.percent(bar.percent))", body: body)
            notified.append(key)
        }
        Prefs.notifiedKeys = notified
    }

    // MARK: - Title (cheap, from cached data)

    /// Usage color thresholds: green ≤64, yellow 65–84, red ≥85.
    private func usageColor(_ percent: Double) -> NSColor {
        let p = Int(percent.rounded())
        if p >= 85 { return .systemRed }
        if p >= 65 { return .systemYellow }
        return .systemGreen
    }

    /// Pick the limit to show in the bar based on the user's preference.
    private func selectedBar(_ u: LiveUsage) -> (bar: LimitBar, isSession: Bool)? {
        let weeklyTop = u.weekly.max(by: { $0.percent < $1.percent })
        switch Prefs.barMetric {
        case .session:
            if let s = u.session { return (s, true) }
            if let w = weeklyTop { return (w, false) }
        case .weekly:
            if let w = weeklyTop { return (w, false) }
            if let s = u.session { return (s, true) }
        case .auto:
            let candidates: [(LimitBar, Bool)] =
                (u.session.map { [($0, true)] } ?? []) + u.weekly.map { ($0, false) }
            if let best = candidates.max(by: { $0.0.percent < $1.0.percent }) {
                return (best.0, best.1)
            }
        }
        return nil
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        if tokenExpired { setPlain(button, "⚠︎ login"); return }
        guard let u = last, let sel = selectedBar(u) else {
            setPlain(button, statusNote != nil ? "⚠︎" : "…"); return
        }

        let bar = sel.bar
        button.image = dot(usageColor(bar.percent))

        var suffix = ""
        if sel.isSession, let reset = bar.resetAt {
            suffix = " · " + Fmt.duration(reset.timeIntervalSinceNow, compact: true)
        }
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: Fmt.percent(bar.percent),
                                    attributes: [.foregroundColor: usageColor(bar.percent), .font: barFont]))
        if !suffix.isEmpty {
            s.append(NSAttributedString(string: suffix, attributes: [.font: barFont]))
        }
        button.attributedTitle = s
    }

    private func setPlain(_ button: NSStatusBarButton, _ text: String) {
        button.image = nil
        button.attributedTitle = NSAttributedString(string: text, attributes: [.font: barFont])
    }

    /// A small filled circle tinted by usage color (non-template, so it keeps color).
    private func dot(_ color: NSColor, size: CGFloat = 9) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    // MARK: - Menu (rebuilt from cache on open; no network fetch on open)

    func menuNeedsUpdate(_ menu: NSMenu) {
        buildMenu(menu)
        attemptFetch(manual: false, force: false)
    }

    private func buildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        if tokenExpired {
            menu.addItem(info("⚠︎ Token scaduto"))
            menu.addItem(info("  Apri Claude Code per rinnovarlo"))
            menu.addItem(.separator())
        } else if let note = statusNote {
            menu.addItem(info("⚠︎ \(note)"))
            menu.addItem(.separator())
        }

        if let u = last {
            if let s = u.session {
                menu.addItem(header("Sessione corrente"))
                var line = "  \(Fmt.percent(s.percent)) utilizzato"
                if let reset = s.resetAt {
                    line += " · reset tra \(Fmt.duration(reset.timeIntervalSinceNow)) (\(Fmt.time(reset)))"
                }
                menu.addItem(coloredRow(line, colorPart: Fmt.percent(s.percent), percent: s.percent))
            }

            if !u.weekly.isEmpty {
                menu.addItem(.separator())
                menu.addItem(header("Limiti settimanali"))
                for w in u.weekly {
                    var line = "  \(w.label): \(Fmt.percent(w.percent))"
                    if let reset = w.resetAt { line += " · reset \(Fmt.weekdayTime(reset))" }
                    menu.addItem(coloredRow(line, colorPart: Fmt.percent(w.percent), percent: w.percent, bold: w.isActive))
                }
            }

            if let sp = u.spend, sp.enabled {
                menu.addItem(.separator())
                menu.addItem(header("Crediti extra"))
                let used = Fmt.money(minor: sp.usedMinor, exponent: sp.exponent, currency: sp.currency)
                let limit = Fmt.money(minor: sp.limitMinor, exponent: sp.exponent, currency: sp.currency)
                menu.addItem(info("  \(used) / \(limit) (\(Fmt.percent(sp.percent)))"))
            }

            menu.addItem(.separator())
            menu.addItem(info("Aggiornato \(Fmt.timeSec(u.generatedAt))"))
        } else if !tokenExpired && statusNote == nil {
            menu.addItem(info("Caricamento…"))
        }

        addFooter(menu)
    }

    private func addFooter(_ menu: NSMenu) {
        let console = NSMenuItem(title: "Apri console utilizzo", action: #selector(openConsole), keyEquivalent: "")
        console.target = self
        menu.addItem(console)

        let refreshItem = NSMenuItem(title: "Aggiorna ora", action: #selector(manualRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())
        menu.addItem(preferencesMenu())

        let loginItem = NSMenuItem(title: "Avvia al login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Esci", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func preferencesMenu() -> NSMenuItem {
        let prefs = NSMenuItem(title: "Preferenze", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        sub.addItem(header("Mostra in barra"))
        for (label, metric) in [("Sessione corrente", BarMetric.session),
                                 ("Settimanale (max)", .weekly),
                                 ("Automatico (più alto)", .auto)] {
            let item = NSMenuItem(title: "  " + label, action: #selector(selectBarMetric(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = metric.rawValue
            item.state = (Prefs.barMetric == metric) ? .on : .off
            sub.addItem(item)
        }

        sub.addItem(.separator())
        let notif = NSMenuItem(title: "Notifiche soglia", action: #selector(toggleNotifications), keyEquivalent: "")
        notif.target = self
        notif.state = Prefs.notificationsEnabled ? .on : .off
        sub.addItem(notif)

        sub.addItem(header("Soglia avviso"))
        for v in [75, 80, 85, 90, 95] {
            let item = NSMenuItem(title: "  \(v)%", action: #selector(selectThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = v
            item.state = (Prefs.alertThreshold == v) ? .on : .off
            sub.addItem(item)
        }

        sub.addItem(header("Aggiornamento"))
        for (label, secs) in [("Ogni 2 minuti", 120.0), ("Ogni 3 minuti", 180.0),
                              ("Ogni 5 minuti", 300.0), ("Ogni 10 minuti", 600.0)] {
            let item = NSMenuItem(title: "  " + label, action: #selector(selectInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = secs
            item.state = (Prefs.pollInterval == secs) ? .on : .off
            sub.addItem(item)
        }

        prefs.submenu = sub
        return prefs
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)]
        )
        return item
    }

    private func coloredRow(_ full: String, colorPart: String, percent: Double, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: full, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let baseFont = bold ? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize) : NSFont.menuFont(ofSize: 0)
        let attr = NSMutableAttributedString(
            string: full, attributes: [.foregroundColor: NSColor.labelColor, .font: baseFont]
        )
        if let r = full.range(of: colorPart) {
            attr.addAttribute(.foregroundColor, value: usageColor(percent), range: NSRange(r, in: full))
        }
        item.attributedTitle = attr
        return item
    }

    // MARK: - Actions

    @objc private func manualRefresh() { attemptFetch(manual: true, force: false) }
    @objc private func openConsole() { NSWorkspace.shared.open(consoleURL) }

    @objc private func selectBarMetric(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = BarMetric(rawValue: raw) {
            Prefs.barMetric = m
            updateTitle()
        }
    }

    @objc private func toggleNotifications() {
        Prefs.notificationsEnabled.toggle()
        if Prefs.notificationsEnabled { notifier.requestAuthIfNeeded() }
    }

    @objc private func selectThreshold(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Int { Prefs.alertThreshold = v }
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { Prefs.pollInterval = v }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("TachyBar: login item toggle failed (run as .app to use this): \(error)")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
