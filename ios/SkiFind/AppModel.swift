import Foundation
import CoreLocation
import SwiftUI

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

    private var pollTask: Task<Void, Never>?
    private var geoCache: [String: String] = [:]
    private let geocoder = CLGeocoder()
    private var removedObserver: NSObjectProtocol?

    init() {
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
