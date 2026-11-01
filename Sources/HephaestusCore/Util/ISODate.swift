import Foundation

/// Date formats of docs/data-model.md › Dates and docs/engine-api.md › JSON encoding.
public enum ISODate {
    /// `yyyy-MM-dd'T'HH:mm:ss'Z'` in UTC with whole seconds, for example `2026-10-31T14:03:00Z`.
    /// A fraction of a second is dropped.
    public static func string(from date: Date) -> String {
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down))
        return format(seconds: seconds, milliseconds: nil)
    }

    /// The engine API form: whole seconds as `string(from:)`, otherwise with milliseconds,
    /// for example `2026-10-31T14:03:07.412Z`.
    public static func apiString(from date: Date) -> String {
        let interval = date.timeIntervalSince1970
        if interval == interval.rounded(.down) {
            return format(seconds: Int64(interval), milliseconds: nil)
        }
        return millisecondString(from: date)
    }

    /// UTC time with milliseconds, for example `2026-10-31T14:03:07.412Z`, rounded to the
    /// nearest millisecond.
    public static func millisecondString(from date: Date) -> String {
        let total = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = floorDiv(total, 1000)
        return format(seconds: seconds, milliseconds: Int(total - seconds * 1000))
    }

    /// Parses `YYYY-MM-DDTHH:MM:SS`, an optional fraction of a second, then `Z` or a numeric
    /// offset `±HH:MM`. Fractions are dropped and offsets converted to UTC. Any other form
    /// gives nil.
    public static func date(from string: String) -> Date? {
        parse(string, keepingMilliseconds: false)
    }

    /// The engine API form of `date(from:)`: the same forms, with the fraction of a second kept
    /// to the millisecond (docs/engine-api.md › JSON encoding), so that a `modified` date read
    /// back as `expectedModified` compares equal.
    public static func apiDate(from string: String) -> Date? {
        parse(string, keepingMilliseconds: true)
    }

    private static func parse(_ string: String, keepingMilliseconds: Bool) -> Date? {
        let scalars = Array(string.utf8)
        var index = 0
        var milliseconds = 0

        func digits(_ count: Int) -> Int? {
            guard index + count <= scalars.count else { return nil }
            var value = 0
            for offset in 0..<count {
                let byte = scalars[index + offset]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            index += count
            return value
        }

        func expect(_ byte: UInt8) -> Bool {
            guard index < scalars.count, scalars[index] == byte else { return false }
            index += 1
            return true
        }

        guard let year = digits(4), expect(0x2D),
              let month = digits(2), expect(0x2D),
              let day = digits(2), expect(0x54),
              let hour = digits(2), expect(0x3A),
              let minute = digits(2), expect(0x3A),
              let second = digits(2)
        else { return nil }

        if index < scalars.count, scalars[index] == 0x2E {
            index += 1
            let start = index
            while index < scalars.count, scalars[index] >= 0x30, scalars[index] <= 0x39 {
                if index - start < 3 {
                    milliseconds = milliseconds * 10 + Int(scalars[index] - 0x30)
                }
                index += 1
            }
            guard index > start else { return nil }
            for _ in min(index - start, 3)..<3 {
                milliseconds *= 10
            }
        }

        var offsetSeconds = 0
        guard index < scalars.count else { return nil }
        if scalars[index] == 0x5A {
            index += 1
        } else if scalars[index] == 0x2B || scalars[index] == 0x2D {
            let sign = scalars[index] == 0x2D ? -1 : 1
            index += 1
            guard let offsetHours = digits(2), expect(0x3A), let offsetMinutes = digits(2),
                  offsetHours <= 23, offsetMinutes <= 59
            else { return nil }
            offsetSeconds = sign * (offsetHours * 3600 + offsetMinutes * 60)
        } else {
            return nil
        }
        guard index == scalars.count else { return nil }

        guard (1...12).contains(month), (0...23).contains(hour), (0...59).contains(minute),
              (0...59).contains(second), day >= 1, day <= daysIn(month: month, year: year)
        else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let total = Int64(days) * 86_400 + Int64(hour * 3600 + minute * 60 + second) - Int64(offsetSeconds)
        guard keepingMilliseconds, milliseconds > 0 else { return Date(timeIntervalSince1970: TimeInterval(total)) }
        return Date(timeIntervalSince1970: (Double(total * 1000) + Double(milliseconds)) / 1000)
    }

    /// The current time truncated to whole seconds, as the engine stores times.
    public static func now() -> Date {
        Date().truncatedToSeconds
    }

    // MARK: - Calendar arithmetic (proleptic Gregorian, UTC)

    private static func format(seconds: Int64, milliseconds: Int?) -> String {
        let days = Int(floorDiv(seconds, 86_400))
        let secondOfDay = Int(seconds - Int64(days) * 86_400)
        let (year, month, day) = civilFromDays(days)
        let hour = secondOfDay / 3600
        let minute = (secondOfDay % 3600) / 60
        let second = secondOfDay % 60
        var text = pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2) + "T"
            + pad(hour, 2) + ":" + pad(minute, 2) + ":" + pad(second, 2)
        if let milliseconds {
            text += "." + pad(milliseconds, 3)
        }
        return text + "Z"
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let quotient = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? quotient - 1 : quotient
    }

    private static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 (Howard Hinnant's algorithm).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let monthIndex = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civilFromDays(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }
}

extension Date {
    /// This date without its fraction of a second.
    public var truncatedToSeconds: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
    }
}
