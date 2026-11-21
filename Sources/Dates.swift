import Foundation

/// Date maths: "today + 30 days", "3 weeks from 1 dec", "days until 25 dec", "days between 1 jan and 1 mar".
extension Evaluator {
    private static let datePattern =
        #"(?:today|tomorrow|yesterday|now|(?:next |this )?(?:mon|tues|wednes|thurs|fri|satur|sun)day"#
        + #"|\d{4}-\d{1,2}-\d{1,2}|\d{1,2}[/.]\d{1,2}(?:[/.]\d{2,4})?"#
        + #"|\d{1,2}(?:st|nd|rd|th)? (?:of )?\p{L}{3,9}\.?(?:,? \d{4})?"#
        + #"|\p{L}{3,9}\.? \d{1,2}(?:st|nd|rd|th)?(?:,? \d{4})?)"#
    private static let unitPattern = #"(days?|weeks?|months?|years?)"#

    private static let shiftRegex = regex(#"(\#(datePattern))\s*([+-])\s*(\d+)\s*\#(unitPattern)"#)
    private static let fromRegex = regex(#"(\d+)\s*\#(unitPattern)\s+(from|after|before)\s+(\#(datePattern))"#)
    private static let agoRegex = regex(#"(\d+)\s*\#(unitPattern)\s+(ago|from now)"#)
    private static let untilRegex = regex(#"(days|weeks)\s+(until|till|to|since|from)\s+(\#(datePattern))"#)
    private static let betweenRegex =
        regex(#"(days|weeks)\s+between\s+(\#(datePattern))\s+(?:and|\+)\s+(\#(datePattern))"#)

    /// Anchors a pattern to the end of the text, starting at a word boundary.
    private static func regex(_ body: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: #"(?:^|(?<=\s))("# + body + #")\s*$"#, options: [.caseInsensitive])
    }

    /// The answer to date maths at the end of `text`, and the character index where it starts.
    static func dateAnswer(_ text: String) -> (String, Int)? {
        let calendar = dateCalendar
        let today = calendar.startOfDay(for: now())

        if let (m, start) = lastMatch(shiftRegex, in: text),
           let base = parseDate(m[2], preferFuture: nil),
           let amount = Int(m[4]), let date = add(m[3] == "-" ? -amount : amount, unit: m[5], to: base) {
            return (formatDate(date), start)
        }
        if let (m, start) = lastMatch(fromRegex, in: text), let amount = Int(m[2]),
           let base = parseDate(m[5], preferFuture: true),
           let date = add(m[4].lowercased() == "before" ? -amount : amount, unit: m[3], to: base) {
            return (formatDate(date), start)
        }
        if let (m, start) = lastMatch(agoRegex, in: text), let amount = Int(m[2]),
           let date = add(m[4].lowercased() == "ago" ? -amount : amount, unit: m[3], to: today) {
            return (formatDate(date), start)
        }
        if let (m, start) = lastMatch(untilRegex, in: text) {
            let isPast = ["since", "from"].contains(m[3].lowercased())
            if let date = parseDate(m[4], preferFuture: !isPast) {
                return (formatSpan(from: today, to: date, unit: m[2]), start)
            }
        }
        if let (m, start) = lastMatch(betweenRegex, in: text),
           let first = parseDate(m[3], preferFuture: nil), let second = parseDate(m[4], preferFuture: nil) {
            return (formatSpan(from: first, to: second, unit: m[2]), start)
        }
        return nil
    }

    private static var dateCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return calendar
    }

    /// Capture groups (index 0 is the whole match) and the character index where the match starts.
    private static func lastMatch(_ regex: NSRegularExpression, in text: String) -> ([String], Int)? {
        let range = NSRange(text.startIndex..., in: text)
        guard let result = regex.firstMatch(in: text, range: range),
              let whole = Range(result.range(at: 1), in: text) else { return nil }
        let groups = (1..<result.numberOfRanges).map { i -> String in
            Range(result.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
        return ([""] + groups, text.distance(from: text.startIndex, to: whole.lowerBound))
    }

    private static func add(_ amount: Int, unit: String, to date: Date) -> Date? {
        let component: Calendar.Component
        switch unit.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "s")) {
        case "day": component = .day
        case "week": component = .weekOfYear
        case "month": component = .month
        case "year": component = .year
        default: return nil
        }
        return dateCalendar.date(byAdding: component, value: amount, to: date)
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM yyyy")
        return formatter.string(from: date)
    }

    private static func formatSpan(from start: Date, to end: Date, unit: String) -> String {
        let days = abs(dateCalendar.dateComponents([.day], from: start, to: end).day ?? 0)
        if unit.lowercased() == "weeks" {
            let weeks = Double(days) / 7
            return "\(format(weeks, maxFractionDigits: 1)) \(weeks == 1 ? "week" : "weeks")"
        }
        return "\(days) \(days == 1 ? "day" : "days")"
    }

    /// Parses a date like "today", "friday", "25 dec", "dec 25 2027", "25/12" or "2026-12-25".
    /// Dates without a year land in the future (`preferFuture`), the past (`false`), or this year (`nil`).
    private static func parseDate(_ raw: String, preferFuture: Bool?) -> Date? {
        let calendar = dateCalendar
        let today = calendar.startOfDay(for: now())
        var text = raw.lowercased().trimmingCharacters(in: .whitespaces)

        switch text {
        case "today", "now": return today
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: today)
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: today)
        default: break
        }

        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let isThis = text.hasPrefix("this ")
        let dayName = text.replacingOccurrences(of: "next ", with: "").replacingOccurrences(of: "this ", with: "")
        if let index = weekdays.firstIndex(of: dayName) {
            let todayIndex = calendar.component(.weekday, from: today) - 1
            var ahead = (index - todayIndex + 7) % 7
            if ahead == 0 && !isThis { ahead = 7 }
            return calendar.date(byAdding: .day, value: ahead, to: today)
        }

        // Tidy "25th of Dec., 2026" into "25 dec 2026".
        text = text.replacingOccurrences(of: #"(\d)(st|nd|rd|th)\b"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: " of ", with: " ")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: ".", with: " ", options: [], range: nil)
        if text.range(of: #"^\d{1,2} \d{1,2}( \d{2,4})?$"#, options: .regularExpression) != nil {
            text = text.replacingOccurrences(of: " ", with: "/")  // "25.12.2026" came through as "25 12 2026"
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        let monthFirst = locale.region?.identifier == "US"
        let numeric = monthFirst ? ["M/d/yyyy", "M/d/yy", "M/d"] : ["d/M/yyyy", "d/M/yy", "d/M"]
        let formats = ["yyyy-M-d"] + numeric + ["d MMM yyyy", "d MMMM yyyy", "MMM d yyyy", "MMMM d yyyy",
                                                "d MMM", "d MMMM", "MMM d", "MMMM d"]
        for dateLocale in [Locale(identifier: "en_US_POSIX"), locale] {
            let formatter = DateFormatter()
            formatter.locale = dateLocale
            formatter.calendar = calendar
            formatter.isLenient = false
            for format in formats {
                formatter.dateFormat = format
                guard var date = formatter.date(from: text) else { continue }
                if !format.contains("y") {
                    var parts = calendar.dateComponents([.month, .day], from: date)
                    parts.year = calendar.component(.year, from: today)
                    guard let thisYear = calendar.date(from: parts) else { continue }
                    date = thisYear
                    if preferFuture == true, date < today { date = calendar.date(byAdding: .year, value: 1, to: date)! }
                    if preferFuture == false, date > today { date = calendar.date(byAdding: .year, value: -1, to: date)! }
                }
                return calendar.startOfDay(for: date)
            }
        }
        return nil
    }
}
