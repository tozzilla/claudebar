import Foundation

// MARK: - Models (mirror api/oauth/usage — the same data the Claude console shows)

struct LimitBar {
    let label: String
    let percent: Double
    let resetAt: Date?
    let isActive: Bool
    let group: String   // "session" | "weekly"
}

struct SpendInfo {
    let usedMinor: Int
    let limitMinor: Int
    let currency: String
    let exponent: Int
    let percent: Double
    let enabled: Bool
}

struct LiveUsage {
    var session: LimitBar?
    var weekly: [LimitBar] = []
    var spend: SpendInfo?
    var generatedAt = Date()
    var error: String?
    var tokenExpired = false
    var rateLimited = false
    var retryAfter: TimeInterval?
}

// MARK: - API client

/// Reads the Claude Code OAuth token from the macOS Keychain and queries the
/// official usage endpoint. Drive from a background queue (see `Poller`).
final class UsageAPI {
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let keychainService = "Claude Code-credentials"

    func fetch() -> LiveUsage {
        var result = LiveUsage()

        guard let token = readToken() else {
            result.error = "Token non leggibile dal Keychain.\nApri Claude Code e consenti l'accesso."
            return result
        }

        var request = URLRequest(url: usageURL, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("TachyBar/1.1 (menubar)", forHTTPHeaderField: "User-Agent")

        let (data, response, netError) = syncGet(request)
        let status = response?.statusCode ?? 0

        if let netError {
            result.error = "Rete: \(netError.localizedDescription)"
            return result
        }
        if status == 429 {
            result.rateLimited = true
            let header = response?.value(forHTTPHeaderField: "Retry-After")
            result.retryAfter = header.flatMap { Double($0) } ?? 120
            result.error = "Limite richieste raggiunto (429)"
            return result
        }
        if status == 401 || status == 403 {
            result.tokenExpired = true
            result.error = "Token scaduto. Apri Claude Code per rinnovarlo."
            return result
        }
        guard status == 200, let data else {
            result.error = "Risposta inattesa (HTTP \(status))"
            return result
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            result.error = "JSON non valido dalla API"
            return result
        }

        parse(obj, into: &result)
        return result
    }

    // MARK: Parsing

    private func parse(_ obj: [String: Any], into result: inout LiveUsage) {
        if let limits = obj["limits"] as? [[String: Any]] {
            for l in limits {
                let group = (l["group"] as? String) ?? ""
                let kind = (l["kind"] as? String) ?? ""
                let percent = numericPercent(l["percent"])
                let reset = (l["resets_at"] as? String).flatMap(Self.parseISO)
                let isActive = (l["is_active"] as? Bool) ?? false
                let label = self.label(kind: kind, scope: l["scope"] as? [String: Any])
                let bar = LimitBar(label: label, percent: percent, resetAt: reset, isActive: isActive, group: group)
                if group == "session" {
                    result.session = bar
                } else if group == "weekly" {
                    result.weekly.append(bar)
                }
            }
        }

        if let spend = obj["spend"] as? [String: Any],
           let used = spend["used"] as? [String: Any],
           let limit = spend["limit"] as? [String: Any] {
            let enabled = (spend["enabled"] as? Bool) ?? false
            result.spend = SpendInfo(
                usedMinor: (used["amount_minor"] as? Int) ?? 0,
                limitMinor: (limit["amount_minor"] as? Int) ?? 0,
                currency: (used["currency"] as? String) ?? "EUR",
                exponent: (used["exponent"] as? Int) ?? 2,
                percent: numericPercent(spend["percent"]),
                enabled: enabled
            )
        }
    }

    private func numericPercent(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }

    private func label(kind: String, scope: [String: Any]?) -> String {
        switch kind {
        case "session": return "Sessione corrente"
        case "weekly_all": return "Tutti i modelli"
        case "weekly_scoped":
            if let model = scope?["model"] as? [String: Any],
               let name = model["display_name"] as? String {
                return name
            }
            return "Modello specifico"
        default: return kind
        }
    }

    // MARK: Keychain

    private func readToken() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let blob = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = blob["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        return token
    }

    // MARK: Networking (synchronous, for use on a background queue)

    private func syncGet(_ request: URLRequest) -> (Data?, HTTPURLResponse?, Error?) {
        let sem = DispatchSemaphore(value: 0)
        var outData: Data?
        var outResponse: HTTPURLResponse?
        var outError: Error?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            outData = data
            outResponse = response as? HTTPURLResponse
            outError = error
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 20)
        return (outData, outResponse, outError)
    }

    // MARK: ISO date

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseISO(_ s: String) -> Date? {
        // Drop microsecond fraction (ISO8601DateFormatter chokes on >3 digits).
        let cleaned = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return iso.date(from: cleaned)
    }
}

// MARK: - Background poller

final class Poller {
    private let queue = DispatchQueue(label: "app.tachybar.poll")
    private let api = UsageAPI()

    func pollAsync(_ completion: @escaping (LiveUsage) -> Void) {
        queue.async {
            let usage = self.api.fetch()
            DispatchQueue.main.async { completion(usage) }
        }
    }
}
