import Foundation
import CoreLocation
import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var circle: Circle?
    @Published var people: [Person] = []
    @Published var myUid: String? = Store.uid
    @Published var myName: String = Store.name
    @Published var sharing: Bool = Store.sharing
    @Published var busy = false
    @Published var error: String?
    @Published var offline = false
    @Published var addresses: [String: String] = [:]
    /// uid -> profile photo
    @Published var photos: [String: UIImage] = [:]
    @Published var places: [Place] = Store.places
    @Published var alerts: Bool = Store.alerts

    // History sheet
    @Published var historyUid: String?
    @Published var historyDay = 0          // 0 = today, 1 = yesterday …
    @Published var historyPoints: [HistPoint] = []
    @Published var historySegments: [Segment] = []
    @Published var historyLoading = false
    @Published var historyError: String?

    private var pollTask: Task<Void, Never>?
    private var geoCache: [String: String] = [:]
    private let geocoder = CLGeocoder()
    private var removedObserver: NSObjectProtocol?

    init() {
        photos = PhotoCache.loadAll()
        if let cid = Store.circleId {
            // Show the map right away; details fill in when loaded.
            circle = Circle(id: cid, members: [], names: [:], joinCode: "")
        }
        removedObserver = NotificationCenter.default.addObserver(forName: .skiFindRemoved, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.circle = nil; self?.people = [] }
        }
    }

    var members: [String] { circle?.members ?? [] }

    // MARK: Polling while on screen

    func setActive(_ active: Bool) {
        if active {
            LocationSharer.shared.refreshNow()
            startPolling()
        } else {
            pollTask?.cancel()
            pollTask = nil
            AppDelegate.scheduleRefresh()
        }
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                await self?.poll(tick: tick)
                tick += 1
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func refreshNow() {
        pollTask?.cancel()
        pollTask = nil
        startPolling()
    }

    private func poll(tick: Int) async {
        guard let cid = Store.circleId else { return }
        do {
            if tick % 6 == 0 {
                if let c = try await Cloud.shared.loadCircle(cid) {
                    circle = c
                    myUid = Store.uid
                    await syncPhotos(c)
                    if let pl = try? await Cloud.shared.places(cid) {
                        if pl != places { places = pl }
                        LocationSharer.shared.setPlaces(pl)
                    }
                } else {
                    // Removed on the other phone.
                    Store.circleId = nil
                    LocationSharer.shared.stop()
                    circle = nil
                    people = []
                    return
                }
            }
            let all = try await Cloud.shared.locations(cid)
            let m = members
            let visible = m.isEmpty ? all : all.filter { m.contains($0.id) }
            if visible != people { people = visible }
            offline = false
            await lookupAddresses(visible)
            await LocationSharer.shared.checkEvents()
        } catch {
            offline = true
        }
    }

    // MARK: Actions

    func create(name: String) {
        act {
            let c = try await Cloud.shared.createCircle(myName: name.trimmingCharacters(in: .whitespaces))
            self.didPair(c)
        }
    }

    func join(name: String, code: String) {
        act {
            guard let c = try await Cloud.shared.joinCircle(myName: name.trimmingCharacters(in: .whitespaces), code: code) else {
                throw UserFacingError(message: "That code wasn't found. Check it on the other phone.")
            }
            self.didPair(c)
        }
    }

    /// Join someone else's code from Settings, leaving the group this phone is in now.
    func switchTo(code: String) {
        act {
            let old = Store.circleId
            let name = Store.name.isEmpty ? "Me" : Store.name
            guard let c = try await Cloud.shared.joinCircle(myName: name, code: code) else {
                throw UserFacingError(message: "That code wasn't found. Check it on the other phone.")
            }
            if let old, old != c.id, let me = Store.uid {
                try? await Cloud.shared.remove(old, who: me)
            }
            self.people = []
            self.didPair(c)
        }
    }

    private func didPair(_ c: Circle) {
        Store.sharing = true
        sharing = true
        circle = c
        myUid = Store.uid
        myName = Store.name
        Store.lastUploadAt = 0
        LocationSharer.shared.askPermission()
        LocationSharer.shared.refreshNow()
        refreshNow()
    }

    func rename(_ name: String) {
        act {
            guard let cid = Store.circleId else { return }
            try await Cloud.shared.rename(cid, to: name.trimmingCharacters(in: .whitespaces))
            self.myName = Store.name
            Store.lastUploadAt = 0 // send the new name with the next position
            LocationSharer.shared.refreshNow()
        }
    }

    func setSharing(_ on: Bool) {
        Store.sharing = on
        sharing = on
        guard let cid = Store.circleId else { return }
        if on {
            LocationSharer.shared.refreshNow()
        } else {
            LocationSharer.shared.stop()
            Task { try? await Cloud.shared.setSharingFlag(cid, false) }
        }
    }

    func remove(_ uid: String) {
        act {
            guard let cid = Store.circleId else { return }
            try await Cloud.shared.remove(cid, who: uid)
            self.people.removeAll { $0.id == uid }
            self.refreshNow()
        }
    }

    func leave() {
        act {
            guard let cid = Store.circleId else { return }
            LocationSharer.shared.stop()
            if let me = Store.uid { try? await Cloud.shared.remove(cid, who: me) }
            Store.circleId = nil
            Store.lastUploadAt = 0
            self.circle = nil
            self.people = []
        }
    }

    private func act(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do {
                try await work()
            } catch let e as UserFacingError {
                self.error = e.message
            } catch let e as HTTPError {
                self.error = "Something went wrong (\(e.code)). Try again."
            } catch {
                self.error = "Couldn't reach Ski Find. Check your connection and try again."
            }
            self.busy = false
        }
    }

    // MARK: Profile photos

    /// Downloads photos that are new or changed since last time; drops ones that were removed.
    private func syncPhotos(_ c: Circle) async {
        for uid in c.members {
            let version = c.photos[uid]
            if let version, !version.isEmpty {
                guard PhotoCache.version(uid) != version else { continue }
                if let b64 = try? await Cloud.shared.loadPhoto(c.id, uid: uid),
                   let data = Data(base64Encoded: b64), let img = UIImage(data: data) {
                    PhotoCache.save(uid, data: data, version: version)
                    photos[uid] = img
                }
            } else if photos[uid] != nil {
                PhotoCache.remove(uid)
                photos[uid] = nil
            }
        }
    }

    func setMyPhoto(_ image: UIImage) {
        guard let data = PhotoCache.squareJPEG(image) else { return }
        act {
            guard let cid = Store.circleId, let me = Store.uid else { return }
            let version = try await Cloud.shared.setPhoto(cid, base64: data.base64EncodedString())
            PhotoCache.save(me, data: data, version: version)
            self.photos[me] = UIImage(data: data)
        }
    }

    func removeMyPhoto() {
        act {
            guard let cid = Store.circleId, let me = Store.uid else { return }
            try await Cloud.shared.removePhoto(cid)
            PhotoCache.remove(me)
            self.photos[me] = nil
        }
    }

    // MARK: History

    func openHistory(_ uid: String, day: Int = 0) {
        historyUid = uid
        historyDay = day
        historyPoints = []
        historySegments = []
        historyError = nil
        historyLoading = true
        guard let cid = Store.circleId else { return }
        Task {
            let cal = Calendar.current
            let date = cal.date(byAdding: .day, value: -day, to: cal.startOfDay(for: Date()))!
            let dayEnd = cal.date(byAdding: .day, value: 1, to: date)!.addingTimeInterval(-1)
            let prev = cal.date(byAdding: .day, value: -1, to: date)!
            do {
                let today = try await Cloud.shared.history(cid, uid: uid, day: Cloud.dayKey(date))
                let before = (try? await Cloud.shared.history(cid, uid: uid, day: Cloud.dayKey(prev))) ?? []
                // Carry over where they were at midnight, so the day starts with that stay.
                var points = today
                if let last = before.last {
                    points.insert(HistPoint(lat: last.lat, lng: last.lng, t: date, accuracy: last.accuracy), at: 0)
                }
                guard historyUid == uid, historyDay == day else { return }
                historyPoints = points
                historySegments = Timeline.build(points, isToday: day == 0, now: Date(), dayEnd: dayEnd)
                historyLoading = false
            } catch {
                guard historyUid == uid, historyDay == day else { return }
                historyError = "Couldn't load history. Check your connection."
                historyLoading = false
            }
        }
    }

    /// A saved place's name if the spot is inside one, otherwise the street address.
    func label(lat: Double, lng: Double) async -> String? {
        let here = CLLocation(latitude: lat, longitude: lng)
        if let p = places
            .map({ ($0, here.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lng))) })
            .filter({ $0.1 <= $0.0.radius + 75 })
            .min(by: { $0.1 < $1.1 })?.0 {
            return p.name
        }
        let key = String(format: "%.4f,%.4f", lat, lng)
        if let cached = geoCache[key] { return cached }
        // One lookup at a time; Apple limits how fast we can ask.
        for _ in 0..<20 where geocoder.isGeocoding { try? await Task.sleep(nanoseconds: 300_000_000) }
        guard let m = try? await geocoder.reverseGeocodeLocation(here).first else { return nil }
        let street = [m.subThoroughfare, m.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let parts = [street, m.locality ?? ""].filter { !$0.isEmpty }
        let text = parts.isEmpty ? (m.name ?? "") : parts.joined(separator: ", ")
        guard !text.isEmpty else { return nil }
        geoCache[key] = text
        return text
    }

    // MARK: Places & alerts

    func savePlace(name: String, lat: Double, lng: Double, radius: Double, id: String? = nil) {
        let p = Place(id: id ?? Cloud.randomId(16), name: name.trimmingCharacters(in: .whitespaces),
                      lat: lat, lng: lng, radius: radius)
        askNotificationPermission()
        act {
            guard let cid = Store.circleId else { return }
            try await Cloud.shared.savePlace(cid, p)
            var list = self.places.filter { $0.id != p.id }
            list.append(p)
            list.sort { $0.name.lowercased() < $1.name.lowercased() }
            self.places = list
            LocationSharer.shared.setPlaces(list)
        }
    }

    func deletePlace(_ id: String) {
        act {
            guard let cid = Store.circleId else { return }
            try await Cloud.shared.deletePlace(cid, id: id)
            self.places.removeAll { $0.id == id }
            LocationSharer.shared.setPlaces(self.places)
        }
    }

    func setAlerts(_ on: Bool) {
        Store.alerts = on
        alerts = on
        if on { askNotificationPermission() }
    }

    func askNotificationPermission() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    // MARK: Street addresses

    private func lookupAddresses(_ list: [Person]) async {
        for p in list {
            // ~50 m grid so the same spot isn't looked up every 10 seconds.
            let key = String(format: "%.4f,%.4f", p.lat, p.lng)
            if let cached = geoCache[key] {
                if addresses[p.id] != cached { addresses[p.id] = cached }
                continue
            }
            guard !geocoder.isGeocoding else { continue }
            if let marks = try? await geocoder.reverseGeocodeLocation(CLLocation(latitude: p.lat, longitude: p.lng)),
               let m = marks.first {
                let street = [m.subThoroughfare, m.thoroughfare].compactMap { $0 }.joined(separator: " ")
                let parts = [street, m.locality ?? ""].filter { !$0.isEmpty }
                let text = parts.isEmpty ? (m.name ?? "") : parts.joined(separator: ", ")
                guard !text.isEmpty else { continue }
                geoCache[key] = text
                addresses[p.id] = text
            }
        }
    }
}

/// Keeps profile photos on disk so they show instantly and are only downloaded when they change.
enum PhotoCache {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var versions: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "photoVersions") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "photoVersions") }
    }

    static func version(_ uid: String) -> String? { versions[uid] }

    static func save(_ uid: String, data: Data, version: String) {
        try? data.write(to: dir.appendingPathComponent("\(uid).jpg"), options: .atomic)
        versions[uid] = version
    }

    static func remove(_ uid: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(uid).jpg"))
        versions[uid] = nil
    }

    static func loadAll() -> [String: UIImage] {
        var out: [String: UIImage] = [:]
        for uid in versions.keys {
            if let img = UIImage(contentsOfFile: dir.appendingPathComponent("\(uid).jpg").path) { out[uid] = img }
        }
        return out
    }

    /// Center-cropped 256×256 JPEG, roughly 15–30 KB.
    static func squareJPEG(_ image: UIImage, size: CGFloat = 256) -> Data? {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let side = min(w, h)
        let scale = size / side
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let out = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { _ in
            image.draw(in: CGRect(x: (size - w * scale) / 2, y: (size - h * scale) / 2, width: w * scale, height: h * scale))
        }
        return out.jpegData(compressionQuality: 0.75)
    }
}
