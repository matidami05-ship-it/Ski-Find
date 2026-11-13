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

struct Circle: Equatable {
    let id: String
    var members: [String]
    var names: [String: String]
    var joinCode: String
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
        if data.isEmpty { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
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
            [
                "update": ["name": name("findCircles/\(cid)"), "fields": [String: Any]()],
                "updateMask": ["fieldPaths": ["names.`\(who)`"]],
                "updateTransforms": [["fieldPath": "members", "removeAllFromArray": ["values": [str(who)]]]],
                "currentDocument": ["exists": true],
            ],
        ])
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
        try await commit([[
            "update": ["name": name("findCircles/\(cid)/locations/\(uid)"), "fields": f],
            "updateTransforms": [["fieldPath": "updated", "setToServerValue": "REQUEST_TIME"]],
        ]])
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
        return Circle(id: cid, members: members, names: names, joinCode: string(f, "joinCode") ?? "")
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

    static func randomId(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<n).map { _ in chars.randomElement()! })
    }

    static func makeCode() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in chars.randomElement()! })
    }
}
