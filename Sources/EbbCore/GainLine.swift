import Foundation

/// A whole-point gain at a moment, as listed in a breakdown.
public struct GainItem: Sendable, Equatable {
    public var date: Date
    public var points: Int

    public init(date: Date, points: Int) {
        self.date = date
        self.points = points
    }
}

/// The "+5% in next 4 h" line under a window, plus the resets it's made of.
///
/// Rounding: the line shows the sum of the raw gains rounded to the nearest point;
/// each reset gets whole points by largest remainder, so the breakdown always adds
/// up to the line. Resets that get zero points aren't listed.
public struct GainLine: Sendable, Equatable {
    public var points: Int
    /// The resets behind `points`, soonest first.
    public var items: [GainItem]
    /// Upcoming resets after the ones counted in `points`, shown for context.
    public var later: [GainItem]

    /// When the last counted reset lands.
    public var lastDate: Date? { items.last?.date }

    /// All session resets within the next five hours, summed.
    public static func session(_ resets: [Restoration]) -> GainLine? {
        let items = wholePoints(resets)
        let points = items.reduce(0) { $0 + $1.points }
        guard points >= 1 else { return nil }
        return GainLine(points: points, items: items, later: [])
    }

    /// The next weekly reset worth a point; later ones ride along for the breakdown.
    public static func weekly(_ resets: [Restoration]) -> GainLine? {
        let items = resets.map { GainItem(date: $0.date, points: Int($0.gain.rounded())) }
        guard let index = items.firstIndex(where: { $0.points >= 1 }) else { return nil }
        let later = items[(index + 1)...].filter { $0.points >= 1 }
        return GainLine(points: items[index].points, items: [items[index]], later: Array(later))
    }

    /// Whole points per reset that add up to the rounded total (largest remainder;
    /// ties go to the sooner reset). Zero-point resets are dropped.
    static func wholePoints(_ resets: [Restoration]) -> [GainItem] {
        let total = Int(resets.reduce(0) { $0 + $1.gain }.rounded())
        var points = resets.map { Int($0.gain.rounded(.down)) }
        let byRemainder = resets.indices.sorted {
            let left = resets[$0].gain - resets[$0].gain.rounded(.down)
            let right = resets[$1].gain - resets[$1].gain.rounded(.down)
            return left == right ? $0 < $1 : left > right
        }
        for index in byRemainder.prefix(max(0, total - points.reduce(0, +))) {
            points[index] += 1
        }
        return zip(resets, points)
            .filter { $0.1 > 0 }
            .map { GainItem(date: $0.0.date, points: $0.1) }
    }
}
