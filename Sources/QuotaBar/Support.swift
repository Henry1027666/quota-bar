import Foundation

enum Support {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 35
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    static func jsonRequest(
        _ url: URL,
        method: String = "GET",
        bearer: String? = nil,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.invalidResponse("未收到有效响应")
        }
        guard (200..<300).contains(http.statusCode) else { throw QuotaError.http(http.statusCode) }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func dictionary(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.invalidResponse("认证文件格式无效")
        }
        return value
    }

    static func nested(_ root: [String: Any], path: [String]) -> Any? {
        path.reduce(root as Any?) { value, key in (value as? [String: Any])?[key] }
    }

    static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds)
        }
        guard let text = string(value) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func firstValue(in dictionary: [String: Any], keys: [String]) -> Any? {
        for key in keys where dictionary[key] != nil { return dictionary[key] }
        return nil
    }

    static func firstNumber(in dictionary: [String: Any], keys: [String]) -> Double? {
        number(firstValue(in: dictionary, keys: keys))
    }

    static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        string(firstValue(in: dictionary, keys: keys))
    }

    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func run(_ executable: String, _ arguments: [String], input: Data? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        if let input {
            let pipe = Pipe()
            process.standardInput = pipe
            try process.run()
            pipe.fileHandleForWriting.write(input)
            try? pipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let detail = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw QuotaError.command(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func parseGenericWindows(_ value: Any, preferredLabels: [String: String] = [:]) -> [QuotaWindow] {
        var result: [QuotaWindow] = []
        func walk(_ value: Any, path: String) {
            if let dictionary = value as? [String: Any] {
                let used = firstNumber(in: dictionary, keys: ["used", "usage", "consumed", "amount_used", "used_amount"])
                let limit = firstNumber(in: dictionary, keys: ["limit", "total", "capacity", "max", "amount_limit", "hardLimit"])
                let percent = firstNumber(in: dictionary, keys: ["percent", "utilization", "usagePercent", "percent_used"])
                let reset = date(firstValue(in: dictionary, keys: ["reset_at", "resets_at", "resetAt", "resetsAt", "endOfMonth", "billingCycleEnd"]))
                let rawLabel = firstString(in: dictionary, keys: ["name", "label", "group", "kind", "type"]) ?? path
                let normalized = rawLabel.lowercased()
                let label = preferredLabels.first(where: { normalized.contains($0.key) })?.value ?? displayLabel(normalized)
                if let used, let limit, limit > 0 {
                    result.append(QuotaWindow(title: label, used: used, limit: limit, resetAt: reset))
                } else if let percent {
                    result.append(QuotaWindow(title: label, used: percent, limit: 100, resetAt: reset))
                }
                for (key, child) in dictionary { walk(child, path: key) }
            } else if let array = value as? [Any] {
                array.forEach { walk($0, path: path) }
            }
        }
        walk(value, path: "额度")
        var seen = Set<String>()
        return result.filter { seen.insert("\($0.title)-\($0.resetAt?.timeIntervalSince1970 ?? 0)-\($0.limit)").inserted }
    }

    private static func displayLabel(_ raw: String) -> String {
        if raw.contains("five") || raw.contains("5h") || raw.contains("session") { return "5 小时" }
        if raw.contains("seven") || raw.contains("week") || raw.contains("7d") { return "周限额" }
        if raw.contains("month") { return "月限额" }
        if raw.contains("total") || raw.contains("overall") || raw.contains("plan") { return "总限额" }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
