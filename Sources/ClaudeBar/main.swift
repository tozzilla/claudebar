import AppKit

// `--print`: run one fetch, dump it as text, and exit. Handy for debugging the
// data layer without launching the menu-bar UI.
if CommandLine.arguments.contains("--print") {
    let usage = UsageAPI().fetch()
    print(renderText(usage))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
app.run()

func renderText(_ u: LiveUsage) -> String {
    var out = ""
    if let e = u.error { out += "error: \(e)\n" }
    if let s = u.session {
        out += "Session: \(Fmt.percent(s.percent))"
        if let r = s.resetAt { out += "  reset \(Fmt.time(r)) (in \(Fmt.duration(r.timeIntervalSinceNow)))" }
        out += "\n"
    }
    if !u.weekly.isEmpty {
        out += "Weekly:\n"
        for w in u.weekly {
            out += "  \(w.label): \(Fmt.percent(w.percent))"
            if let r = w.resetAt { out += "  reset \(Fmt.weekdayTime(r))" }
            if w.isActive { out += "  [active]" }
            out += "\n"
        }
    }
    if let sp = u.spend, sp.enabled {
        out += "Credits: \(Fmt.money(minor: sp.usedMinor, exponent: sp.exponent, currency: sp.currency)) / "
        out += "\(Fmt.money(minor: sp.limitMinor, exponent: sp.exponent, currency: sp.currency)) (\(Fmt.percent(sp.percent)))\n"
    }
    out += "generated at \(Fmt.timeSec(u.generatedAt))\n"
    return out
}
