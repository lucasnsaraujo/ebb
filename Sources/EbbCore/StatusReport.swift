import Foundation

/// What the `ebb` command prints from the app's saved status. Numbers are worked out at `now`:
/// resets that landed since the app wrote the file count as free.
public enum StatusReport {
    /// "5h 88% · W 45%" for the menu bar's pool, or `provider`'s; old numbers add their age.
    public static func statusline(_ status: PoolStatus?, provider: String?, now: Date) -> String {
        guard let status, !status.providers.isEmpty else { return "Ebb: no data" }
        guard let pool = status.pool(named: provider) else { return "Ebb: no \(provider ?? "") pool" }
        let session = WindowReading(window: .session, percent: whole(pool.session.free(at: now)), refillsAt: nil, shortWindow: pool.shortWindow)
        let weekly = WindowReading(window: .weekly, percent: whole(pool.weekly.free(at: now)), refillsAt: nil)
        var parts = [session, weekly].map { "\($0.label) \($0.percent)%" }
        if pool.isStale(at: now) {
            parts.append(pool.readAt.map { "\(RefillText.until(now, now: $0)) old" } ?? "stale")
        }
        return parts.joined(separator: " · ")
    }

    /// Each pool's two windows and the capacity that comes back next. Never lists accounts.
    public static func text(_ status: PoolStatus, now: Date, timeZone: TimeZone = .current) -> String {
        var lines: [String] = []
        for pool in status.providers {
            var heading = pool.title
            if pool.id == status.menuBarProvider { heading += " (menu bar)" }
            if pool.isStale(at: now) {
                heading += pool.readAt.map { " (last read \(RefillText.until(now, now: $0)) ago)" } ?? " (no recent reading)"
            }
            if pool.isPartial { heading += " (partial: some accounts can't be read, so they're left out)" }
            lines.append(heading)
            for (title, window) in [(pool.shortWindow.title, pool.session), ("Weekly", pool.weekly)] {
                var line = "  " + title.padding(toLength: 6, withPad: " ", startingAt: 0) + "  \(whole(window.free(at: now)))% free"
                if let refill = window.nextRefill(at: now) {
                    line += "  +\(whole(refill.gain))% \(moment(refill.date, now: now, timeZone: timeZone))"
                }
                lines.append(line)
            }
        }
        var updated = "Updated \(RefillText.until(now, now: status.updatedAt)) ago."
        if status.isStale(at: now) { updated += " Ebb may have quit, or its menu bar item is hidden." }
        lines.append(updated)
        return lines.joined(separator: "\n")
    }

    /// The schema in docs/cli.md. Fields are only ever added; a breaking change bumps `schema_version`.
    public static func json(_ status: PoolStatus, now: Date) -> Data {
        func window(_ kind: String, _ name: String, _ window: WindowStatus) -> [String: Any] {
            let refill = window.nextRefill(at: now).map { ["at": $0.date.formatted(.iso8601), "gain_percent": whole($0.gain)] as [String: Any] }
            return ["kind": kind, "name": name, "free_percent": whole(window.free(at: now)), "next_refill": refill ?? NSNull()]
        }
        let object: [String: Any] = [
            "schema_version": 1,
            "updated_at": status.updatedAt.formatted(.iso8601),
            "age_seconds": max(0, Int(now.timeIntervalSince(status.updatedAt))),
            "is_stale": status.isStale(at: now),
            "menu_bar_provider": status.menuBarProvider ?? NSNull(),
            "providers": status.providers.map { pool -> [String: Any] in
                [
                    "id": pool.id,
                    "name": pool.title,
                    "is_partial": pool.isPartial,
                    "read_at": pool.readAt?.formatted(.iso8601) ?? NSNull(),
                    "is_stale": pool.isStale(at: now),
                    "short_window": window(pool.shortWindow.jsonKind, pool.shortWindow.title, pool.session),
                    "weekly": window("weekly", "Weekly", pool.weekly),
                ]
            },
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// "at 20:05" later the same day, else "Tue 22:00".
    static func moment(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let isToday = calendar.isDate(date, inSameDayAs: now)
        let format: Date.FormatString = isToday
            ? "at \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)"
            : "\(weekday: .abbreviated) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)"
        return date.formatted(Date.VerbatimFormatStyle(format: format, locale: Locale(identifier: "en_US_POSIX"), timeZone: timeZone, calendar: calendar))
    }

    static func whole(_ percent: Double) -> Int {
        Int(percent.rounded())
    }
}

extension ShortWindow {
    /// The JSON schema's fixed name, apart from the display title.
    var jsonKind: String {
        switch self {
        case .fiveHours: "five_hours"
        case .day: "day"
        }
    }
}

extension PoolStatus {
    /// `name`'s pool, or with no name the menu bar's, else the first.
    public func pool(named name: String?) -> ProviderStatus? {
        if let name { return providers.first { $0.id == Providers.named(name)?.proxyName ?? name.lowercased() } }
        return providers.first { $0.id == menuBarProvider } ?? providers.first
    }

    /// The file itself is old: the app quit, or its item was hidden.
    public func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(updatedAt) > Self.staleAge
    }
}
