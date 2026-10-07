import Foundation

/// Rasyonel zaman: `value / timescale` saniye. CMTime'ın value/timescale
/// temsilinin Foundation'a bağımlı olmayan karşılığı. Kayan noktalı saniye
/// yerine bu tip saklanır; böylece kare sınırları ve kesme noktaları kaymaz.
public struct MediaTime: Hashable, Sendable, Codable {
    public var value: Int64
    public var timescale: Int32

    /// Varsayılan zaman ölçeği: 24, 25, 30 ve 60 fps'in ortak katı.
    public static let defaultTimescale: Int32 = 600
    public static let zero = MediaTime(value: 0, timescale: defaultTimescale)

    public init(value: Int64, timescale: Int32) {
        precondition(timescale > 0, "timescale pozitif olmalı")
        self.value = value
        self.timescale = timescale
    }

    /// Saniyeden en yakın değere yuvarlayarak oluşturur.
    public init(seconds: Double, timescale: Int32 = MediaTime.defaultTimescale) {
        self.init(value: Int64((seconds * Double(timescale)).rounded()), timescale: timescale)
    }

    public var seconds: Double { Double(value) / Double(timescale) }

    /// Aynı anı başka bir zaman ölçeğinde (yuvarlayarak) ifade eder.
    public func converted(to newTimescale: Int32) -> MediaTime {
        if newTimescale == timescale { return self }
        let scaled = (Double(value) * Double(newTimescale) / Double(timescale)).rounded()
        return MediaTime(value: Int64(scaled), timescale: newTimescale)
    }

    /// Süreyi hız oranına böler (ör. 2x hızda süre yarıya iner). Sonuç bu
    /// zamanın ölçeğinde yuvarlanır.
    public func divided(by rate: Double) -> MediaTime {
        precondition(rate > 0, "hız pozitif olmalı")
        return MediaTime(value: Int64((Double(value) / rate).rounded()), timescale: timescale)
    }

    public func multiplied(by rate: Double) -> MediaTime {
        precondition(rate > 0, "hız pozitif olmalı")
        return MediaTime(value: Int64((Double(value) * rate).rounded()), timescale: timescale)
    }

    // MARK: - Ortak ölçek

    /// İki zaman için ortak ölçek: ekok, makul sınırı aşarsa büyük olan ölçek.
    static func commonTimescale(_ a: Int32, _ b: Int32) -> Int32 {
        if a == b { return a }
        let lcm = Int64(a) / Int64(gcd(Int(a), Int(b))) * Int64(b)
        return lcm <= 1_000_000_000 ? Int32(lcm) : max(a, b)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (a, b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }
}

extension MediaTime: Comparable {
    public static func < (lhs: MediaTime, rhs: MediaTime) -> Bool {
        let ts = commonTimescale(lhs.timescale, rhs.timescale)
        return lhs.converted(to: ts).value < rhs.converted(to: ts).value
    }

    /// Farklı ölçeklerde aynı anı gösteren zamanlar eşittir (600/600 == 1/1).
    public static func == (lhs: MediaTime, rhs: MediaTime) -> Bool {
        let ts = commonTimescale(lhs.timescale, rhs.timescale)
        return lhs.converted(to: ts).value == rhs.converted(to: ts).value
    }

    public func hash(into hasher: inout Hasher) {
        // Eşitlik ölçekten bağımsız olduğu için özet de öyle olmalı.
        hasher.combine(seconds)
    }
}

extension MediaTime {
    public static func + (lhs: MediaTime, rhs: MediaTime) -> MediaTime {
        let ts = commonTimescale(lhs.timescale, rhs.timescale)
        return MediaTime(value: lhs.converted(to: ts).value + rhs.converted(to: ts).value, timescale: ts)
    }

    public static func - (lhs: MediaTime, rhs: MediaTime) -> MediaTime {
        let ts = commonTimescale(lhs.timescale, rhs.timescale)
        return MediaTime(value: lhs.converted(to: ts).value - rhs.converted(to: ts).value, timescale: ts)
    }
}

extension MediaTime: CustomStringConvertible {
    public var description: String { String(format: "%.3fs", seconds) }
}

/// Yarı açık zaman aralığı: [start, end).
public struct TimeRange: Hashable, Sendable, Codable {
    public var start: MediaTime
    public var end: MediaTime

    public init(start: MediaTime, end: MediaTime) {
        self.start = start
        self.end = end
    }

    public var duration: MediaTime { end - start }
    public var isEmpty: Bool { end <= start }

    public func contains(_ time: MediaTime) -> Bool { time >= start && time < end }

    public func overlaps(_ other: TimeRange) -> Bool { start < other.end && other.start < end }
}
