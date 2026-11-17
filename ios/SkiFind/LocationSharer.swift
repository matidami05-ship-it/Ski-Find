import Foundation
import CoreLocation
import UIKit
import UserNotifications

/// Sends this iPhone's location to the circle, including while the app is closed
/// (needs "Always" location access). iOS wakes the app when you move.
@MainActor
final class LocationSharer: NSObject, ObservableObject {
    static let shared = LocationSharer()

    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var preciseOff = false
    @Published private(set) var lastLocation: CLLocation?

    private let manager = CLLocationManager()
    private var uploading = false
    private var pending: CLLocation?
    private var forceNext = true
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private let wakeRegionId = "skifind.wake"
    private let placePrefix = "place."
    private var lastEventCheck = Date.distantPast

    private let moveMeters: CLLocationDistance = 25
    private let heartbeat: TimeInterval = 5 * 60

    override init() {
        super.init()
        authorization = manager.authorizationStatus
        manager.delegate = self
        UIDevice.current.isBatteryMonitoringEnabled = true
        preciseOff = manager.accuracyAuthorization == .reducedAccuracy
    }

    var hasAlways: Bool { authorization == .authorizedAlways }

    // MARK: Permission

    func askPermission() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            if Store.askedAlways {
                openSettings()
            } else {
                Store.askedAlways = true
                manager.requestAlwaysAuthorization()
            }
        default:
            openSettings()
        }
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: Start / stop

    /// Starts sharing if this phone is in a circle and sharing is on. Safe to call often.
    func resume() {
        guard Store.circleId != nil, Store.sharing else { stop(); return }
        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 20
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = true
        if status == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = false
            // These two wake the app even after it's been closed or the phone restarted.
            manager.startMonitoringSignificantLocationChanges()
            manager.startMonitoringVisits()
        }
        manager.startUpdatingLocation()
    }

    /// Sends a fresh position as soon as one arrives (used when the app opens).
    func refreshNow() {
        forceNext = true
        resume()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopMonitoringVisits()
        for r in manager.monitoredRegions where r.identifier == wakeRegionId {
            manager.stopMonitoring(for: r)
        }
    }

    // MARK: Location events (on the main actor)

    private func authorizationChanged() {
        authorization = manager.authorizationStatus
        preciseOff = manager.accuracyAuthorization == .reducedAccuracy
        forceNext = true
        resume()
    }

    private func got(_ loc: CLLocation) {
        lastLocation = loc
        upload(loc, force: forceNext)
        checkPlaces(loc)
    }

    /// iOS paused GPS because we're standing still. Leave a fence here so moving away wakes us up.
    private func paused() {
        guard let loc = lastLocation ?? manager.location else { return }
        upload(loc, force: true)
        guard hasAlways, CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let region = CLCircularRegion(center: loc.coordinate, radius: 120, identifier: wakeRegionId)
        region.notifyOnExit = true
        region.notifyOnEntry = false
        manager.startMonitoring(for: region)
    }

    private func wake(region: CLRegion?) {
        if let region {
            if region.identifier.hasPrefix(placePrefix) {
                placeRegion(region.identifier, entered: false)
                return
            }
            guard region.identifier == wakeRegionId else { return }
            manager.stopMonitoring(for: region)
        }
        guard Store.circleId != nil, Store.sharing else { return }
        forceNext = true
        manager.startUpdatingLocation()
        if region == nil, let loc = manager.location { upload(loc, force: true) }
    }

    // MARK: Places & alerts

    /// Saves the circle's places and asks iOS to wake the app when crossing them (up to 19).
    func setPlaces(_ places: [Place]) {
        guard places != Store.places || manager.monitoredRegions.filter({ $0.identifier.hasPrefix(placePrefix) }).count != min(places.count, 19) else { return }
        Store.places = places
        for r in manager.monitoredRegions where r.identifier.hasPrefix(placePrefix) {
            manager.stopMonitoring(for: r)
        }
        guard hasAlways, Store.circleId != nil, CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        for p in places.prefix(19) {
            let r = CLCircularRegion(center: p.coordinate, radius: min(max(p.radius, 100), manager.maximumRegionMonitoringDistance),
                                     identifier: placePrefix + p.id)
            r.notifyOnEntry = true
            r.notifyOnExit = true
            manager.startMonitoring(for: r)
        }
    }

    /// iOS told us we crossed a place's edge.
    fileprivate func placeRegion(_ identifier: String, entered: Bool) {
        let id = String(identifier.dropFirst(placePrefix.count))
        guard let place = Store.places.first(where: { $0.id == id }) else { return }
        var inside = Store.insidePlaces
        var known = Store.knownPlaces
        let wasIn = inside.contains(id)
        if entered { inside.insert(id) } else { inside.remove(id) }
        if known.contains(id), wasIn != entered { sendEvent(place.name, arrived: entered) }
        known.insert(id)
        Store.insidePlaces = inside
        Store.knownPlaces = known
        // Also send a fresh position while iOS has us awake.
        forceNext = true
        if Store.circleId != nil, Store.sharing { manager.startUpdatingLocation() }
    }

    /// Same check from GPS fixes, in case iOS is slow to report a crossing.
    private func checkPlaces(_ loc: CLLocation) {
        guard Store.circleId != nil, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 200 else { return }
        let places = Store.places
        guard !places.isEmpty else { return }
        let ids = Set(places.map(\.id))
        var inside = Store.insidePlaces.intersection(ids)
        var known = Store.knownPlaces.intersection(ids)
        for p in places {
            let d = loc.distance(from: CLLocation(latitude: p.lat, longitude: p.lng))
            let wasIn = inside.contains(p.id)
            let margin = max(40, min(loc.horizontalAccuracy, 100))
            let nowIn = wasIn ? d <= p.radius + margin : d <= p.radius
            if nowIn { inside.insert(p.id) } else { inside.remove(p.id) }
            if !known.contains(p.id) {
                known.insert(p.id) // first look: just remember, no alert
            } else if nowIn != wasIn {
                sendEvent(p.name, arrived: nowIn)
            }
        }
        Store.insidePlaces = inside
        Store.knownPlaces = known
    }

    private func sendEvent(_ place: String, arrived: Bool) {
        guard let cid = Store.circleId, Store.sharing else { return }
        let box = BackgroundTaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "SkiFindEvent") { box.end() }
        Task {
            try? await Cloud.shared.addEvent(cid, place: place, arrived: arrived)
            box.end()
        }
    }

    /// Shows a notification for each new arrive/leave by someone else.
    func checkEvents(force: Bool = false) async {
        guard let cid = Store.circleId else { return }
        guard force || Date().timeIntervalSince(lastEventCheck) > 50 else { return }
        lastEventCheck = Date()
        let nowMs = Date().timeIntervalSince1970 * 1000
        if Store.lastEventAt == 0 { Store.lastEventAt = nowMs }
        guard let events = try? await Cloud.shared.eventsSince(cid, after: Store.lastEventAt), !events.isEmpty else { return }
        Store.lastEventAt = events.map(\.at).max() ?? Store.lastEventAt
        guard Store.alerts else { return }
        let me = Store.uid
        for e in events where e.uid != me && nowMs - e.at < 2 * 3600 * 1000 {
            let c = UNMutableNotificationContent()
            c.title = e.arrived ? "\(e.person) arrived at \(e.place)" : "\(e.person) left \(e.place)"
            c.body = Date(timeIntervalSince1970: e.at / 1000).formatted(date: .omitted, time: .shortened)
            c.sound = .default
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: e.id, content: c, trigger: nil))
        }
    }

    // MARK: Upload

    private func upload(_ loc: CLLocation, force: Bool) {
        guard let cid = Store.circleId, Store.sharing else { return }
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 2000 else { return }
        let last = CLLocation(latitude: Store.lastLat, longitude: Store.lastLng)
        let stale = Date().timeIntervalSince1970 - Store.lastUploadAt > heartbeat
        guard force || stale || loc.distance(from: last) > moveMeters else { return }
        forceNext = false
        if uploading { pending = loc; return }
        uploading = true

        // Ask iOS for a few seconds to finish the upload if we're in the background.
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "SkiFindUpload") { [weak self] in
            self?.endBackgroundTask()
        }
        let device = UIDevice.current
        let battery: Int? = device.batteryLevel < 0 ? nil : Int((device.batteryLevel * 100).rounded())
        let charging = device.batteryState == .charging || device.batteryState == .full

        Task {
            do {
                try await Cloud.shared.uploadLocation(
                    cid, lat: loc.coordinate.latitude, lng: loc.coordinate.longitude,
                    accuracy: loc.horizontalAccuracy, speed: loc.speed, battery: battery, charging: charging)
                Store.lastUploadAt = Date().timeIntervalSince1970
                Store.lastLat = loc.coordinate.latitude
                Store.lastLng = loc.coordinate.longitude
                // We're awake anyway: look for the other person's arrive/leave alerts.
                await self.checkEvents()
            } catch let e as HTTPError where e.code == 403 {
                // Removed from the circle on the other phone?
                var removed = false
                do { removed = try await Cloud.shared.loadCircle(cid) == nil } catch {}
                if removed {
                    Store.circleId = nil
                    self.stop()
                    NotificationCenter.default.post(name: .skiFindRemoved, object: nil)
                }
            } catch {
                // Offline: the next movement or heartbeat tries again.
            }
            self.uploading = false
            if let next = self.pending {
                self.pending = nil
                self.upload(next, force: true)
            }
            self.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }
}

extension LocationSharer: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.authorizationChanged() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.got(loc) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in self.paused() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in self.wake(region: region) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in
            if id.hasPrefix("place.") { self.placeRegion(id, entered: true) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        Task { @MainActor in self.wake(region: nil) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {}
}

/// Holds a background-task id so the task can be ended from either the expiry handler or the upload.
@MainActor
final class BackgroundTaskBox {
    var id = UIBackgroundTaskIdentifier.invalid
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

extension Notification.Name {
    static let skiFindRemoved = Notification.Name("skiFindRemoved")
}
