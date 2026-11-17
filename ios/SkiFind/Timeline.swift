import Foundation
import CoreLocation

/// A day's history turned into "stayed here" and "moving" pieces, like Life360's timeline.
enum Segment: Identifiable {
    case stay(lat: Double, lng: Double, start: Date, end: Date, ongoing: Bool)
    case move(start: Date, end: Date, meters: Double, ongoing: Bool)

    var id: String {
        switch self {
        case let .stay(_, _, s, _, _): return "s\(s.timeIntervalSince1970)"
        case let .move(s, _, _, _): return "m\(s.timeIntervalSince1970)"
        }
    }
}

enum Timeline {
    private static let stayRadius: CLLocationDistance = 150
    private static let minStay: TimeInterval = 8 * 60
    private static let gap: TimeInterval = 10 * 60

    private static func dist(_ aLat: Double, _ aLng: Double, _ bLat: Double, _ bLng: Double) -> CLLocationDistance {
        CLLocation(latitude: aLat, longitude: aLng).distance(from: CLLocation(latitude: bLat, longitude: bLng))
    }

    /// `points` oldest first. Returns oldest first.
    static func build(_ points: [HistPoint], isToday: Bool, now: Date, dayEnd: Date) -> [Segment] {
        let p = points.filter { $0.accuracy < 300 }
        let n = p.count
        guard n > 0 else { return [] }

        struct S { let from, to: Int; let lat, lng: Double; let start, end: Date; let ongoing: Bool }
        var stays: [S] = []
        var i = 0
        while i < n {
            var lat = p[i].lat, lng = p[i].lng
            var j = i + 1
            while j < n && dist(lat, lng, p[j].lat, p[j].lng) <= stayRadius {
                let k = Double(j - i + 1)
                lat += (p[j].lat - lat) / k
                lng += (p[j].lng - lng) / k
                j += 1
            }
            let start = p[i].t
            let lastIn = p[j - 1].t
            let atEnd = j == n
            // iOS only reports when you move again, so a long gap before the next point means you left around then.
            let end: Date
            if !atEnd {
                end = p[j].t.timeIntervalSince(lastIn) > gap ? p[j].t.addingTimeInterval(-120) : lastIn
            } else if isToday {
                end = now
            } else {
                end = max(lastIn, dayEnd)
            }
            if end.timeIntervalSince(start) >= minStay {
                stays.append(S(from: i, to: j - 1, lat: lat, lng: lng, start: start, end: end, ongoing: atEnd && isToday))
                i = j
            } else {
                i += 1
            }
        }

        func pathMeters(_ from: Int, _ to: Int) -> Double {
            guard to > from else { return 0 }
            var m = 0.0
            for k in from..<to { m += dist(p[k].lat, p[k].lng, p[k + 1].lat, p[k + 1].lng) }
            return m
        }

        var out: [Segment] = []
        var prevIdx = 0
        var prevEnd = p[0].t
        for (idx, s) in stays.enumerated() {
            let from = idx == 0 ? 0 : prevIdx
            if s.from > from || (idx > 0 && s.start.timeIntervalSince(prevEnd) > 60) {
                let meters = pathMeters(from, s.from)
                if meters > 100 { out.append(.move(start: prevEnd, end: s.start, meters: meters, ongoing: false)) }
            }
            out.append(.stay(lat: s.lat, lng: s.lng, start: s.start, end: s.end, ongoing: s.ongoing))
            prevIdx = s.to
            prevEnd = s.end
        }
        if prevIdx < n - 1 {
            let meters = pathMeters(prevIdx, n - 1)
            if meters > 100 {
                out.append(.move(start: prevEnd, end: isToday ? max(p[n - 1].t, prevEnd) : p[n - 1].t, meters: meters, ongoing: isToday))
            }
        }
        return out
    }
}
