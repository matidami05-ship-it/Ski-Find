import SwiftUI
import MapKit
import CoreLocation

// MARK: - Formatting

func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

func duration(_ seconds: TimeInterval) -> String {
    let m = max(1, Int(seconds / 60))
    if m < 60 { return "\(m) min" }
    return m % 60 == 0 ? "\(m / 60) hr" : "\(m / 60) hr \(m % 60) min"
}

func dayLabel(_ offset: Int) -> String {
    switch offset {
    case 0: return "Today"
    case 1: return "Yesterday"
    default:
        let d = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
        return d.formatted(.dateTime.weekday(.abbreviated).month(.defaultDigits).day())
    }
}

private func miles(_ m: Double) -> String {
    let mi = m / 1609.344
    return mi < 0.1 ? "\(Int(m * 3.28084)) ft" : String(format: "%.1f mi", mi)
}

func placeSymbol(_ name: String) -> String {
    let n = name.lowercased()
    if n.contains("home") { return "house.fill" }
    if n.contains("work") || n.contains("office") { return "briefcase.fill" }
    if n.contains("school") { return "graduationcap.fill" }
    if n.contains("gym") { return "dumbbell.fill" }
    return "mappin.circle.fill"
}

// MARK: - History sheet

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition = .automatic

    private var uid: String { model.historyUid ?? "" }
    private var person: Person? { model.people.first { $0.id == uid } }
    private var name: String { person?.name ?? model.circle?.names[uid] ?? "Someone" }
    private var isMe: Bool { uid == model.myUid }
    private var color: Color { personColor(uid, me: model.myUid, members: model.members) }
    private struct StayPin: Identifiable {
        let id: String
        let coord: CLLocationCoordinate2D
    }

    private var stays: [StayPin] {
        model.historySegments.compactMap { seg -> StayPin? in
            if case let .stay(lat, lng, start, _, _) = seg {
                return StayPin(id: "\(start.timeIntervalSince1970)", coord: CLLocationCoordinate2D(latitude: lat, longitude: lng))
            }
            return nil
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    dayPicker
                    map
                    timeline
                }
                .padding(16)
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onChange(of: model.historyPoints) { _, pts in fit(pts) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Avatar(letter: initial(name), image: model.photos[uid], color: color, size: 56, dim: person?.sharing == false)
            VStack(alignment: .leading, spacing: 2) {
                Text(isMe ? "\(name) (you)" : name).font(.title3.bold())
                Text(model.addresses[uid] ?? "Location history").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !isMe, let person {
                Button { directions(to: person) } label: {
                    Label("Drive", systemImage: "car.fill").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).frame(height: 38)
                        .background(Color.brand.opacity(0.2), in: Capsule())
                }
            }
        }
    }

    private var dayPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<7, id: \.self) { i in
                    Button(dayLabel(i)) { model.openHistory(uid, day: i) }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(model.historyDay == i ? Color.brand : Color.card, in: Capsule())
                        .foregroundStyle(model.historyDay == i ? .white : .primary)
                }
            }
        }
    }

    private var map: some View {
        ZStack {
            Map(position: $camera) {
                if model.historyPoints.count > 1 {
                    MapPolyline(coordinates: model.historyPoints.map(\.coordinate))
                        .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                ForEach(stays) { s in
                    Annotation("", coordinate: s.coord) {
                        SwiftUI.Circle().fill(color).frame(width: 14, height: 14)
                            .overlay(SwiftUI.Circle().stroke(.white, lineWidth: 2.5))
                    }
                }
                if let last = model.historyPoints.last {
                    Annotation("", coordinate: last.coordinate) {
                        SwiftUI.Circle().fill(.white).frame(width: 12, height: 12)
                            .overlay(SwiftUI.Circle().stroke(color, lineWidth: 3))
                    }
                }
            }
            if model.historyLoading { ProgressView() }
        }
        .frame(height: 250)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private var timeline: some View {
        if let e = model.historyError {
            Text(e).foregroundStyle(.red)
        } else if !model.historyLoading && model.historySegments.isEmpty {
            Text(model.historyPoints.isEmpty ? "No location history for \(dayLabel(model.historyDay).lowercased())."
                                             : "Stayed close to one spot.")
                .foregroundStyle(.secondary)
        }
        VStack(spacing: 0) {
            ForEach(Array(model.historySegments.reversed())) { seg in
                SegmentRow(segment: seg)
                Divider().padding(.leading, 54)
            }
        }
    }

    private func fit(_ pts: [HistPoint]) {
        guard !pts.isEmpty else { return }
        let lats = pts.map(\.lat), lngs = pts.map(\.lng)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lngs.min()! + lngs.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((lats.max()! - lats.min()!) * 1.4, 0.006),
                                    longitudeDelta: max((lngs.max()! - lngs.min()!) * 1.4, 0.006))
        withAnimation { camera = .region(MKCoordinateRegion(center: center, span: span)) }
    }
}

