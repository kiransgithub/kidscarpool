import SwiftUI

struct DashboardView: View {
    @Environment(CarpoolStore.self) private var store

    private func nextTrip(of kind: TripKind, now: Date) -> CarpoolTrip? {
        store.trips
            .filter { trip in
                guard trip.kind == kind,
                      trip.status != .cancelled,
                      trip.status != .completed else { return false }

                // Keep an active trip visible even if its scheduled time has passed.
                if trip.status == .inProgress { return true }
                guard let start = store.scheduledStart(for: trip) else {
                    return trip.date >= Calendar.current.startOfDay(for: now)
                }
                return start >= now
            }
            .sorted { lhs, rhs in
                let left = store.scheduledStart(for: lhs) ?? lhs.date
                let right = store.scheduledStart(for: rhs) ?? rhs.date
                return left < right
            }
            .first
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let nextDrop = nextTrip(of: .morningDrop, now: context.date)
            let nextPickup = nextTrip(of: .afternoonPickup, now: context.date)

            ScrollView {
                VStack(spacing: 18) {
                    header
                    activeGroupContext

                    NextTripCard(
                        title: "Next morning drop",
                        trip: nextDrop,
                        now: context.date,
                        accent: KCPTheme.orange
                    )

                    NextTripCard(
                        title: "Next afternoon pickup",
                        trip: nextPickup,
                        now: context.date,
                        accent: KCPTheme.violet
                    )

                    Text("The full calendar, volunteer requests, points and settings are available in the tabs below.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground))
        }
        .navigationTitle("KCP")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: UUID.self) { id in TripDetailView(tripID: id) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(destination: AlertsView()) {
                    Image(systemName: hasAttentionAlert ? "bell.badge.fill" : "bell.fill")
                }
                .accessibilityLabel("Alerts")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image("KCPLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Who is driving next?")
                    .font(.title2.bold())
                Text("Good \(greeting), \(store.currentParentName).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(KCPTheme.heroGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .foregroundStyle(.white)
        .shadow(color: KCPTheme.navy.opacity(0.18), radius: 14, y: 7)
    }

    @ViewBuilder
    private var activeGroupContext: some View {
        if let group = store.activeGroup {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(KCPTheme.blue.opacity(0.12))
                    Image(systemName: "person.3.sequence.fill")
                        .foregroundStyle(KCPTheme.blue)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Text("\(group.schoolName) • \(store.currentRole.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()

                if store.availableGroups.count > 1 {
                    Menu {
                        ForEach(store.availableGroups.sorted { $0.group.name < $1.group.name }) { summary in
                            Button {
                                Task { await store.switchGroup(to: summary.group.code) }
                            } label: {
                                Label(
                                    summary.group.name,
                                    systemImage: summary.group.code == group.code ? "checkmark.circle.fill" : "circle"
                                )
                            }
                            .disabled(summary.group.code == group.code || store.isSyncing)
                        }
                    } label: {
                        Label("Switch", systemImage: "arrow.left.arrow.right")
                            .font(.caption.bold())
                    }
                } else {
                    Text(group.code)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .kcpCard()
        } else {
            NavigationLink(destination: GroupsView()) {
                Label("Create or join a carpool group", systemImage: "person.3.sequence.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .kcpCard()
        }
    }

    private var hasAttentionAlert: Bool {
        !store.coverRequests.filter { $0.acceptedBy == nil }.isEmpty ||
        store.trips.contains { $0.status == .coverRequested } ||
        (store.isCurrentUserAdmin && store.pendingConstraintCount > 0)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        if hour < 12 { return "morning" }
        if hour < 17 { return "afternoon" }
        return "evening"
    }
}

private struct NextTripCard: View {
    @Environment(CarpoolStore.self) private var store
    let title: String
    let trip: CarpoolTrip?
    let now: Date
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label(title, systemImage: trip?.kind.symbol ?? "calendar.badge.clock")
                    .font(.headline)
                    .foregroundStyle(accent)
                Spacer()
                if let trip { HomeStatusBadge(trip: trip) }
            }

            if let trip {
                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        Circle().fill(KCPTheme.parentColor(trip.driver).opacity(0.14))
                        Text(initials(for: trip.driver))
                            .font(.title3.bold())
                            .foregroundStyle(KCPTheme.parentColor(trip.driver))
                    }
                    .frame(width: 54, height: 54)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(trip.driver)
                            .font(.title3.bold())
                        Text("Assigned driver")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Divider()

                HStack(spacing: 0) {
                    infoColumn(
                        label: "DATE & TIME",
                        value: "\(trip.date.formatted(date: .abbreviated, time: .omitted))\n\(trip.timeLabel)",
                        icon: "calendar"
                    )
                    Divider().frame(height: 46).padding(.horizontal, 12)
                    infoColumn(
                        label: "COUNTDOWN",
                        value: countdown(for: trip),
                        icon: "timer"
                    )
                }

                NavigationLink(value: trip.id) {
                    Text("View trip")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .foregroundStyle(.white)
                        .background(accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                ContentUnavailableView(
                    "No upcoming \(title.lowercased())",
                    systemImage: "calendar.badge.checkmark",
                    description: Text("The schedule has no future trip of this type.")
                )
                .frame(maxWidth: .infinity)
            }
        }
        .kcpCard()
    }

    private func infoColumn(label: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: icon)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func initials(for name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    private func countdown(for trip: CarpoolTrip) -> String {
        if trip.status == .inProgress { return "In progress" }
        guard let start = store.scheduledStart(for: trip) else { return "Time pending" }
        let interval = start.timeIntervalSince(now)
        if interval <= 0 { return "Due now" }

        let totalMinutes = Int(interval / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1)) min"
    }
}

private struct HomeStatusBadge: View {
    let trip: CarpoolTrip

    private var label: String {
        if trip.driver == "Unassigned" { return "Coverage needed" }
        if trip.status == .accepted || trip.isVolunteerTrip { return "Volunteer assigned" }
        if trip.status == .scheduled { return "Confirmed" }
        return trip.status.rawValue
    }

    private var color: Color {
        if trip.driver == "Unassigned" { return KCPTheme.red }
        switch trip.status {
        case .scheduled: return KCPTheme.blue
        case .coverRequested: return KCPTheme.red
        case .accepted: return KCPTheme.green
        case .inProgress: return KCPTheme.orange
        case .completed: return KCPTheme.green
        case .cancelled: return .secondary
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct AlertsView: View {
    @Environment(CarpoolStore.self) private var store

    private var attentionTrips: [CarpoolTrip] {
        store.trips
            .filter { [.coverRequested, .accepted, .inProgress].contains($0.status) }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        List {
            if store.isCurrentUserAdmin {
                Section("Admin approvals") {
                    NavigationLink(destination: ConstraintRequestQueueView()) {
                        HStack {
                            Label("Constraint update requests", systemImage: "checklist.checked")
                            Spacer()
                            Text("\(store.pendingConstraintCount)")
                                .font(.caption.bold())
                                .foregroundStyle(store.pendingConstraintCount > 0 ? KCPTheme.red : .secondary)
                        }
                    }
                    NavigationLink(destination: GroupManagementView()) {
                        Label("Group members, invitations & audit", systemImage: "person.3.sequence.fill")
                    }
                }
            }

            Section("Trip alerts") {
                if attentionTrips.isEmpty {
                    ContentUnavailableView("No active alerts", systemImage: "bell.badge.checkmark")
                } else {
                    ForEach(attentionTrips) { trip in
                        NavigationLink(destination: TripDetailView(tripID: trip.id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(trip.kind.rawValue) · \(trip.driver)")
                                    .font(.headline)
                                Text("\(trip.date.formatted(date: .abbreviated, time: .omitted)) · \(trip.timeLabel)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(trip.status == .accepted ? "Volunteer assigned" : trip.status.rawValue)
                                    .font(.caption.bold())
                                    .foregroundStyle(trip.status == .coverRequested ? KCPTheme.red : KCPTheme.green)
                            }
                        }
                    }
                }
            }

            Section("Reminder delivery") {
                Label(
                    store.remindersEnabled ? "Trip reminders are enabled" : "Trip reminders are not enabled",
                    systemImage: store.remindersEnabled ? "bell.fill" : "bell.slash"
                )
                Button("Request notification permission") {
                    Task { await store.requestNotificationPermission() }
                }
            }
        }
        .navigationTitle("Alerts")
    }
}

// Shared by Schedule and Volunteer screens.
struct TripRow: View {
    let trip: CarpoolTrip

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: trip.kind.symbol)
                .font(.title3)
                .foregroundStyle(trip.kind == .morningDrop ? KCPTheme.orange : KCPTheme.violet)
                .frame(width: 44, height: 44)
                .background((trip.kind == .morningDrop ? KCPTheme.orange : KCPTheme.violet).opacity(0.12), in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 4) {
                Text(trip.kind.rawValue).font(.headline)
                Text("\(trip.date.formatted(date: .abbreviated, time: .omitted)) • \(trip.timeLabel)")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Circle().fill(KCPTheme.parentColor(trip.driver)).frame(width: 7, height: 7)
                    Text("Driver: \(trip.driver)").font(.caption.weight(.medium))
                }
            }
            Spacer(minLength: 4)
            StatusBadge(status: trip.status)
        }
        .kcpCard()
    }
}

struct StatusBadge: View {
    let status: TripStatus

    private var color: Color {
        switch status {
        case .scheduled: return KCPTheme.blue
        case .coverRequested: return KCPTheme.red
        case .accepted: return KCPTheme.green
        case .inProgress: return KCPTheme.orange
        case .completed: return KCPTheme.green
        case .cancelled: return .secondary
        }
    }

    var body: some View {
        Text(status == .accepted ? "Volunteer assigned" : status.rawValue)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }
}
