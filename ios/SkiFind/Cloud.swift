import Foundation
import CoreLocation

/// Talks to Ski Find's own Firebase project (free Spark plan) over its REST API — no Firebase SDK needed.
///
///   findCodes/{CODE}                    { circleId }
///   findCircles/{cid}                   { members: [uid], names: {uid: name}, joinCode }
///   findCircles/{cid}/locations/{uid}   { name, lat, lng, accuracy, speed, battery, charging, platform, sharing, updated }
/// Filled in by the GitHub workflow from the FIREBASE_API_KEY and FIREBASE_PROJECT_ID secrets.
enum Config {
    static let apiKey = "__FIREBASE_API_KEY__"
    static let projectId = "__FIREBASE_PROJECT_ID__"
}

enum Store {
    private static let d = UserDefaults.standard
    static var uid: String? { get { d.string(forKey: "uid") } set { d.set(newValue, forKey: "uid") } }
    static var idToken: String? { get { d.string(forKey: "idToken") } set { d.set(newValue, forKey: "idToken") } }
    static var refreshToken: String? { get { d.string(forKey: "refreshToken") } set { d.set(newValue, forKey: "refreshToken") } }
    static var tokenExpiry: Double { get { d.double(forKey: "tokenExpiry") } set { d.set(newValue, forKey: "tokenExpiry") } }
    static var circleId: String? { get { d.string(forKey: "circleId") } set { d.set(newValue, forKey: "circleId") } }
    static var name: String { get { d.string(forKey: "name") ?? "" } set { d.set(newValue, forKey: "name") } }
    static var sharing: Bool {
        get { d.object(forKey: "sharing") == nil ? true : d.bool(forKey: "sharing") }
        set { d.set(newValue, forKey: "sharing") }
    }
    static var askedAlways: Bool { get { d.bool(forKey: "askedAlways") } set { d.set(newValue, forKey: "askedAlways") } }
    static var lastUploadAt: Double { get { d.double(forKey: "lastUploadAt") } set { d.set(newValue, forKey: "lastUploadAt") } }
    static var lastLat: Double { get { d.double(forKey: "lastLat") } set { d.set(newValue, forKey: "lastLat") } }
    static var lastLng: Double { get { d.double(forKey: "lastLng") } set { d.set(newValue, forKey: "lastLng") } }
    static var lastHistoryDay: String? { get { d.string(forKey: "lastHistoryDay") } set { d.set(newValue, forKey: "lastHistoryDay") } }
    static var alerts: Bool {
        get { d.object(forKey: "alerts") == nil ? true : d.bool(forKey: "alerts") }
        set { d.set(newValue, forKey: "alerts") }
    }
    static var lastPingSeen: Double { get { d.double(forKey: "lastPingSeen") } set { d.set(newValue, forKey: "lastPingSeen") } }
    static var lastEventAt: Double { get { d.double(forKey: "lastEventAt") } set { d.set(newValue, forKey: "lastEventAt") } }
    /// Place ids this phone is inside right now.
    static var insidePlaces: Set<String> {
        get { Set(d.stringArray(forKey: "insidePlaces") ?? []) }
        set { d.set(Array(newValue), forKey: "insidePlaces") }
    }
    /// Place ids we've already checked once (the first check never alerts).
    static var knownPlaces: Set<String> {
        get { Set(d.stringArray(forKey: "knownPlaces") ?? []) }
        set { d.set(Array(newValue), forKey: "knownPlaces") }
    }
    /// Last known list of places, so the app can check them when iOS wakes it in the background.
    static var places: [Place] {
        get { (d.data(forKey: "places")).flatMap { try? JSONDecoder().decode([Place].self, from: $0) } ?? [] }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "places") }
    }
}

struct Person: Identifiable, Equatable {
    let id: String // uid
    var name: String
    var lat: Double
    var lng: Double
    var accuracy: Double
    var speed: Double
    var battery: Int?
    var charging: Bool
    var platform: String
    var sharing: Bool
    var updated: Date?

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
}

