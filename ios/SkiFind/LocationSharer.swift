import Foundation
import CoreLocation
import UIKit

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
            guard region.identifier == wakeRegionId else { return }
            manager.stopMonitoring(for: region)
        }
        guard Store.circleId != nil, Store.sharing else { return }
        forceNext = true
        manager.startUpdatingLocation()
        if region == nil, let loc = manager.location { upload(loc, force: true) }
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

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        Task { @MainActor in self.wake(region: nil) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {}
}

extension Notification.Name {
    static let skiFindRemoved = Notification.Name("skiFindRemoved")
}
