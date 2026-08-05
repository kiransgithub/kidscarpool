import SwiftUI
import MapKit

struct TripDetailView: View {
    @Environment(CarpoolStore.self) private var store
    let tripID: UUID
    @State private var coverNote = ""
    @State private var showCoverSheet = false

    private var trip: CarpoolTrip? { store.trips.first { $0.id == tripID } }

    /// All children in the active group, including a child temporarily removed
    /// from this trip because of an absence or an ad-hoc activity.
    private var availableChildren: [String] {
        let activeMemberChildren = store.groupMembers
            .filter { $0.status == .active }
            .map(\.childName)
        let profileChildren = store.parents.map(\.childName)
        let source = activeMemberChildren.isEmpty ? profileChildren : activeMemberChildren
        let names = source
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let uniqueNames = Array(Set(names)).sorted()
        return uniqueNames.isEmpty ? ScheduleGenerator.defaultChildren : uniqueNames
    }

    var body: some View {
        Group {
            if let trip {
                ScrollView {
                    VStack(spacing: 16) {
                        header(trip)

                        if !trip.notes.isEmpty {
                            Label(trip.notes, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(KCPTheme.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .kcpCard()
                        }

                        timingGuardCard(trip)
                        childrenCard(trip)
                        actions(trip)
                    }
                    .padding(16)
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Trip Details")
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showCoverSheet) {
                    NavigationStack {
                        Form {
                            TextField("Reason or instructions", text: $coverNote, axis: .vertical)
                            Button("Post cover request") {
                                store.requestCover(for: tripID, note: coverNote)
                                showCoverSheet = false
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .navigationTitle("Request Cover")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showCoverSheet = false } } }
                    }
                }
            } else {
                ContentUnavailableView("Trip not found", systemImage: "exclamationmark.triangle")
            }
        }
    }

    private func header(_ trip: CarpoolTrip) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: trip.kind.symbol).font(.largeTitle)
                Spacer()
                StatusBadge(status: trip.status)
            }
            Text(trip.kind.rawValue).font(.title.bold())
            Text(trip.date.formatted(date: .complete, time: .omitted)).foregroundStyle(.white.opacity(0.85))
            HStack {
                Label(trip.timeLabel, systemImage: "clock.fill")
                Spacer()
                Label(trip.driver, systemImage: "person.fill")
            }
            .font(.subheadline.bold())
            if trip.isVolunteerTrip {
                Label("Volunteer trip • 20 points", systemImage: "star.circle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.yellow)
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(KCPTheme.heroGradient, in: RoundedRectangle(cornerRadius: 24))
    }

    private func timingGuardCard(_ trip: CarpoolTrip) -> some View {
        let start = store.startEligibility(for: trip)
        let completion = store.completionEligibility(for: trip)
        return VStack(alignment: .leading, spacing: 10) {
            Label("Protected trip controls", systemImage: "lock.shield.fill")
                .font(.headline)
                .foregroundStyle(KCPTheme.blue)
            Text("Start is allowed from 30 minutes before until 90 minutes after the scheduled start. Completion requires the trip to be in progress, the scheduled time to have arrived, and at least 3 minutes of elapsed time.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if trip.status == .scheduled || trip.status == .accepted {
                Label(start.allowed ? "Start window is open" : start.message,
                      systemImage: start.allowed ? "checkmark.circle.fill" : "clock.badge.exclamationmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(start.allowed ? KCPTheme.green : KCPTheme.orange)
            } else if trip.status == .inProgress {
                Label(completion.allowed ? "Completion is available" : completion.message,
                      systemImage: completion.allowed ? "checkmark.circle.fill" : "timer")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(completion.allowed ? KCPTheme.green : KCPTheme.orange)
            }
            if store.pilotTimeOverride {
                Label("Pilot time override is enabled in Settings", systemImage: "wrench.and.screwdriver.fill")
                    .font(.caption.bold()).foregroundStyle(KCPTheme.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kcpCard()
    }

    private func childrenCard(_ trip: CarpoolTrip) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Children riding").font(.title3.bold())
            ForEach(availableChildren, id: \.self) { child in
                Button { store.toggleChild(child, in: tripID) } label: {
                    HStack {
                        Image(systemName: "person.crop.circle.fill").foregroundStyle(KCPTheme.blue)
                        Text(child).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: trip.childNames.contains(child) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(trip.childNames.contains(child) ? KCPTheme.green : .secondary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .kcpCard()
    }

    private func actions(_ trip: CarpoolTrip) -> some View {
        VStack(spacing: 12) {
            if trip.status == .scheduled || trip.status == .accepted {
                let eligible = store.startEligibility(for: trip).allowed
                actionButton("Start trip", icon: "car.fill", color: KCPTheme.blue, enabled: eligible) {
                    store.startTrip(tripID)
                }
            }
            if trip.status == .inProgress {
                let eligible = store.completionEligibility(for: trip).allowed
                actionButton("Complete trip", icon: "checkmark.circle.fill", color: KCPTheme.green, enabled: eligible) {
                    store.completeTrip(tripID)
                }
            }
            if trip.status != .completed && trip.status != .cancelled {
                actionButton("Request a cover", icon: "person.crop.circle.badge.questionmark", color: KCPTheme.orange) {
                    showCoverSheet = true
                }
            }
            actionButton("Open school in Apple Maps", icon: "map.fill", color: KCPTheme.violet) {
                let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 33.5947, longitude: -112.0120)))
                item.name = "BASIS Phoenix Primary"
                item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
            }
        }
    }

    private func actionButton(_ title: String, icon: String, color: Color, enabled: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 13)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}