private struct SegmentRow: View {
    @EnvironmentObject var model: AppModel
    let segment: Segment
    @State private var label: String?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                SwiftUI.Circle().fill(Color.card).frame(width: 40, height: 40)
                Image(systemName: icon).foregroundStyle(isStay ? Color.brand : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .task(id: segment.id) {
            if case let .stay(lat, lng, _, _, _) = segment {
                label = await model.label(lat: lat, lng: lng)
            }
        }
    }

    private var isStay: Bool { if case .stay = segment { return true } else { return false } }

    private var icon: String {
        switch segment {
        case .stay: return label.map(placeSymbol) ?? "mappin.circle.fill"
        case .move: return "car.fill"
        }
    }

    private var title: String {
        switch segment {
        case .stay: return label ?? "Stop"
        case let .move(_, _, _, ongoing): return ongoing ? "On the move" : "Drive / trip"
        }
    }

    private var subtitle: String {
        switch segment {
        case let .stay(_, _, start, end, ongoing):
            return ongoing ? "Since \(clock(start)) · \(duration(end.timeIntervalSince(start)))"
                           : "\(clock(start)) – \(clock(end)) · \(duration(end.timeIntervalSince(start)))"
        case let .move(start, end, meters, _):
            return "\(clock(start)) – \(clock(end)) · \(duration(end.timeIntervalSince(start))) · \(miles(meters))"
        }
    }
}

// MARK: - Places (Settings)

struct PlacesSection: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Place?
    @State private var adding = false
    @State private var confirmDelete: Place?

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { model.alerts }, set: { model.setAlerts($0) })) {
                VStack(alignment: .leading) {
                    Text("Arrive & leave alerts")
                    Text("Get notified when someone arrives at or leaves a place below.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if model.places.isEmpty {
                Text("No places yet. Add Home, Work or anywhere else.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(model.places) { p in
                Button { editing = p } label: {
                    HStack {
                        Image(systemName: placeSymbol(p.name)).foregroundStyle(Color.brand).frame(width: 28)
                        VStack(alignment: .leading) {
                            Text(p.name).foregroundStyle(.primary)
                            Text("\(Int(p.radius * 3.28084)) ft around").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { confirmDelete = p }
                }
            }
            Button { adding = true } label: { Label("Add a place", systemImage: "mappin.and.ellipse") }
        } header: {
            Text("Places")
        } footer: {
            Text("Swipe left on a place to delete it. Alerts arrive within about a minute on Samsung; on iPhone they show when iOS next wakes Ski Find, usually within minutes.")
        }
        .sheet(isPresented: $adding) { editor(nil) }
        .sheet(item: $editing) { p in editor(p) }
        .confirmationDialog("Delete \(confirmDelete?.name ?? "place")?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let p = confirmDelete { model.deletePlace(p.id) }
                confirmDelete = nil
            }
        } message: {
            Text("You'll stop getting alerts for this place on both phones.")
        }
    }

    private func editor(_ p: Place?) -> some View {
        let me = model.people.first { $0.id == model.myUid } ?? model.people.first
        let start = p?.coordinate ?? me?.coordinate ?? LocationSharer.shared.lastLocation?.coordinate
            ?? CLLocationCoordinate2D(latitude: 42.59, longitude: -88.43)
        return PlaceEditor(place: p, start: start) { name, coord, radius in
            model.savePlace(name: name, lat: coord.latitude, lng: coord.longitude, radius: radius, id: p?.id)
        }
    }
}

private struct PlaceEditor: View {
    let place: Place?
    let start: CLLocationCoordinate2D
    let onSave: (String, CLLocationCoordinate2D, Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var radius: Double = 150
    @State private var center: CLLocationCoordinate2D?
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Map(position: $camera) {
                        if let c = center {
                            MapCircle(center: c, radius: radius)
                                .foregroundStyle(Color.brand.opacity(0.18))
                                .stroke(Color.brand, lineWidth: 2)
                        }
                    }
                    .onMapCameraChange(frequency: .continuous) { ctx in center = ctx.region.center }
                    // The place is the middle of the map.
                    Image(systemName: "mappin")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Color.brand)
                        .offset(y: -15)
                        .allowsHitTesting(false)
                    VStack {
                        Text("Move the map to put the place in the middle")
                            .font(.footnote).padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 10)
                        Spacer()
                    }
                }
                Form {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(["Home", "Work", "School", "Gym"], id: \.self) { q in
                                    Button { name = q } label: { Label(q, systemImage: placeSymbol(q)) }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                        TextField("Name", text: $name)
                    }
                    Section("Alert area: \(Int(radius * 3.28084)) ft around") {
                        Slider(value: $radius, in: 75...500)
                    }
                }
                .frame(height: 260)
            }
            .navigationTitle(place == nil ? "Add a place" : "Edit place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name, center ?? start, radius)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear {
            name = place?.name ?? ""
            radius = place?.radius ?? 150
            center = start
            camera = .region(MKCoordinateRegion(center: start, latitudinalMeters: 600, longitudinalMeters: 600))
        }
    }
}
