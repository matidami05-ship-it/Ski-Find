import SwiftUI
import MapKit
import CoreLocation

// MARK: - Colors per person

private let palette: [Color] = [
    Color(red: 0.18, green: 0.50, blue: 0.93), // blue (you)
    Color(red: 0.88, green: 0.33, blue: 0.60), // pink
    Color(red: 0.15, green: 0.68, blue: 0.38), // green
    Color(red: 0.95, green: 0.60, blue: 0.29), // orange
    Color(red: 0.61, green: 0.32, blue: 0.88), // purple
    Color(red: 0.00, green: 0.66, blue: 0.66), // teal
]

func personColor(_ uid: String, me: String?, members: [String]) -> Color {
    if uid == me { return palette[0] }
    let others = members.filter { $0 != me }
    let i = others.firstIndex(of: uid) ?? abs(uid.hashValue % 97)
    return palette[1 + i % (palette.count - 1)]
}

// MARK: - Setup

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var name = Store.name
    @State private var code = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Spacer(minLength: 50)
                ZStack {
                    RoundedRectangle(cornerRadius: 20).fill(Color.brand).frame(width: 72, height: 72)
                    Image(systemName: "location.fill").font(.system(size: 32, weight: .semibold)).foregroundStyle(.white)
                }
                Text("Ski Find").font(.largeTitle.bold())
                Text("See each other on a live map, iPhone and Samsung.")
                    .foregroundStyle(.secondary)

                TextField("Your name", text: $name)
                    .textContentType(.givenName)
                    .padding(14)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 10)

                Button {
                    model.create(name: name)
                } label: {
                    Text("Start sharing (get a pair code)").bold().frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)

                Text("Already have a code from the other phone?")
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)
                HStack {
                    TextField("Pair code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.title3.monospaced())
                        .padding(14)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 12))
                        .onChange(of: code) { _, v in
                            let clean = String(v.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6))
                            if clean != v { code = clean }
                        }
                    Button("Join") { model.join(name: name, code: code) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || code.count != 6 || model.busy)
                }

                if model.busy { ProgressView().frame(maxWidth: .infinity) }
                if let e = model.error { Text(e).foregroundStyle(.red) }
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

