import Foundation

public enum Stats {
    public static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    public static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    /// Mean absolute difference between consecutive samples (the usual "jitter" figure).
    public static func jitter(_ xs: [Double]) -> Double? {
        guard xs.count >= 2 else { return nil }
        var total = 0.0
        for i in 1..<xs.count { total += abs(xs[i] - xs[i - 1]) }
        return total / Double(xs.count - 1)
    }
}

/// Overall quality used across the app (status dots, verdicts).
public enum Health: Int, Codable, Sendable, Comparable {
    case good = 0, fair = 1, poor = 2, unknown = 3

    public static func < (a: Health, b: Health) -> Bool { a.rawValue < b.rawValue }

    /// The worse of two known values; `unknown` never wins over a known value.
    public func worse(_ other: Health) -> Health {
        if self == .unknown { return other }
        if other == .unknown { return self }
        return max(self, other)
    }
}

public enum Format {
    public static func ms(_ v: Double?) -> String {
        guard let v else { return "–" }
        return v < 10 ? String(format: "%.1f ms", v) : String(format: "%.0f ms", v)
    }

    public static func mbps(_ v: Double?) -> String {
        guard let v else { return "–" }
        if v >= 100 { return String(format: "%.0f", v) }
        if v >= 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }

    public static func percent(_ v: Double?) -> String {
        guard let v else { return "–" }
        return v == v.rounded() ? String(format: "%.0f%%", v) : String(format: "%.1f%%", v)
    }
}
