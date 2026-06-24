import Foundation

enum Fmt {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
        if d >= 1_000 { return String(format: "%.1fK", d / 1_000) }
        return "\(n)"
    }

    static func cost(_ c: Double) -> String {
        return String(format: "$%.2f", c)
    }

    /// "2h 41m" / "41m" / "<1m". With compact: true → "2h41m".
    static func duration(_ seconds: TimeInterval, compact: Bool = false) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 {
            return compact ? "\(h)h\(m)m" : "\(h)h \(m)m"
        } else if m > 0 {
            return "\(m)m"
        } else {
            return total > 0 ? "<1m" : "0m"
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    static func time(_ d: Date) -> String { clock.string(from: d) }

    private static let clockSec: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    static func timeSec(_ d: Date) -> String { clockSec.string(from: d) }

    private static let grouped: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; return f
    }()
    static func intGrouped(_ n: Int) -> String {
        grouped.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func shortModel(_ m: String) -> String {
        m.replacingOccurrences(of: "claude-", with: "")
    }

    static func percent(_ p: Double) -> String {
        return "\(Int(p.rounded()))%"
    }

    static func money(minor: Int, exponent: Int, currency: String) -> String {
        let value = Double(minor) / pow(10.0, Double(exponent))
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = currency
        nf.locale = Locale(identifier: "it_IT")
        return nf.string(from: NSNumber(value: value)) ?? String(format: "%.2f %@", value, currency)
    }

    // Weekly reset shown like the console: "lun 02:59" (local time, Italian).
    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEE HH:mm"
        return f
    }()
    static func weekdayTime(_ d: Date) -> String { weekday.string(from: d) }

    /// "tra 2h 31m" if within a day, otherwise "lun 02:59".
    static func smartReset(_ d: Date) -> String {
        let dt = d.timeIntervalSinceNow
        if dt > 0, dt < 86_400 { return "tra " + duration(dt) }
        return weekdayTime(d)
    }
}