// MARK: - Main map

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var sharer: LocationSharer
    @State private var position: MapCameraPosition = .automatic
    @State private var didInitialFit = false
    @State private var showSettings = false

    private var alone: Bool {
        let m = model.members
        return m.count == 1 || (m.isEmpty && model.people.count <= 1)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $position) {
                ForEach(model.people.filter { $0.accuracy > 30 }) { p in
                    let c = personColor(p.id, me: model.myUid, members: model.members)
                    MapCircle(center: p.coordinate, radius: p.accuracy)
                        .foregroundStyle(c.opacity(0.15))
                        .stroke(c.opacity(0.5), lineWidth: 1)
                }
                ForEach(model.people) { p in
                    Annotation(p.id == model.myUid ? "You" : p.name, coordinate: p.coordinate, anchor: .bottom) {
                        AvatarPin(
                            letter: initial(p.id == model.myUid ? "Me" : p.name),
                            color: personColor(p.id, me: model.myUid, members: model.members),
                            dim: !p.sharing || (p.updated.map { Date().timeIntervalSince($0) > 3600 } ?? false)
                        )
                        .onTapGesture { focus(on: p) }
                    }
                }
            }
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .ignoresSafeArea()

            VStack(spacing: 10) {
                setupCard
                if alone, let code = model.circle?.joinCode, !code.isEmpty {
                    PairCard(code: code)
                }
                peopleCard
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .overlay(alignment: .top) { topBar }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(model)
                .presentationDetents([.medium, .large])
        }
        .onAppear { model.startPolling() }
        .onChange(of: model.people.isEmpty) { _, empty in
            if !empty && !didInitialFit {
                didInitialFit = true
                fitEveryone()
            }
        }
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "location.fill").foregroundStyle(Color.brand)
                Text("Ski Find").bold()
                if !model.sharing {
                    Text("· paused").foregroundStyle(.yellow).font(.footnote)
                } else if model.offline {
                    Text("· offline").foregroundStyle(.orange).font(.footnote)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            CircleButton(system: "arrow.up.left.and.arrow.down.right") {
                fitEveryone()
                model.refreshNow()
            }
            CircleButton(system: "gearshape.fill") { showSettings = true }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    @ViewBuilder private var setupCard: some View {
        switch sharer.authorization {
        case .notDetermined:
            SetupCard(title: "Allow location", text: "So your partner can see where you are.", action: "Allow") {
                sharer.askPermission()
            }
        case .denied, .restricted:
            SetupCard(title: "Location is off for Ski Find", text: "Settings › Ski Find › Location › Always.", action: "Settings") {
                sharer.openSettings()
            }
        case .authorizedWhenInUse:
            SetupCard(title: "Share when the app is closed", text: "Set location to \"Always\" so she can see you anytime.", action: "Fix") {
                sharer.askPermission()
            }
        default:
            if sharer.preciseOff {
                SetupCard(title: "Turn on Precise Location", text: "Settings › Ski Find › Location › Precise Location.", action: "Settings") {
                    sharer.openSettings()
                }
            }
        }
    }

    @ViewBuilder private var peopleCard: some View {
        // Partner(s) first, you last.
        let sorted = model.people.sorted { ($0.id == model.myUid ? 1 : 0) < ($1.id == model.myUid ? 1 : 0) }
        if !sorted.isEmpty {
            VStack(spacing: 0) {
                ForEach(sorted) { p in
                    PersonRow(
                        person: p,
                        isMe: p.id == model.myUid,
                        color: personColor(p.id, me: model.myUid, members: model.members),
                        address: model.addresses[p.id],
                        distance: distanceFromMe(p),
                        onShow: { focus(on: p) }
                    )
                    if p.id != sorted.last?.id { Divider().padding(.leading, 74) }
                }
            }
            .padding(.vertical, 4)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 22))
            .shadow(radius: 8, y: 2)
        } else if !alone {
            Text("Waiting for locations…")
                .frame(maxWidth: .infinity).padding(18)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    // MARK: Camera

    private func focus(on p: Person) {
        withAnimation(.easeInOut(duration: 0.6)) {
            position = .region(MKCoordinateRegion(center: p.coordinate, latitudinalMeters: 700, longitudinalMeters: 700))
        }
    }

    private func fitEveryone() {
        let pts = model.people.map(\.coordinate)
        guard let first = pts.first else { return }
        if pts.count == 1 {
            withAnimation { position = .region(MKCoordinateRegion(center: first, latitudinalMeters: 900, longitudinalMeters: 900)) }
            return
        }
        let lats = pts.map(\.latitude), lngs = pts.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lngs.min()! + lngs.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((lats.max()! - lats.min()!) * 1.8, 0.008),
                                    longitudeDelta: max((lngs.max()! - lngs.min()!) * 1.8, 0.008))
        withAnimation(.easeInOut(duration: 0.6)) { position = .region(MKCoordinateRegion(center: center, span: span)) }
    }

    private func distanceFromMe(_ p: Person) -> CLLocationDistance? {
        guard p.id != model.myUid else { return nil }
        let mine = model.people.first { $0.id == model.myUid }.map { CLLocation(latitude: $0.lat, longitude: $0.lng) }
            ?? sharer.lastLocation
        guard let mine else { return nil }
        return mine.distance(from: CLLocation(latitude: p.lat, longitude: p.lng))
    }
}

// MARK: - Small views

func initial(_ name: String) -> String {
    String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased().ifEmpty("?")
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

func shareText(_ code: String) -> String {
    "Join me on Ski Find: open the app, enter your name and the pair code \(code), then tap Join."
}

struct AvatarPin: View {
    let letter: String
    let color: Color
    let dim: Bool

    var body: some View {
        VStack(spacing: -3) {
            ZStack {
                SwiftUI.Circle().fill(.white).frame(width: 46, height: 46)
                SwiftUI.Circle().fill(dim ? Color.gray : color).frame(width: 40, height: 40)
                Text(letter).font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
            }
            Triangle().fill(.white).frame(width: 16, height: 10)
        }
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

struct CircleButton: View {
    let system: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: SwiftUI.Circle())
        }
        .foregroundStyle(.primary)
    }
}

