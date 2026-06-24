import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // The usage endpoint is meant for occasional refreshes, so we fetch it
    // sparingly and tick the reset countdown locally between fetches.
    private let tickInterval: TimeInterval = 30      // local title refresh
    private let fetchInterval: TimeInterval = 180     // min seconds between network fetches
    private let manualMinInterval: TimeInterval = 8   // anti-spam for "Aggiorna ora"
    private let defaultBackoff: TimeInterval = 120    // if 429 has no Retry-After

    private var statusItem: NSStatusItem!
    private let poller = Poller()
    private var timer: Timer?

    private var last: LiveUsage?          // last GOOD payload (kept across transient errors)
    private var statusNote: String?       // transient note (rate-limit, network…)
    private var tokenExpired = false
    private var backoffUntil: Date?
    private var lastFetchAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…"

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        attemptFetch(manual: false, force: true)
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    /// Runs every 30s: refresh the title from cached data (so the countdown
    /// moves), and fetch from the network only when due.
    private func tick() {
        updateTitle()
        attemptFetch(manual: false, force: false)
    }

    // MARK: - Fetching (throttled)

    private func attemptFetch(manual: Bool, force: Bool) {
        let now = Date()
        if !force, let until = backoffUntil, now < until { return }   // honor 429 backoff
        if !force, let lf = lastFetchAt {
            let minGap = manual ? manualMinInterval : fetchInterval
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
            // keep last good data on screen
        } else if usage.tokenExpired {
            tokenExpired = true
            statusNote = usage.error
        } else if let err = usage.error {
            statusNote = err  // network/parse hiccup — keep last good data
        } else {
            last = usage
            statusNote = nil
            tokenExpired = false
            backoffUntil = nil
        }
        updateTitle()
    }

    // MARK: - Title (cheap, from cached data)

    private let barFont = NSFont.menuBarFont(ofSize: 0)

    /// Usage color thresholds: green ≤64, yellow 65–84, red ≥85.
    private func usageColor(_ percent: Double) -> NSColor {
        let p = Int(percent.rounded())
        if p >= 85 { return .systemRed }
        if p >= 65 { return .systemYellow }
        return .systemGreen
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        if tokenExpired { setPlainTitle(button, "⚠︎ login"); return }
        guard let u = last else { setPlainTitle(button, statusNote != nil ? "⚠︎" : "…"); return }

        if let s = u.session {
            var suffix = ""
            if let reset = s.resetAt {
                suffix = " · " + Fmt.duration(reset.timeIntervalSinceNow, compact: true)
            }
            button.attributedTitle = barTitle(Fmt.percent(s.percent), percent: s.percent, suffix: suffix)
        } else if let w = u.weekly.first {
            button.attributedTitle = barTitle(Fmt.percent(w.percent), percent: w.percent, suffix: " sett.")
        } else {
            setPlainTitle(button, "—")
        }
    }

    /// Colored percentage + default-colored suffix for the menu-bar title.
    private func barTitle(_ percentText: String, percent: Double, suffix: String) -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: percentText,
                                    attributes: [.foregroundColor: usageColor(percent), .font: barFont]))
        if !suffix.isEmpty {
            s.append(NSAttributedString(string: suffix, attributes: [.font: barFont]))
        }
        return s
    }

    private func setPlainTitle(_ button: NSStatusBarButton, _ text: String) {
        button.attributedTitle = NSAttributedString(string: text, attributes: [.font: barFont])
    }

    // MARK: - Menu (rebuilt from cache on open; no network fetch on open)

    func menuNeedsUpdate(_ menu: NSMenu) {
        buildMenu(menu)
        attemptFetch(manual: false, force: false) // only fires if due and not backing off
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

        guard let u = last else {
            menu.addItem(info("Caricamento…"))
            addFooter(menu)
            return
        }

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
                if let reset = w.resetAt {
                    line += " · reset \(Fmt.weekdayTime(reset))"
                }
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
        addFooter(menu)
    }

    private func addFooter(_ menu: NSMenu) {
        let refreshItem = NSMenuItem(title: "Aggiorna ora", action: #selector(manualRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let loginItem = NSMenuItem(title: "Avvia al login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Esci", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
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

    /// Info row whose percentage substring is tinted by usage color.
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

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("ClaudeBar: login item toggle failed (run as .app to use this): \(error)")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