struct Place: Identifiable, Equatable, Codable {
    let id: String
    var name: String
    var lat: Double
    var lng: Double
    var radius: Double

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
}

struct HistPoint: Equatable {
    let lat: Double
    let lng: Double
    let t: Date
    let accuracy: Double

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
}

struct PlaceEvent {
    let id: String
    let uid: String
    let person: String
    let place: String
    let arrived: Bool
    let at: Double // ms
}

struct Circle: Equatable {
    let id: String
    var members: [String]
    var names: [String: String]
    var joinCode: String
    /// uid -> version of that person's profile photo (changes whenever they pick a new one).
    var photos: [String: String] = [:]
}

struct HTTPError: Error {
    let code: Int
    let body: String
}

struct UserFacingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

actor Cloud {
    static let shared = Cloud()

    private let docRoot = "projects/\(Config.projectId)/databases/(default)/documents"
    private var base: String { "https://firestore.googleapis.com/v1/\(docRoot)" }
    private var tokenTask: Task<String, Error>?

    // MARK: HTTP

    private func http(_ method: String, _ url: String, _ body: [String: Any]?, token: String?) async throws -> [String: Any] {
        (try await httpAny(method, url, body, token: token) as? [String: Any]) ?? [:]
    }

    private func httpAny(_ method: String, _ url: String, _ body: [String: Any]?, token: String?) async throws -> Any {
        guard let u = URL(string: url) else { throw HTTPError(code: 0, body: "bad url") }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw HTTPError(code: code, body: String(data: data, encoding: .utf8) ?? "")
        }
        if data.isEmpty { return [String: Any]() }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: Sign-in (anonymous Firebase account, kept for good)

    func token() async throws -> String {
        if let t = tokenTask { return try await t.value }
        if let tok = Store.idToken, Date().timeIntervalSince1970 < Store.tokenExpiry - 120 { return tok }
        let task = Task { try await self.fetchToken() }
        tokenTask = task
        defer { tokenTask = nil }
        return try await task.value
    }

    private func fetchToken() async throws -> String {
        let now = Date().timeIntervalSince1970
        if let rt = Store.refreshToken {
            do {
                let r = try await http("POST", "https://securetoken.googleapis.com/v1/token?key=\(Config.apiKey)",
                                       ["grant_type": "refresh_token", "refresh_token": rt], token: nil)
                let tok = r["id_token"] as? String ?? ""
                Store.idToken = tok
                Store.refreshToken = r["refresh_token"] as? String
                Store.tokenExpiry = now + (Double(r["expires_in"] as? String ?? "3600") ?? 3600)
                Store.uid = r["user_id"] as? String
                return tok
            } catch let e as HTTPError where e.code == 400 {
                // Refresh token is gone: make a new account below.
            }
        }
        let r = try await http("POST", "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=\(Config.apiKey)",
                               ["returnSecureToken": true], token: nil)
        let tok = r["idToken"] as? String ?? ""
        Store.uid = r["localId"] as? String
        Store.idToken = tok
        Store.refreshToken = r["refreshToken"] as? String
        Store.tokenExpiry = now + (Double(r["expiresIn"] as? String ?? "3600") ?? 3600)
        return tok
    }

    func uid() async throws -> String {
        _ = try await token()
        guard let u = Store.uid else { throw HTTPError(code: 0, body: "no uid") }
        return u
    }

    // MARK: Firestore helpers

    private func getDoc(_ path: String) async throws -> [String: Any]? {
        do {
            return try await http("GET", "\(base)/\(path)", nil, token: try await token())
        } catch let e as HTTPError where e.code == 404 {
            return nil
        }
    }

    private func commit(_ writes: [[String: Any]]) async throws {
        _ = try await http("POST", "\(base):commit", ["writes": writes], token: try await token())
    }

    private func name(_ path: String) -> String { "\(docRoot)/\(path)" }

    // MARK: Circle

    func loadCircle(_ cid: String) async throws -> Circle? {
        do {
            guard let d = try await getDoc("findCircles/\(cid)") else { return nil }
            return parseCircle(cid, d)
        } catch let e as HTTPError where e.code == 403 {
            return nil // no longer in it
        }
    }

    func createCircle(myName: String) async throws -> Circle {
        let uid = try await uid()
        let cid = Self.randomId(20)
        var code = Self.makeCode()
        for _ in 0..<3 {
            if try await getDoc("findCodes/\(code)") == nil { break }
            code = Self.makeCode()
        }
        try await commit([
            [
                "update": [
                    "name": name("findCircles/\(cid)"),
                    "fields": [
                        "members": arr([str(uid)]),
                        "names": map([uid: str(myName)]),
                        "joinCode": str(code),
                        "created": int(Int64(Date().timeIntervalSince1970 * 1000)),
                    ],
                ],
                "currentDocument": ["exists": false],
            ],
            [
                "update": ["name": name("findCodes/\(code)"), "fields": ["circleId": str(cid)]],
                "currentDocument": ["exists": false],
            ],
        ])
        Store.circleId = cid
        Store.name = myName
        return Circle(id: cid, members: [uid], names: [uid: myName], joinCode: code)
    }

    /// Returns nil if the code doesn't exist.
    func joinCircle(myName: String, code rawCode: String) async throws -> Circle? {
        let uid = try await uid()
        let code = rawCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard let codeDoc = try await getDoc("findCodes/\(code)"),
              let cid = (fields(codeDoc)["circleId"] as? [String: Any])?["stringValue"] as? String else { return nil }
        let already = try await loadCircle(cid) != nil
        var write: [String: Any] = ["currentDocument": ["exists": true]]
        if already {
            write["update"] = ["name": name("findCircles/\(cid)"), "fields": ["names": map([uid: str(myName)])]]
            write["updateMask"] = ["fieldPaths": ["names.`\(uid)`"]]
        } else {
            write["update"] = [
                "name": name("findCircles/\(cid)"),
                "fields": ["names": map([uid: str(myName)]), "joinCodeUsed": str(code)],
            ]
            write["updateMask"] = ["fieldPaths": ["names.`\(uid)`", "joinCodeUsed"]]
            write["updateTransforms"] = [["fieldPath": "members", "appendMissingElements": ["values": [str(uid)]]]]
        }
        try await commit([write])
        Store.circleId = cid
        Store.name = myName
        return try await loadCircle(cid)
    }

    func rename(_ cid: String, to newName: String) async throws {
        let uid = try await uid()
        try await commit([[
            "update": ["name": name("findCircles/\(cid)"), "fields": ["names": map([uid: str(newName)])]],
            "updateMask": ["fieldPaths": ["names.`\(uid)`"]],
            "currentDocument": ["exists": true],
        ]])
        Store.name = newName
    }

    /// Removes someone (or yourself, when leaving) and their last location.
    func remove(_ cid: String, who: String) async throws {
        try await commit([
            ["delete": name("findCircles/\(cid)/locations/\(who)")],
            ["delete": name("findCircles/\(cid)/photos/\(who)")],
            [
                "update": ["name": name("findCircles/\(cid)"), "fields": [String: Any]()],
                "updateMask": ["fieldPaths": ["names.`\(who)`", "photos.`\(who)`"]],
                "updateTransforms": [["fieldPath": "members", "removeAllFromArray": ["values": [str(who)]]]],
                "currentDocument": ["exists": true],
            ],
        ])
    }

    // MARK: Profile photos

    /// Saves your photo (base64 JPEG) and bumps its version so other phones download it. Returns the version.
    func setPhoto(_ cid: String, base64: String) async throws -> String {
        let uid = try await uid()
        let version = Self.randomId(8)
        try await commit([
            ["update": ["name": name("findCircles/\(cid)/photos/\(uid)"),
                        "fields": ["data": str(base64), "version": str(version)]]],
            ["update": ["name": name("findCircles/\(cid)"), "fields": ["photos": map([uid: str(version)])]],
             "updateMask": ["fieldPaths": ["photos.`\(uid)`"]],
             "currentDocument": ["exists": true]],
        ])
        return version
    }

    func removePhoto(_ cid: String) async throws {
        let uid = try await uid()
        try await commit([
            ["delete": name("findCircles/\(cid)/photos/\(uid)")],
            ["update": ["name": name("findCircles/\(cid)"), "fields": [String: Any]()],
             "updateMask": ["fieldPaths": ["photos.`\(uid)`"]],
             "currentDocument": ["exists": true]],
        ])
    }

    /// Base64 JPEG for someone's photo, or nil if they have none.
    func loadPhoto(_ cid: String, uid: String) async throws -> String? {
        guard let d = try await getDoc("findCircles/\(cid)/photos/\(uid)") else { return nil }
        return string(fields(d), "data")
    }

    // MARK: Locations

    func uploadLocation(_ cid: String, lat: Double, lng: Double, accuracy: Double, speed: Double,
                        battery: Int?, charging: Bool) async throws {
        let uid = try await uid()
        var f: [String: Any] = [
            "name": str(Store.name),
            "lat": dbl(lat), "lng": dbl(lng),
            "accuracy": dbl(accuracy), "speed": dbl(max(speed, 0)),
            "charging": ["booleanValue": charging],
            "sharing": ["booleanValue": true],
            "platform": str("ios"),
        ]
        if let battery { f["battery"] = int(Int64(battery)) }
        let now = Date()
        let day = Self.dayKey(now)
        let point = map([
            "lat": dbl(lat), "lng": dbl(lng),
            "t": int(Int64(now.timeIntervalSince1970 * 1000)), "acc": dbl(accuracy),
        ])
        var writes: [[String: Any]] = [
            [
                "update": ["name": name("findCircles/\(cid)/locations/\(uid)"), "fields": f],
                "updateTransforms": [["fieldPath": "updated", "setToServerValue": "REQUEST_TIME"]],
            ],
            // Today's history doc, one point appended.
            [
                "update": ["name": name("findCircles/\(cid)/history/\(uid)_\(day)"), "fields": ["day": str(day)]],
                "updateMask": ["fieldPaths": ["day"]],
                "updateTransforms": [["fieldPath": "points", "appendMissingElements": ["values": [point]]]],
            ],
        ]
        // First point of a new day: drop history older than a week.
        if Store.lastHistoryDay != day {
            writes.append(["delete": name("findCircles/\(cid)/history/\(uid)_\(Self.dayKey(now.addingTimeInterval(-8 * 86400)))")])
        }
        try await commit(writes)
        Store.lastHistoryDay = day
    }

    // MARK: History

    /// One person's points for a day ("yyyy-MM-dd"), oldest first.
    func history(_ cid: String, uid: String, day: String) async throws -> [HistPoint] {
        guard let d = try await getDoc("findCircles/\(cid)/history/\(uid)_\(day)") else { return [] }
        let values = (((fields(d)["points"] as? [String: Any])?["arrayValue"] as? [String: Any])?["values"] as? [[String: Any]]) ?? []
        return values.compactMap { v -> HistPoint? in
            guard let f = (v["mapValue"] as? [String: Any])?["fields"] as? [String: Any],
                  let lat = num(f, "lat"), let lng = num(f, "lng"), let t = num(f, "t") else { return nil }
            return HistPoint(lat: lat, lng: lng, t: Date(timeIntervalSince1970: t / 1000), accuracy: num(f, "acc") ?? 0)
        }.sorted { $0.t < $1.t }
    }

    // MARK: Places

    func places(_ cid: String) async throws -> [Place] {
        let r = try await http("GET", "\(base)/findCircles/\(cid)/places?pageSize=50", nil, token: try await token())
        let docs = r["documents"] as? [[String: Any]] ?? []
        return docs.compactMap { d -> Place? in
            let f = fields(d)
            guard let path = d["name"] as? String, let name = string(f, "name"),
                  let lat = num(f, "lat"), let lng = num(f, "lng") else { return nil }
            return Place(id: String(path.split(separator: "/").last ?? ""), name: name, lat: lat, lng: lng,
                         radius: num(f, "radius") ?? 150)
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    func savePlace(_ cid: String, _ p: Place) async throws {
        let uid = try await uid()
        try await commit([["update": [
            "name": name("findCircles/\(cid)/places/\(p.id)"),
            "fields": ["name": str(p.name), "lat": dbl(p.lat), "lng": dbl(p.lng), "radius": dbl(p.radius), "by": str(uid)],
        ]]])
    }

    func deletePlace(_ cid: String, id: String) async throws {
        try await commit([["delete": name("findCircles/\(cid)/places/\(id)")]])
    }

    // MARK: Refresh requests

    /// Asks the other phones to send a fresh location.
    func ping(_ cid: String) async throws {
        let uid = try await uid()
        try await commit([["update": [
            "name": name("findCircles/\(cid)/pings/\(uid)"),
            "fields": ["at": int(Int64(Date().timeIntervalSince1970 * 1000))],
        ]]])
    }

    /// Newest refresh request from someone else (ms), or 0.
    func latestPing(_ cid: String) async throws -> Double {
        let me = try await uid()
        let r = try await http("GET", "\(base)/findCircles/\(cid)/pings?pageSize=20", nil, token: try await token())
        let docs = r["documents"] as? [[String: Any]] ?? []
        return docs.compactMap { d -> Double? in
            guard let path = d["name"] as? String, !path.hasSuffix("/\(me)") else { return nil }
            return num(fields(d), "at")
        }.max() ?? 0
    }

    // MARK: Arrive / leave events

    func addEvent(_ cid: String, place: String, arrived: Bool) async throws {
        let uid = try await uid()
        try await commit([["update": [
            "name": name("findCircles/\(cid)/events/\(Self.randomId(20))"),
            "fields": [
                "uid": str(uid), "person": str(Store.name), "place": str(place),
                "kind": str(arrived ? "arrived" : "left"),
                "at": int(Int64(Date().timeIntervalSince1970 * 1000)),
            ],
        ]]])
    }

    /// Events newer than `after` (ms), oldest first.
    func eventsSince(_ cid: String, after: Double) async throws -> [PlaceEvent] {
        let q: [String: Any] = ["structuredQuery": [
            "from": [["collectionId": "events"]],
            "where": ["fieldFilter": [
                "field": ["fieldPath": "at"], "op": "GREATER_THAN", "value": int(Int64(after)),
            ]],
            "orderBy": [["field": ["fieldPath": "at"], "direction": "ASCENDING"]],
            "limit": 20,
        ]]
        let r = try await httpAny("POST", "\(base)/findCircles/\(cid):runQuery", q, token: try await token())
        let rows = r as? [[String: Any]] ?? []
        return rows.compactMap { row -> PlaceEvent? in
            guard let d = row["document"] as? [String: Any], let path = d["name"] as? String else { return nil }
            let f = fields(d)
            return PlaceEvent(
                id: String(path.split(separator: "/").last ?? ""),
                uid: string(f, "uid") ?? "", person: string(f, "person") ?? "",
                place: string(f, "place") ?? "", arrived: string(f, "kind") == "arrived",
                at: num(f, "at") ?? 0)
        }
    }

    /// Marks this phone as paused without moving its pin.
    func setSharingFlag(_ cid: String, _ on: Bool) async throws {
        let uid = try await uid()
        try await commit([[
            "update": ["name": name("findCircles/\(cid)/locations/\(uid)"), "fields": ["sharing": ["booleanValue": on]]],
            "updateMask": ["fieldPaths": ["sharing"]],
            "updateTransforms": [["fieldPath": "updated", "setToServerValue": "REQUEST_TIME"]],
        ]])
    }

    func locations(_ cid: String) async throws -> [Person] {
        let r = try await http("GET", "\(base)/findCircles/\(cid)/locations?pageSize=50", nil, token: try await token())
        guard let docs = r["documents"] as? [[String: Any]] else { return [] }
        return docs.compactMap { d in
            let f = fields(d)
            guard let path = d["name"] as? String,
                  let lat = num(f, "lat"), let lng = num(f, "lng") else { return nil }
            return Person(
                id: String(path.split(separator: "/").last ?? ""),
                name: string(f, "name") ?? "",
                lat: lat, lng: lng,
                accuracy: num(f, "accuracy") ?? 0,
                speed: num(f, "speed") ?? 0,
                battery: num(f, "battery").map { Int($0) },
                charging: bool(f, "charging") ?? false,
                platform: string(f, "platform") ?? "",
                sharing: bool(f, "sharing") ?? true,
                updated: ((f["updated"] as? [String: Any])?["timestampValue"] as? String).flatMap(Self.parseTime)
            )
        }
    }

    // MARK: Value encoding

    private func parseCircle(_ cid: String, _ d: [String: Any]) -> Circle {
        let f = fields(d)
        let members = (((f["members"] as? [String: Any])?["arrayValue"] as? [String: Any])?["values"] as? [[String: Any]] ?? [])
            .compactMap { $0["stringValue"] as? String }
        let nameFields = ((f["names"] as? [String: Any])?["mapValue"] as? [String: Any])?["fields"] as? [String: Any] ?? [:]
        var names: [String: String] = [:]
        for (k, v) in nameFields { names[k] = (v as? [String: Any])?["stringValue"] as? String ?? "" }
        let photoFields = ((f["photos"] as? [String: Any])?["mapValue"] as? [String: Any])?["fields"] as? [String: Any] ?? [:]
        var photos: [String: String] = [:]
        for (k, v) in photoFields { photos[k] = (v as? [String: Any])?["stringValue"] as? String ?? "" }
        return Circle(id: cid, members: members, names: names, joinCode: string(f, "joinCode") ?? "", photos: photos)
    }

    private func fields(_ d: [String: Any]) -> [String: Any] { d["fields"] as? [String: Any] ?? [:] }
    private func string(_ f: [String: Any], _ k: String) -> String? { (f[k] as? [String: Any])?["stringValue"] as? String }
    private func bool(_ f: [String: Any], _ k: String) -> Bool? { (f[k] as? [String: Any])?["booleanValue"] as? Bool }
    private func num(_ f: [String: Any], _ k: String) -> Double? {
        guard let v = f[k] as? [String: Any] else { return nil }
        if let d = v["doubleValue"] as? Double { return d }
        if let d = v["doubleValue"] as? NSNumber { return d.doubleValue }
        if let s = v["integerValue"] as? String { return Double(s) }
        return nil
    }

    private func str(_ s: String) -> [String: Any] { ["stringValue": s] }
    private func dbl(_ d: Double) -> [String: Any] { ["doubleValue": d.isFinite ? d : 0] }
    private func int(_ i: Int64) -> [String: Any] { ["integerValue": String(i)] }
    private func arr(_ v: [[String: Any]]) -> [String: Any] { ["arrayValue": ["values": v]] }
    private func map(_ fields: [String: Any]) -> [String: Any] { ["mapValue": ["fields": fields]] }

    static func parseTime(_ s: String) -> Date? {
        // Firestore sends e.g. 2026-11-13T15:04:05.123456Z; the date parser only knows whole seconds.
        var main = s
        var fraction = 0.0
        if let dot = s.firstIndex(of: "."), let z = s.lastIndex(of: "Z"), dot < z {
            fraction = Double("0" + s[dot..<z]) ?? 0
            main = String(s[..<dot]) + "Z"
        }
        return ISO8601DateFormatter().date(from: main)?.addingTimeInterval(fraction)
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func randomId(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<n).map { _ in chars.randomElement()! })
    }

    static func makeCode() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in chars.randomElement()! })
    }
}
