import SwiftUI

struct SettingsView: View {
    @Environment(CarpoolStore.self) private var store

    var body: some View {
        List {
            Section("Current parent") {
                LabeledContent("Parent", value: store.currentParentName)
                if let member = store.currentMember {
                    LabeledContent("Child", value: "\(member.childName), Grade \(member.grade)")
                    LabeledContent("Group role", value: member.role.displayName)
                }
                if !store.phoneNumber.isEmpty {
                    LabeledContent("Phone", value: store.phoneNumber)
                }
                Text("A pilot phone is bound to the signed-in parent. Sign out to test a different invitation instead of switching identities in place.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Group & school") {
                NavigationLink { GroupsView() } label: {
                    HStack {
                        Label("My carpool groups", systemImage: "rectangle.3.group.fill")
                        Spacer()
                        Text("\(store.availableGroups.count)")
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink { GroupManagementView() } label: {
                    HStack {
                        Label("Carpool group & admins", systemImage: "person.3.sequence.fill")
                        Spacer()
                        if store.pendingConstraintCount > 0 && store.isCurrentUserAdmin {
                            Text("\(store.pendingConstraintCount)")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(KCPTheme.red, in: Capsule())
                        }
                    }
                }
                NavigationLink { MyAvailabilityView() } label: {
                    Label("My drop & pickup availability", systemImage: "slider.horizontal.3")
                }
                NavigationLink { SchoolCalendarAnalyticsView() } label: {
                    Label("School calendar & analytics", systemImage: "chart.bar.xaxis")
                }
                if store.isCurrentUserAdmin {
                    NavigationLink { ConstraintRequestQueueView() } label: {
                        Label("Constraint approval queue", systemImage: "checklist.checked")
                    }
                }
                NavigationLink { PilotServerView() } label: {
                    Label("Central family database", systemImage: "server.rack")
                }
            }

            Section("Alerts & reminders") {
                HStack {
                    Label("Notification access", systemImage: "bell.badge.fill")
                    Spacer()
                    Text(store.notificationStatus).foregroundStyle(.secondary)
                }
                if store.remindersEnabled {
                    Button("Refresh trip reminders") { Task { await store.scheduleLocalReminders() } }
                    Button("Pause reminders", role: .destructive) { Task { await store.disableNotifications() } }
                } else {
                    Button("Enable trip reminders") { Task { await store.requestNotificationPermission() } }
                }
                Text("Local reminders fire 30 minutes before assigned trips. Shared invitation, constraint and cover alerts require APNs credentials for remote delivery.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Pilot testing") {
                Toggle(
                    "Pilot time override",
                    isOn: Binding(
                        get: { store.pilotTimeOverride },
                        set: { store.setPilotTimeOverride($0) }
                    )
                )
                Text("Allows trip actions outside the real time window for testing. Keep this disabled for normal use.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Pilot data") {
                Button("Reset local pilot", role: .destructive) { Task { await store.resetPilot() } }
                Button("Sign out") { store.signOut() }
            }
        }
        .navigationTitle("Settings")
    }
}

private struct PilotServerView: View {
    @Environment(CarpoolStore.self) private var store

    var body: some View {
        Form {
            Section("Laptop server") {
                TextField(
                    "Server URL",
                    text: Binding(get: { store.serverURL }, set: { store.serverURL = $0 })
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                LabeledContent("Active group", value: store.activeGroup?.name ?? "None")
                LabeledContent("Group code", value: store.activeGroup?.code ?? store.groupCode)
                NavigationLink(destination: GroupsView()) {
                    Label("View or switch groups", systemImage: "arrow.left.arrow.right.circle.fill")
                }

                LabeledContent("Status", value: store.serverStatus)
            }

            Section {
                Button(store.isSyncing ? "Synchronizing…" : "Connect and synchronize") {
                    Task { await store.connectAndSync() }
                }
                .disabled(store.isSyncing)

                Button("Download latest family data") {
                    Task { await store.pullFromServer() }
                }
                .disabled(store.isSyncing)

                Button("Refresh group workspace") {
                    Task { await store.refreshGroupWorkspace() }
                }
                .disabled(store.isSyncing)

                Button("Refresh my group list") {
                    Task { await store.refreshGroups() }
                }
                .disabled(store.isSyncing)
            } footer: {
                Text("For phones on the same Wi‑Fi, use your Mac's LAN address and port 8090, for example http://192.168.1.25:8090. Keep the Mac awake and allow incoming local-network traffic.")
            }

            Section("Persistent records") {
                Label("Group members and roles", systemImage: "person.3.fill")
                Label("Invitations and acceptance", systemImage: "envelope.open.fill")
                Label("Constraint requests and reviews", systemImage: "checklist.checked")
                Label("Calendar and events", systemImage: "calendar.badge.checkmark")
                Label("Schedule versions", systemImage: "square.stack.3d.up.fill")
                Label("Immutable audit events", systemImage: "doc.text.magnifyingglass")
            }
        }
        .navigationTitle("Central Database")
    }
}
