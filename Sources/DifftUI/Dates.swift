import Foundation

/// Date formatting with the formatters built once.
///
/// `ISO8601DateFormatter`, `DateFormatter` and `RelativeDateTimeFormatter` each
/// build ICU state when constructed — tens of microseconds each. They were
/// being constructed inside `body`: two per comment card, two per commit row,
/// re-run on every render pass. A two-hundred-commit PR paid for four hundred
/// of them on every keystroke in the commits search field.
///
/// Main-actor because Foundation's formatters are not thread-safe and every
/// caller is a SwiftUI view.
@MainActor
public enum Dates {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// GitHub occasionally includes fractional seconds; the strict parser
    /// rejects those, so a second configuration covers them.
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let abbreviated: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static let full: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static let longDay: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    public static func parse(_ isoString: String) -> Date? {
        iso.date(from: isoString) ?? isoFractional.date(from: isoString)
    }

    /// "3d", "2 mo" — empty when the timestamp will not parse, so a caller can
    /// drop the segment rather than show a placeholder.
    public static func age(iso isoString: String, now: Date = Date()) -> String {
        guard let date = parse(isoString) else { return "" }
        return abbreviated.localizedString(for: date, relativeTo: now)
    }

    /// "two hours ago". Under a minute this says "just now": the relative
    /// formatter rounds a fresh timestamp to "in 0 seconds" — future tense,
    /// and an artefact of the run's own duration.
    public static func since(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return full.localizedString(for: date, relativeTo: now)
    }

    /// "5 September 2026", or the raw string when it will not parse — better a
    /// stray header than a crash.
    public static func day(iso isoString: String) -> String {
        guard let date = parse(isoString) else { return isoString }
        return longDay.string(from: date)
    }
}