struct SetupCard: View {
    let title: String
    let text: String
    let action: String
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.yellow).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action, action: onTap).buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(Color(red: 0.17, green: 0.21, blue: 0.31), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct PairCard: View {
    let code: String
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Waiting for the other phone").bold()
                Text("Enter this code in Ski Find on her phone:").font(.footnote).foregroundStyle(.secondary)
                Text(code).font(.system(size: 30, weight: .bold, design: .monospaced)).kerning(4)
            }
            Spacer()
            ShareLink(item: shareText(code)) { Text("Share") }.buttonStyle(.bordered)
        }
        .padding(16)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct PersonRow: View {
    let person: Person
    let isMe: Bool
    let color: Color
    let address: String?
    let distance: CLLocationDistance?
    let onShow: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                SwiftUI.Circle().fill(person.sharing ? color : .gray).frame(width: 46, height: 46)
                Text(initial(isMe ? "Me" : person.name)).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(isMe ? "\(person.name) (you)" : person.name).font(.headline).lineLimit(1)
                Text(address ?? String(format: "%.5f, %.5f", person.lat, person.lng))
                    .font(.subheadline).lineLimit(1)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !isMe {
                Button {
                    openDirections()
                } label: {
                    Image(systemName: "car.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(Color.brand.opacity(0.18), in: SwiftUI.Circle())
                }
                .accessibilityLabel("Directions")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onShow)
    }

    private var details: String {
        var bits: [String] = []
        if !person.sharing {
            bits.append("Paused sharing")
        } else if let t = person.updated {
            let mins = Int(Date().timeIntervalSince(t) / 60)
            bits.append(mins < 1 ? "Now" : mins < 60 ? "\(mins) min ago" : mins < 1440 ? "\(mins / 60) hr ago" : "\(mins / 1440) days ago")
        } else {
            bits.append("Updating…")
        }
        if let d = distance {
            let miles = d / 1609.344
            bits.append(miles < 0.1 ? "\(Int(d * 3.28084)) ft away" : miles < 10 ? String(format: "%.1f mi away", miles) : String(format: "%.0f mi away", miles))
        }
        if person.speed > 4.5 { bits.append(String(format: "%.0f mph", person.speed * 2.23694)) }
        if let b = person.battery { bits.append(person.charging ? "\(b)% ⚡" : "\(b)% battery") }
        return bits.joined(separator: " · ")
    }

    private func openDirections() {
        let name = person.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "maps://?daddr=\(person.lat),\(person.lng)&dirflg=d&q=\(name)") {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = Store.name
    @State private var confirmLeave = false
    @State private var removeUid: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { model.sharing }, set: { model.setSharing($0) })) {
                        VStack(alignment: .leading) {
                            Text("Share my location")
                            Text(model.sharing ? "Your partner can see where you are." : "Paused. Your partner sees your last spot as paused.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        TextField("Your name", text: $name)
                        Button("Save") { model.rename(name) }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name.trimmingCharacters(in: .whitespaces) == model.myName)
                    }
                }

                Section("People") {
                    ForEach(model.members, id: \.self) { uid in
                        let n = model.circle?.names[uid] ?? "Someone"
                        HStack {
                            ZStack {
                                SwiftUI.Circle().fill(personColor(uid, me: model.myUid, members: model.members)).frame(width: 30, height: 30)
                                Text(initial(n)).font(.caption.bold()).foregroundStyle(.white)
                            }
                            Text(uid == model.myUid ? "\(n) (you)" : n)
                            Spacer()
                            if uid != model.myUid {
                                Button("Remove", role: .destructive) { removeUid = uid }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                if let code = model.circle?.joinCode, !code.isEmpty {
                    Section {
                        HStack {
                            Text(code).font(.title2.monospaced().bold()).kerning(3)
                            Spacer()
                            ShareLink(item: shareText(code)) { Label("Share", systemImage: "square.and.arrow.up") }
                        }
                    } header: {
                        Text("Pair code")
                    } footer: {
                        Text("To add a phone: open Ski Find on it, enter a name and this code, then tap Join.")
                    }
                }

                Section {
                    Button("Location settings") { LocationSharer.shared.openSettings() }
                    Button("Stop sharing and leave", role: .destructive) { confirmLeave = true }
                } footer: {
                    Text("For sharing while the app is closed, set Location to Always and turn on Precise Location.")
                }

                if let e = model.error {
                    Section { Text(e).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Leave Ski Find?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave", role: .destructive) { dismiss(); model.leave() }
            } message: {
                Text("Your location is removed and sharing stops on this phone. You can pair again later with a code.")
            }
            .confirmationDialog(
                "Remove \(removeUid.flatMap { model.circle?.names[$0] } ?? "this person")?",
                isPresented: Binding(get: { removeUid != nil }, set: { if !$0 { removeUid = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let u = removeUid { model.remove(u) }
                    removeUid = nil
                }
            } message: {
                Text("They'll stop seeing your location and you'll stop seeing theirs. They can rejoin with the pair code.")
            }
        }
    }
}
