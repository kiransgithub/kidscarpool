import Foundation
import CryptoKit
import Observation
import UserNotifications

@MainActor
@Observable
final class CarpoolStore {
    // MARK: Session and trip state

    var isSignedIn = false
    var phoneNumber = ""
    var currentParentName = "Kiran"
    var parents: [ParentProfile] = []
    var trips: [CarpoolTrip] = []
    var coverRequests: [CoverRequest] = []
    var calendarRegistration: CalendarRegistration?
    var alertMessage: String?
    var remindersEnabled = false
    var notificationStatus = "Not requested"

    // MARK: Collaborative group state

    var activeGroup: CarpoolGroup?
    var groupMembers: [GroupMember] = []
    var groupInvitations: [GroupInvitation] = []
    var approvedConstraints: [ApprovedConstraint] = []
    var constraintRequests: [ConstraintChangeRequest] = []
    var calendarEvents: [SchoolCalendarEvent] = []
    var calendarAnalyticsFromServer: CalendarAnalytics?
    var scheduleVersions: [ScheduleRevision] = []
    var auditEvents: [AuditEvent] = []
    var availableGroups: [UserGroupSummary] = []

    // MARK: Pilot server settings

    // Production must replace this trusted-LAN identity with Supabase/Auth tokens.
    var serverURL = UserDefaults.standard.string(forKey: "kcp.serverURL") ?? "http://127.0.0.1:8090"
    var groupCode = UserDefaults.standard.string(forKey: "kcp.groupCode") ?? "KCP-PHOENIX-2026"
    var serverStatus = "Not connected"
    var isSyncing = false
    var pilotTimeOverride = UserDefaults.standard.bool(forKey: "kcp.pilotTimeOverride")

    private let persistence = Persistence()
    private let phoenixTimeZone = TimeZone(identifier: "America/Phoenix")!
    private let expectedBasisCalendarSHA256 = "3a5ffb0feda17ce6a0a7655b3d6d2a9c21cbb3c473df1adcc1c8dc81ba170464"

    // MARK: Derived group state

    var currentMember: GroupMember? {
        groupMembers.first { $0.parentName == currentParentName && $0.status == .active }
    }

    var currentRole: GroupRole {
        currentMember?.role ?? (currentParentName == activeGroup?.createdBy ? .owner : .parent)
    }

    var isCurrentUserAdmin: Bool { currentRole.canAdminister }

    var activeGroupSummary: UserGroupSummary? {
        guard let code = activeGroup?.code else { return nil }
        return availableGroups.first { $0.group.code == code }
    }

    var pendingConstraintCount: Int {
        constraintRequests.filter { $0.status == .pending }.count
    }

    var displayCalendarEvents: [SchoolCalendarEvent] {
        guard calendarRegistration != nil else { return [] }
        return calendarEvents.isEmpty ? SchoolCalendarData.events : calendarEvents
    }

    var calendarAnalytics: CalendarAnalytics {
        guard calendarRegistration != nil else {
            return CalendarAnalytics(
                instructionalDays: 0,
                holidayPeriods: 0,
                noSchoolWeekdays: 0,
                longWeekends: 0,
                upcomingLongWeekends: 0,
                earlyPickups: 0,
                noLateBirdDays: 0,
                projectWeekDays: 0,
                longestBreakDays: 0,
                longestBreakTitle: nil,
                upcomingEventCount: 0,
                nextEventTitle: nil,
                nextEventDate: nil
            )
        }
        return calendarAnalyticsFromServer ?? SchoolCalendarData.analytics(events: displayCalendarEvents)
    }

    var leaderboard: [LeaderboardRow] {
        parents.map { parent in
            let completed = trips.filter { $0.driver == parent.name && $0.status == .completed }
            let volunteer = completed.filter(\.isVolunteerTrip).count
            let regular = completed.count - volunteer
            return LeaderboardRow(
                parentName: parent.name,
                scheduledCompleted: regular,
                volunteerCompleted: volunteer,
                points: regular * 10 + volunteer * 20
            )
        }
        .sorted { lhs, rhs in
            lhs.points == rhs.points ? lhs.parentName < rhs.parentName : lhs.points > rhs.points
        }
    }

    // MARK: Bootstrap and sign-in

    func bootstrap() async {
        do {
            if let snapshot = try await persistence.load() {
                currentParentName = snapshot.currentParentName
                parents = snapshot.parents
                trips = snapshot.trips
                coverRequests = snapshot.coverRequests
                calendarRegistration = snapshot.calendarRegistration
                activeGroup = snapshot.activeGroup
                groupMembers = snapshot.groupMembers ?? []
                groupInvitations = snapshot.groupInvitations ?? []
                approvedConstraints = snapshot.approvedConstraints ?? []
                constraintRequests = snapshot.constraintRequests ?? []
                calendarEvents = snapshot.calendarEvents ?? []
                calendarAnalyticsFromServer = snapshot.calendarAnalytics
                scheduleVersions = snapshot.scheduleVersions ?? []
                auditEvents = snapshot.auditEvents ?? []
                availableGroups = snapshot.availableGroups ?? []
                ensureCollaborativePilotState()
            } else {
                seedFreshPilot()
                await save(sync: false)
            }
        } catch {
            alertMessage = "Could not load saved data: \(error.localizedDescription)"
            seedFreshPilot()
        }
        await refreshNotificationStatus()
    }

    func signIn(phone: String, code: String, parentName: String) {
        let digits = normalizedPhone(phone)
        guard digits.count >= 10 else {
            alertMessage = "Enter a valid phone number."
            return
        }
        guard code == "123456" else {
            alertMessage = "Pilot code is 123456."
            return
        }
        guard parents.contains(where: { $0.name == parentName }) else {
            alertMessage = "Choose a parent profile."
            return
        }

        phoneNumber = digits
        currentParentName = parentName
        isSignedIn = true

        if let memberIndex = groupMembers.firstIndex(where: { $0.parentName == parentName }),
           groupMembers[memberIndex].phone == nil {
            groupMembers[memberIndex].phone = digits
            groupMembers[memberIndex].updatedAt = .now
        }
        Task {
            await save(sync: false)
            await refreshGroups(showSuccess: false)
        }
    }

    func signInInvited(
        phone: String,
        code: String,
        parentName: String,
        inviteToken: String,
        serverURL invitedServerURL: String? = nil
    ) async {
        let digits = normalizedPhone(phone)
        let name = parentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard digits.count >= 10 else {
            alertMessage = "Enter a valid phone number."
            return
        }
        guard code == "123456" else {
            alertMessage = "Pilot code is 123456."
            return
        }
        guard !name.isEmpty, !inviteToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alertMessage = "Enter the invited parent name and invitation code."
            return
        }
        guard let invitedServerURL,
              let components = URLComponents(string: invitedServerURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "http" || components.scheme == "https" else {
            alertMessage = "Enter the Mac pilot server URL included in the invitation."
            return
        }

        configurePilotServerURL(invitedServerURL)
        let previousParent = currentParentName
        let previousPhone = phoneNumber
        currentParentName = name
        phoneNumber = digits

        let accepted = await acceptInvitation(token: inviteToken)
        guard accepted else {
            currentParentName = previousParent
            phoneNumber = previousPhone
            isSignedIn = false
            return
        }

        isSignedIn = true
        serverStatus = "Connected — invitation accepted"
        await connectAndSync()
    }

    func signOut() { isSignedIn = false }

    // MARK: Cover and trip lifecycle

    func requestCover(for tripID: UUID, note: String) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        trips[index].status = .coverRequested
        coverRequests.removeAll { $0.tripID == tripID }
        coverRequests.append(
            CoverRequest(
                id: UUID(),
                tripID: tripID,
                requestedBy: currentParentName,
                note: note,
                createdAt: .now,
                acceptedBy: nil
            )
        )
        recordAudit(
            action: "cover_requested",
            entityType: "trip",
            entityID: tripID.uuidString,
            details: ["note": note]
        )
        alertMessage = "Cover request posted. Approved parents will see it after synchronization."
        Task { await save() }
    }

    func acceptCover(_ requestID: UUID) {
        guard let requestIndex = coverRequests.firstIndex(where: { $0.id == requestID }),
              let tripIndex = trips.firstIndex(where: { $0.id == coverRequests[requestIndex].tripID }) else { return }
        guard coverRequests[requestIndex].acceptedBy == nil else {
            alertMessage = "This request was already accepted."
            return
        }
        guard trips[tripIndex].scheduledDriver != currentParentName else {
            alertMessage = "The scheduled driver cannot claim their own cover request as a volunteer trip."
            return
        }

        coverRequests[requestIndex].acceptedBy = currentParentName
        trips[tripIndex].actualDriver = currentParentName
        trips[tripIndex].volunteerAssignment = true
        trips[tripIndex].status = .accepted
        recordAudit(
            action: "cover_accepted",
            entityType: "trip",
            entityID: trips[tripIndex].id.uuidString,
            details: ["volunteer": currentParentName, "pointsOnCompletion": "20"]
        )
        alertMessage = "You are now the volunteer driver. This trip earns 20 points when completed."
        Task {
            await save()
            if remindersEnabled { await scheduleLocalReminders() }
        }
    }

    func startTrip(_ tripID: UUID, now: Date = .now) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        guard trips[index].driver == currentParentName else {
            alertMessage = "Only the assigned driver can start this trip."
            return
        }
        guard trips[index].status == .scheduled || trips[index].status == .accepted else {
            alertMessage = "This trip cannot be started from its current status."
            return
        }
        let evaluation = startEligibility(for: trips[index], now: now)
        guard evaluation.allowed else {
            alertMessage = evaluation.message
            return
        }

        trips[index].status = .inProgress
        trips[index].startedAt = now
        recordAudit(
            action: "trip_started",
            entityType: "trip",
            entityID: tripID.uuidString,
            details: ["driver": currentParentName, "kind": trips[index].kind.rawValue]
        )
        Task { await save() }
    }

    func completeTrip(_ tripID: UUID, now: Date = .now) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        guard trips[index].driver == currentParentName else {
            alertMessage = "Only the active driver can complete this trip."
            return
        }
        guard trips[index].status == .inProgress else {
            alertMessage = "Start the trip before completing it."
            return
        }
        let evaluation = completionEligibility(for: trips[index], now: now)
        guard evaluation.allowed else {
            alertMessage = evaluation.message
            return
        }

        trips[index].status = .completed
        trips[index].completedAt = now
        recordAudit(
            action: "trip_completed",
            entityType: "trip",
            entityID: tripID.uuidString,
            details: [
                "driver": currentParentName,
                "points": trips[index].isVolunteerTrip ? "20" : "10",
                "volunteer": trips[index].isVolunteerTrip ? "true" : "false"
            ]
        )
        alertMessage = trips[index].isVolunteerTrip
            ? "Trip completed — 20 volunteer points earned!"
            : "Trip completed — 10 points earned!"
        Task { await save() }
    }

    func startEligibility(for trip: CarpoolTrip, now: Date = .now) -> (allowed: Bool, message: String) {
        if pilotTimeOverride { return (true, "Pilot time override enabled") }
        guard let scheduled = scheduledStart(for: trip) else {
            return (false, "The trip time has not been confirmed.")
        }
        let earliest = scheduled.addingTimeInterval(-30 * 60)
        let latest = scheduled.addingTimeInterval(90 * 60)
        if now < earliest {
            return (false, "Start becomes available 30 minutes before \(scheduled.formatted(date: .omitted, time: .shortened)).")
        }
        if now > latest {
            return (false, "This trip is outside its start window. Ask a group admin to correct the trip status.")
        }
        return (true, "Ready")
    }

    func completionEligibility(for trip: CarpoolTrip, now: Date = .now) -> (allowed: Bool, message: String) {
        if pilotTimeOverride { return (true, "Pilot time override enabled") }
        guard let scheduled = scheduledStart(for: trip) else {
            return (false, "The trip time has not been confirmed.")
        }
        guard now >= scheduled else {
            return (false, "Complete becomes available at the scheduled start time.")
        }
        if let startedAt = trip.startedAt, now.timeIntervalSince(startedAt) < 3 * 60 {
            return (false, "Wait at least 3 minutes after starting before completing the trip.")
        }
        let latest = scheduled.addingTimeInterval(4 * 60 * 60)
        guard now <= latest else {
            return (false, "This completion window has expired. A group admin must review it.")
        }
        return (true, "Ready")
    }

    func scheduledStart(for trip: CarpoolTrip) -> Date? {
        if trip.timeLabel.localizedCaseInsensitiveContains("confirm") { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = phoenixTimeZone
        var components = calendar.dateComponents([.year, .month, .day], from: trip.date)
        switch trip.kind {
        case .morningDrop:
            components.hour = 7
            components.minute = 0
        case .afternoonPickup:
            components.hour = 15
            components.minute = 35
        }
        return calendar.date(from: components)
    }

    func toggleChild(_ child: String, in tripID: UUID) {
        guard let index = trips.firstIndex(where: { $0.id == tripID }) else { return }
        if trips[index].childNames.contains(child) {
            trips[index].childNames.removeAll { $0 == child }
        } else {
            trips[index].childNames.append(child)
            trips[index].childNames.sort()
        }
        Task { await save() }
    }

    // MARK: Group creation, invitations, admins and workspace

    @discardableResult
    func createGroup(
        name: String,
        schoolName: String,
        schoolKey: String,
        academicYear: String,
        creatorChildName: String? = nil,
        creatorGrade: Int? = nil
    ) async -> Bool {
        guard let api = apiClient else {
            alertMessage = serverIdentityMessage
            return false
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            if serverStatus.hasPrefix("Connected") {
                try? await api.saveSnapshot(groupCode: activeGroup?.code ?? groupCode, snapshot: snapshot())
            }
            let creator = parents.first(where: { $0.name == currentParentName })
            let resolvedChildName = creatorChildName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let payload = CreateGroupPayload(
                code: nil,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                schoolKey: schoolKey.trimmingCharacters(in: .whitespacesAndNewlines),
                schoolName: schoolName.trimmingCharacters(in: .whitespacesAndNewlines),
                academicYear: academicYear.trimmingCharacters(in: .whitespacesAndNewlines),
                creatorChildName: (resolvedChildName?.isEmpty == false ? resolvedChildName! : creator?.childName) ?? "",
                creatorGrade: creatorGrade ?? creator?.grade ?? 1,
                initialDropWeekdays: (creator?.effectiveDropWeekdays ?? Set(2...6)).sorted(),
                initialPickupWeekdays: (creator?.pickupWeekdays ?? Set(2...6)).sorted(),
                initialNotes: creator?.notes ?? ""
            )
            let previousGroupCode = activeGroup?.code
            let workspace = try await api.createGroup(payload)
            applyWorkspace(workspace)
            if previousGroupCode != workspace.group.code {
                trips = []
                coverRequests = []
            }
            availableGroups = try await api.listGroups()
            serverStatus = "Connected — group created"
            alertMessage = "Carpool group created. It is now the active group, and your other groups remain available under Groups."
            await save()
            return true
        } catch {
            alertMessage = "Could not create the group: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func sendInvitation(
        parentName: String,
        phone: String,
        childName: String,
        grade: Int,
        role: GroupRole
    ) async -> Bool {
        guard isCurrentUserAdmin else {
            alertMessage = "Only an owner or admin can invite parents."
            return false
        }
        guard let group = activeGroup, let api = apiClient else {
            alertMessage = serverIdentityMessage
            return false
        }
        let invitedPhone = normalizedPhone(phone)
        if !invitedPhone.isEmpty, invitedPhone == normalizedPhone(phoneNumber) {
            alertMessage = "That phone number belongs to your signed-in parent profile. Use the invited parent's phone number, or leave the phone blank and share only the generated invitation code."
            return false
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let response = try await api.createInvitation(
                groupCode: group.code,
                payload: CreateInvitationPayload(
                    invitedParentName: parentName.trimmingCharacters(in: .whitespacesAndNewlines),
                    phone: invitedPhone.isEmpty ? nil : invitedPhone,
                    childName: childName.trimmingCharacters(in: .whitespacesAndNewlines),
                    grade: grade,
                    role: role
                )
            )
            groupInvitations.removeAll { $0.id == response.invitation.id }
            groupInvitations.insert(response.invitation, at: 0)
            alertMessage = "Invite created. Share code \(response.invitation.token) with \(response.invitation.invitedParentName)."
            await refreshGroupWorkspace(showSuccess: false)
            availableGroups = (try? await api.listGroups()) ?? availableGroups
            return true
        } catch {
            alertMessage = "Could not create the invitation: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func acceptInvitation(token: String) async -> Bool {
        guard let api = apiClient else {
            alertMessage = serverIdentityMessage
            return false
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else {
            alertMessage = "Enter the invitation code."
            return false
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let previousGroupCode = activeGroup?.code
            let workspace = try await api.acceptInvitation(
                token: trimmed,
                payload: AcceptInvitationPayload(phone: normalizedPhone(phoneNumber), parentName: currentParentName)
            )
            applyWorkspace(workspace)
            if previousGroupCode != workspace.group.code {
                trips = []
                coverRequests = []
            }
            availableGroups = (try? await api.listGroups()) ?? availableGroups
            alertMessage = "Invitation accepted. The group is active and all of your groups are available under Groups."
            await save(sync: false)
            return true
        } catch {
            alertMessage = "Could not accept the invitation: \(error.localizedDescription)"
            return false
        }
    }

    func refreshGroupWorkspace(showSuccess: Bool = true) async {
        guard let group = activeGroup, let api = apiClient else {
            if showSuccess { alertMessage = serverIdentityMessage }
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let workspace = try await api.workspace(groupCode: group.code)
            applyWorkspace(workspace)
            availableGroups = try await api.listGroups()
            serverStatus = "Connected — group data current"
            if showSuccess { alertMessage = "Group, calendar, constraints and audit history refreshed." }
            await save(sync: false)
        } catch {
            serverStatus = "Group refresh failed"
            if showSuccess { alertMessage = "Could not refresh the group: \(error.localizedDescription)" }
        }
    }

    func refreshGroups(showSuccess: Bool = true) async {
        guard let api = apiClient else {
            if showSuccess { alertMessage = serverIdentityMessage }
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            availableGroups = try await api.listGroups()
            serverStatus = "Connected — \(availableGroups.count) group\(availableGroups.count == 1 ? "" : "s") available"
            if showSuccess {
                alertMessage = availableGroups.isEmpty
                    ? "No server-backed groups are linked to this parent yet."
                    : "Your carpool groups are current."
            }
            await save(sync: false)
        } catch {
            if showSuccess { alertMessage = "Could not load your groups: \(error.localizedDescription)" }
        }
    }

    func switchGroup(to targetCode: String) async {
        let normalizedCode = targetCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalizedCode.isEmpty else { return }
        if activeGroup?.code == normalizedCode {
            alertMessage = "\(activeGroup?.name ?? normalizedCode) is already active."
            return
        }
        guard let api = apiClient else {
            alertMessage = serverIdentityMessage
            return
        }

        isSyncing = true
        defer { isSyncing = false }
        do {
            if let currentCode = activeGroup?.code, serverStatus.hasPrefix("Connected") {
                try? await api.saveSnapshot(groupCode: currentCode, snapshot: snapshot())
            }

            let workspace = try await api.workspace(groupCode: normalizedCode)
            let remoteSnapshot = try await api.snapshot(groupCode: normalizedCode)

            if let remoteSnapshot {
                applyTripState(remoteSnapshot)
            } else {
                parents = []
                trips = []
                coverRequests = []
            }
            applyWorkspace(workspace)
            availableGroups = try await api.listGroups()
            serverStatus = "Connected — \(workspace.group.name) active"
            await save(sync: false)
            if remindersEnabled { await scheduleLocalReminders() }
            alertMessage = "Switched to \(workspace.group.name)."
        } catch {
            alertMessage = "Could not switch groups: \(error.localizedDescription)"
        }
    }

    func updateMemberRole(parentName: String, role: GroupRole) async {
        guard isCurrentUserAdmin else {
            alertMessage = "Only an owner or admin can update member roles."
            return
        }
        guard let group = activeGroup, let api = apiClient else {
            alertMessage = serverIdentityMessage
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let workspace = try await api.updateMemberRole(
                groupCode: group.code,
                parentName: parentName,
                payload: MemberRolePayload(role: role)
            )
            applyWorkspace(workspace)
            alertMessage = "\(parentName) is now \(role.displayName)."
            await save(sync: false)
        } catch {
            alertMessage = "Could not update the role: \(error.localizedDescription)"
        }
    }

    // MARK: Constraint request and approval workflow

    func approvedConstraint(for parentName: String) -> ApprovedConstraint? {
        approvedConstraints.first { $0.parentName == parentName }
    }

    func latestConstraintRequest(for parentName: String) -> ConstraintChangeRequest? {
        constraintRequests
            .filter { $0.parentName == parentName }
            .sorted { $0.submittedAt > $1.submittedAt }
            .first
    }

    func submitConstraintRequest(dropWeekdays: Set<Int>, pickupWeekdays: Set<Int>, notes: String) async {
        guard let group = activeGroup, let api = apiClient else {
            alertMessage = serverIdentityMessage
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let response = try await api.submitConstraintRequest(
                groupCode: group.code,
                payload: ConstraintRequestPayload(
                    requestedDropWeekdays: dropWeekdays.sorted(),
                    requestedPickupWeekdays: pickupWeekdays.sorted(),
                    notes: notes
                )
            )
            constraintRequests.removeAll { $0.id == response.request.id }
            constraintRequests.insert(response.request, at: 0)
            alertMessage = "Availability update submitted for admin review. Estimated impact: \(response.request.existingAssignmentsAffected) future trips."
            await refreshGroupWorkspace(showSuccess: false)
        } catch {
            alertMessage = "Could not submit the availability request: \(error.localizedDescription)"
        }
    }

    func reviewConstraintRequest(_ requestID: UUID, approve: Bool, note: String) async {
        guard isCurrentUserAdmin else {
            alertMessage = "Only an owner or admin can review constraint requests."
            return
        }
        guard let group = activeGroup, let api = apiClient else {
            alertMessage = serverIdentityMessage
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let response = try await api.reviewConstraintRequest(
                groupCode: group.code,
                requestID: requestID,
                payload: ConstraintReviewPayload(
                    decision: approve ? "approved" : "rejected",
                    reviewNote: note
                )
            )
            if let constraint = response.constraint {
                upsertApprovedConstraint(constraint)
                regenerateFutureSchedule(reason: "Approved availability update for \(constraint.parentName)")
            }
            if let version = response.scheduleVersion {
                scheduleVersions.removeAll { $0.id == version.id }
                scheduleVersions.insert(version, at: 0)
                activeGroup?.currentScheduleVersion = version.version
            }
            constraintRequests.removeAll { $0.id == response.request.id }
            constraintRequests.insert(response.request, at: 0)
            alertMessage = approve
                ? "Request approved. Schedule version \(response.scheduleVersion?.version ?? activeGroup?.currentScheduleVersion ?? 1) recorded."
                : "Request rejected and preserved in the audit history."
            await refreshGroupWorkspace(showSuccess: false)
            await save()
        } catch {
            alertMessage = "Could not review the request: \(error.localizedDescription)"
        }
    }

    func regenerateScheduleFromConstraints() {
        regenerateFutureSchedule(reason: "Manual admin regeneration")
        Task {
            if let group = activeGroup, let api = apiClient, isCurrentUserAdmin {
                if let revision = try? await api.createScheduleRevision(groupCode: group.code, reason: "Manual admin regeneration") {
                    scheduleVersions.removeAll { $0.id == revision.id }
                    scheduleVersions.insert(revision, at: 0)
                    activeGroup?.currentScheduleVersion = revision.version
                }
            }
            await save()
        }
        alertMessage = "Future trips regenerated from approved constraints; completed and active trips were preserved."
    }

    private func upsertApprovedConstraint(_ constraint: ApprovedConstraint) {
        approvedConstraints.removeAll { $0.parentName == constraint.parentName }
        approvedConstraints.append(constraint)
        applyConstraintToParentProfile(constraint)
    }

    private func applyConstraintToParentProfile(_ constraint: ApprovedConstraint) {
        guard let index = parents.firstIndex(where: { $0.name == constraint.parentName }) else { return }
        parents[index].dropWeekdays = constraint.dropWeekdays
        parents[index].pickupWeekdays = constraint.pickupWeekdays
        parents[index].canDriveMorning = !constraint.dropWeekdays.isEmpty
        parents[index].notes = constraint.notes
    }

    private func regenerateFutureSchedule(reason: String) {
        let generated = ScheduleGenerator.generate(parents: parents)
        let today = Calendar.current.startOfDay(for: .now)
        let preserved = trips.filter { trip in
            trip.date < today || trip.status != .scheduled
        }
        let preservedIDs = Set(preserved.map(\.id))
        let replacement = generated.filter { $0.date >= today && !preservedIDs.contains($0.id) }
        trips = (preserved + replacement).sorted { lhs, rhs in
            if lhs.date == rhs.date { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.date < rhs.date
        }
        coverRequests.removeAll { request in !trips.contains(where: { $0.id == request.tripID }) }
        for trip in replacement where trip.driver == "Unassigned" {
            guard !coverRequests.contains(where: { $0.tripID == trip.id }) else { continue }
            coverRequests.append(
                CoverRequest(
                    id: UUID(),
                    tripID: trip.id,
                    requestedBy: "Schedule engine",
                    note: "No parent is available under the approved weekday constraints.",
                    createdAt: .now,
                    acceptedBy: nil
                )
            )
        }
        recordAudit(
            action: "schedule_regenerated",
            entityType: "schedule",
            entityID: activeGroup?.code ?? groupCode,
            details: ["reason": reason]
        )
    }

    // MARK: Calendar ownership and analytics

    func uploadAuthoritativeCalendar(sourceName: String, sourceData: Data? = nil) async {
        guard isCurrentUserAdmin else {
            alertMessage = "Only an owner or admin can upload the authoritative school calendar."
            return
        }
        if let existing = calendarRegistration {
            alertMessage = "Holiday schedule is already uploaded by \(existing.uploadedBy) and considered in the carpool schedule. Duplicate uploads are not allowed."
            return
        }
        guard let group = activeGroup, let api = apiClient else {
            alertMessage = serverIdentityMessage
            return
        }
        guard group.schoolKey == "basis-phoenix-primary", group.academicYear == "2026-27" else {
            alertMessage = "This pilot build currently parses only the BASIS Phoenix Primary 2026–27 calendar. Do not publish dates for another school using this template."
            return
        }
        let sourceHash = sourceData.map { data in
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        if group.schoolKey == "basis-phoenix-primary",
           let sourceHash,
           sourceHash != expectedBasisCalendarSHA256 {
            alertMessage = "The selected PDF does not match the validated BASIS Phoenix Primary 2026–27 calendar. Select the authoritative PDF supplied by the school."
            return
        }

        isSyncing = true
        defer { isSyncing = false }
        do {
            let response = try await api.uploadCalendar(
                groupCode: group.code,
                payload: CalendarUploadPayload(
                    schoolKey: group.schoolKey,
                    schoolName: group.schoolName,
                    academicYear: group.academicYear,
                    sourceName: sourceName,
                    sourceSHA256: sourceHash,
                    sourceFileSize: sourceData?.count,
                    sourceContentBase64: sourceData?.base64EncodedString(),
                    events: SchoolCalendarData.events
                )
            )
            calendarRegistration = response.calendar
            calendarEvents = SchoolCalendarData.events
            calendarAnalyticsFromServer = response.analytics
            alertMessage = "The authoritative calendar is active and included in the carpool schedule."
            await refreshGroupWorkspace(showSuccess: false)
            await save(sync: false)
        } catch {
            alertMessage = "Calendar upload failed: \(error.localizedDescription)"
        }
    }

    // Compatibility wrapper for earlier views.
    func registerAuthoritativeCalendar(sourceName: String) {
        Task { await uploadAuthoritativeCalendar(sourceName: sourceName) }
    }

    // MARK: Pilot server synchronization

    func connectAndSync() async {
        guard let base = normalizedServerURL else {
            alertMessage = "Enter a valid server URL."
            return
        }
        guard !normalizedPhone(phoneNumber).isEmpty else {
            alertMessage = "Sign in with a phone number before connecting to the shared server."
            return
        }

        isSyncing = true
        defer { isSyncing = false }
        do {
            let api = PilotAPIClient(baseURL: base, parentName: currentParentName, phone: normalizedPhone(phoneNumber))
            try await api.health()
            availableGroups = try await api.listGroups()
            if !availableGroups.isEmpty,
               !availableGroups.contains(where: { $0.group.code == groupCode }) {
                groupCode = availableGroups[0].group.code
            }

            // Keep the existing trip snapshot sync during the pilot.
            var getRequest = URLRequest(url: base.appending(path: "v1/groups/\(groupCode)/snapshot"))
            addIdentityHeaders(to: &getRequest)
            let (remoteData, remoteResponse) = try await URLSession.shared.data(for: getRequest)
            guard let remoteHTTP = remoteResponse as? HTTPURLResponse else { throw URLError(.badServerResponse) }

            if remoteHTTP.statusCode == 200 {
                let remote = try JSONDecoder.kcp.decode(AppSnapshot.self, from: remoteData)
                applySnapshot(remote)
            } else if remoteHTTP.statusCode == 404 {
                var putRequest = URLRequest(url: base.appending(path: "v1/groups/\(groupCode)/snapshot"))
                putRequest.httpMethod = "PUT"
                putRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                addIdentityHeaders(to: &putRequest)
                putRequest.httpBody = try JSONEncoder.kcp.encode(snapshot())
                let (_, putResponse) = try await URLSession.shared.data(for: putRequest)
                guard let http = putResponse as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                    throw URLError(.badServerResponse)
                }
            } else {
                throw URLError(.badServerResponse)
            }

            do {
                let workspace = try await api.workspace(groupCode: groupCode)
                applyWorkspace(workspace)
            } catch let error as PilotAPIError where error.statusCode == 404 {
                // Older backend or a brand-new group: trip snapshot still remains usable.
            }

            UserDefaults.standard.set(serverURL, forKey: "kcp.serverURL")
            UserDefaults.standard.set(groupCode, forKey: "kcp.groupCode")
            serverStatus = "Connected and synchronized"
            await save(sync: false)
            alertMessage = "Connected. Trips, group membership, calendar, constraints and audit data are synchronized."
        } catch {
            serverStatus = "Connection failed"
            alertMessage = "Could not reach the KCP server: \(error.localizedDescription)"
        }
    }

    func pullFromServer() async {
        guard let base = normalizedServerURL else {
            alertMessage = "Enter a valid server URL."
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            var request = URLRequest(url: base.appending(path: "v1/groups/\(groupCode)/snapshot"))
            addIdentityHeaders(to: &request)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let remote = try JSONDecoder.kcp.decode(AppSnapshot.self, from: data)
            applySnapshot(remote)
            if let api = apiClient, let group = activeGroup {
                let workspace = try await api.workspace(groupCode: group.code)
                applyWorkspace(workspace)
            }
            serverStatus = "Connected — latest data loaded"
            await save(sync: false)
        } catch {
            alertMessage = "Could not download shared data: \(error.localizedDescription)"
        }
    }

    func configurePilotServerURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        serverURL = trimmed
        UserDefaults.standard.set(trimmed, forKey: "kcp.serverURL")
    }

    func invitationShareText(_ invitation: GroupInvitation) -> String {
        let endpoint = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Join \(invitation.groupCode) in Kidscarpool (KCP).
        Invitation code: \(invitation.token)
        Parent: \(invitation.invitedParentName)
        Pilot server: \(endpoint)

        Install the KCP pilot, choose “I have an invitation,” then enter this server and invitation code.
        """
    }

    private var normalizedServerURL: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), components.scheme != nil else { return nil }
        if components.path.isEmpty { components.path = "/" }
        return components.url
    }

    private var apiClient: PilotAPIClient? {
        guard let base = normalizedServerURL else { return nil }
        let phone = normalizedPhone(phoneNumber)
        guard !phone.isEmpty else { return nil }
        return PilotAPIClient(baseURL: base, parentName: currentParentName, phone: phone)
    }

    private var serverIdentityMessage: String {
        "Connect the central database and sign in with your phone number before using shared group workflows."
    }

    private func addIdentityHeaders(to request: inout URLRequest) {
        request.setValue(currentParentName, forHTTPHeaderField: "X-KCP-Parent")
        request.setValue(normalizedPhone(phoneNumber), forHTTPHeaderField: "X-KCP-Phone")
    }

    private func normalizedPhone(_ value: String) -> String {
        value.filter(\.isNumber)
    }

    // MARK: Persistence and audit

    func resetPilot() async {
        do { try await persistence.reset() } catch { }
        seedFreshPilot()
        currentParentName = "Kiran"
        await save(sync: false)
        if remindersEnabled { await scheduleLocalReminders() }
    }

    private func snapshot() -> AppSnapshot {
        AppSnapshot(
            currentParentName: currentParentName,
            parents: parents,
            trips: trips,
            coverRequests: coverRequests,
            calendarRegistration: calendarRegistration,
            activeGroup: activeGroup,
            groupMembers: groupMembers,
            groupInvitations: groupInvitations,
            approvedConstraints: approvedConstraints,
            constraintRequests: constraintRequests,
            calendarEvents: calendarEvents,
            calendarAnalytics: calendarAnalyticsFromServer,
            scheduleVersions: scheduleVersions,
            auditEvents: auditEvents,
            availableGroups: availableGroups
        )
    }

    func save(sync: Bool = true) async {
        do {
            try await persistence.save(snapshot())
            if sync && serverStatus.hasPrefix("Connected") { await pushWithoutAlert() }
        } catch {
            alertMessage = "Could not save: \(error.localizedDescription)"
        }
    }

    private func pushWithoutAlert() async {
        guard let base = normalizedServerURL else { return }
        do {
            var request = URLRequest(url: base.appending(path: "v1/groups/\(groupCode)/snapshot"))
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            addIdentityHeaders(to: &request)
            request.httpBody = try JSONEncoder.kcp.encode(snapshot())
            _ = try await URLSession.shared.data(for: request)
        } catch {
            serverStatus = "Offline — changes saved on phone"
        }
    }

    private func applySnapshot(_ remote: AppSnapshot) {
        parents = remote.parents
        trips = remote.trips
        coverRequests = remote.coverRequests
        calendarRegistration = remote.calendarRegistration
        if let value = remote.activeGroup { activeGroup = value }
        if let value = remote.groupMembers { groupMembers = value }
        if let value = remote.groupInvitations { groupInvitations = value }
        if let value = remote.approvedConstraints { approvedConstraints = value }
        if let value = remote.constraintRequests { constraintRequests = value }
        if let value = remote.calendarEvents { calendarEvents = value }
        if let value = remote.calendarAnalytics { calendarAnalyticsFromServer = value }
        if let value = remote.scheduleVersions { scheduleVersions = value }
        if let value = remote.auditEvents { auditEvents = value }
        if let value = remote.availableGroups { availableGroups = value }
        ensureCollaborativePilotState()
    }

    private func applyTripState(_ remote: AppSnapshot) {
        parents = remote.parents
        trips = remote.trips
        coverRequests = remote.coverRequests
    }

    private func applyWorkspace(_ workspace: GroupWorkspace) {
        activeGroup = workspace.group
        groupCode = workspace.group.code
        groupMembers = workspace.members
        let activeNames = Set(workspace.members.filter { $0.status == .active }.map(\.parentName))
        parents = parents.filter { activeNames.contains($0.name) }
        groupInvitations = workspace.invitations
        approvedConstraints = workspace.constraints
        constraintRequests = workspace.constraintRequests
        calendarRegistration = workspace.calendar
        calendarEvents = workspace.calendarEvents
        calendarAnalyticsFromServer = workspace.calendar == nil ? nil : workspace.calendarAnalytics
        scheduleVersions = workspace.scheduleVersions
        auditEvents = workspace.auditEvents
        mergeParentsFromMembers()
        approvedConstraints.forEach(applyConstraintToParentProfile)
        UserDefaults.standard.set(groupCode, forKey: "kcp.groupCode")
        if let index = availableGroups.firstIndex(where: { $0.group.code == workspace.group.code }) {
            availableGroups[index].group = workspace.group
            availableGroups[index].role = currentRole
            availableGroups[index].membershipStatus = currentMember?.status ?? .active
            availableGroups[index].activeMemberCount = workspace.members.filter { $0.status == .active }.count
            availableGroups[index].pendingInvitationCount = workspace.invitations.filter { $0.status == .pending }.count
            availableGroups[index].pendingConstraintCount = workspace.constraintRequests.filter { $0.status == .pending }.count
            availableGroups[index].calendarRegistered = workspace.calendar != nil
            availableGroups[index].lastActivityAt = workspace.auditEvents.first?.occurredAt ?? workspace.group.updatedAt
        }
    }

    private func mergeParentsFromMembers() {
        for member in groupMembers where member.status == .active && !member.childName.isEmpty {
            if let index = parents.firstIndex(where: { $0.name == member.parentName }) {
                parents[index].childName = member.childName
                parents[index].grade = member.grade
            } else {
                parents.append(
                    ParentProfile(
                        id: UUID(),
                        name: member.parentName,
                        childName: member.childName,
                        grade: member.grade,
                        canDriveMorning: true,
                        pickupWeekdays: Set(2...6),
                        dropWeekdays: Set(2...6),
                        notes: ""
                    )
                )
            }
        }
    }

    private func recordAudit(action: String, entityType: String, entityID: String, details: [String: String]) {
        let localID = Int64(Date().timeIntervalSince1970 * 1_000_000)
        auditEvents.insert(
            AuditEvent(
                id: localID,
                groupCode: activeGroup?.code ?? groupCode,
                actorName: currentParentName,
                action: action,
                entityType: entityType,
                entityID: entityID,
                details: details,
                occurredAt: .now
            ),
            at: 0
        )
        if auditEvents.count > 250 { auditEvents = Array(auditEvents.prefix(250)) }

        guard serverStatus.hasPrefix("Connected"), let api = apiClient, let group = activeGroup else { return }
        Task {
            try? await api.appendAudit(
                groupCode: group.code,
                payload: AuditAppendPayload(
                    action: action,
                    entityType: entityType,
                    entityID: entityID,
                    details: details
                )
            )
        }
    }

    private func ensureCollaborativePilotState() {
        if activeGroup == nil {
            seedCollaborativeState()
        }
        if calendarRegistration != nil {
            if calendarEvents.isEmpty { calendarEvents = SchoolCalendarData.events }
            if calendarAnalyticsFromServer == nil {
                calendarAnalyticsFromServer = SchoolCalendarData.analytics(events: calendarEvents)
            }
        } else {
            calendarEvents = []
            calendarAnalyticsFromServer = nil
        }
        if availableGroups.isEmpty, let group = activeGroup {
            availableGroups = [
                UserGroupSummary(
                    group: group,
                    role: currentRole,
                    membershipStatus: currentMember?.status ?? .active,
                    childName: currentMember?.childName ?? parents.first(where: { $0.name == currentParentName })?.childName ?? "",
                    grade: currentMember?.grade ?? parents.first(where: { $0.name == currentParentName })?.grade ?? 1,
                    activeMemberCount: groupMembers.filter { $0.status == .active }.count,
                    pendingInvitationCount: groupInvitations.filter { $0.status == .pending }.count,
                    pendingConstraintCount: constraintRequests.filter { $0.status == .pending }.count,
                    calendarRegistered: calendarRegistration != nil,
                    lastActivityAt: auditEvents.first?.occurredAt ?? group.updatedAt
                )
            ]
        }
        if approvedConstraints.isEmpty {
            approvedConstraints = parents.map { parent in
                ApprovedConstraint(
                    groupCode: activeGroup?.code ?? groupCode,
                    parentName: parent.name,
                    dropWeekdays: parent.effectiveDropWeekdays,
                    pickupWeekdays: parent.pickupWeekdays,
                    notes: parent.notes ?? "",
                    version: 1,
                    effectiveFrom: SchoolCalendarData.schoolStart,
                    updatedBy: "Kiran",
                    updatedAt: activeGroup?.createdAt ?? .now
                )
            }
        }
    }

    private func seedFreshPilot() {
        parents = Self.seedParents
        trips = ScheduleGenerator.generate(parents: parents)
        coverRequests = []
        calendarRegistration = CalendarRegistration(
            schoolKey: "basis-phoenix-primary",
            academicYear: "2026-27",
            uploadedBy: "Kiran",
            uploadedAt: SchoolCalendarData.date(2026, 8, 1),
            sourceName: "BASIS Phoenix Primary Academic Calendar 2026–27",
            schoolName: "BASIS Phoenix Primary",
            eventCount: SchoolCalendarData.events.count
        )
        calendarEvents = SchoolCalendarData.events
        calendarAnalyticsFromServer = SchoolCalendarData.analytics(events: calendarEvents)
        seedCollaborativeState()
    }

    private func seedCollaborativeState() {
        let created = SchoolCalendarData.date(2026, 8, 1)
        activeGroup = CarpoolGroup(
            code: groupCode,
            name: "BASIS Phoenix Primary Carpool",
            schoolKey: "basis-phoenix-primary",
            schoolName: "BASIS Phoenix Primary",
            academicYear: "2026-27",
            status: "active",
            createdBy: "Kiran",
            createdAt: created,
            updatedAt: created,
            currentScheduleVersion: 1
        )
        groupMembers = parents.enumerated().map { index, parent in
            GroupMember(
                groupCode: groupCode,
                parentName: parent.name,
                phone: nil,
                childName: parent.childName,
                grade: parent.grade,
                role: index == 0 ? .owner : .parent,
                status: .active,
                invitedBy: index == 0 ? nil : "Kiran",
                joinedAt: created,
                updatedAt: created
            )
        }
        groupInvitations = []
        approvedConstraints = parents.map { parent in
            ApprovedConstraint(
                groupCode: groupCode,
                parentName: parent.name,
                dropWeekdays: parent.effectiveDropWeekdays,
                pickupWeekdays: parent.pickupWeekdays,
                notes: parent.notes ?? "",
                version: 1,
                effectiveFrom: SchoolCalendarData.schoolStart,
                updatedBy: "Kiran",
                updatedAt: created
            )
        }
        constraintRequests = []
        scheduleVersions = [
            ScheduleRevision(
                id: UUID(uuidString: "20000000-0000-4000-8000-000000000001")!,
                groupCode: groupCode,
                version: 1,
                status: .published,
                reason: "Initial schedule generated from confirmed parent availability",
                generatedBy: "Kiran",
                generatedAt: created,
                publishedBy: "Kiran",
                publishedAt: created,
                changeSummary: ["members": "4", "schoolDays": "180"]
            )
        ]
        auditEvents = [
            AuditEvent(
                id: 1,
                groupCode: groupCode,
                actorName: "Kiran",
                action: "group_created",
                entityType: "group",
                entityID: groupCode,
                details: ["name": "BASIS Phoenix Primary Carpool"],
                occurredAt: created
            ),
            AuditEvent(
                id: 2,
                groupCode: groupCode,
                actorName: "Kiran",
                action: "calendar_registered",
                entityType: "calendar",
                entityID: "basis-phoenix-primary-2026-27",
                details: ["source": "BASIS Phoenix Primary Academic Calendar 2026–27"],
                occurredAt: created
            ),
            AuditEvent(
                id: 3,
                groupCode: groupCode,
                actorName: "Kiran",
                action: "schedule_published",
                entityType: "schedule",
                entityID: "1",
                details: ["version": "1"],
                occurredAt: created
            )
        ]
        if let group = activeGroup {
            availableGroups = [
                UserGroupSummary(
                    group: group,
                    role: .owner,
                    membershipStatus: .active,
                    childName: "Thanishka",
                    grade: 4,
                    activeMemberCount: groupMembers.filter { $0.status == .active }.count,
                    pendingInvitationCount: 0,
                    pendingConstraintCount: 0,
                    calendarRegistered: calendarRegistration != nil,
                    lastActivityAt: created
                )
            ]
        }
    }

    // MARK: Pilot settings and notifications

    func setPilotTimeOverride(_ enabled: Bool) {
        pilotTimeOverride = enabled
        UserDefaults.standard.set(enabled, forKey: "kcp.pilotTimeOverride")
    }

    func requestNotificationPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            remindersEnabled = granted
            await refreshNotificationStatus()
            if granted {
                await scheduleLocalReminders()
                alertMessage = "Reminders enabled for your upcoming assigned trips."
            } else {
                alertMessage = "Notifications are disabled. Enable them in iPhone Settings → Notifications → Kidscarpool."
            }
        } catch {
            alertMessage = "Could not request notifications: \(error.localizedDescription)"
        }
    }

    func disableNotifications() async {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        remindersEnabled = false
        notificationStatus = "Reminders paused"
    }

    func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationStatus = "Allowed"
            remindersEnabled = true
        case .denied:
            notificationStatus = "Denied in Settings"
            remindersEnabled = false
        case .notDetermined:
            notificationStatus = "Not requested"
            remindersEnabled = false
        @unknown default:
            notificationStatus = "Unknown"
            remindersEnabled = false
        }
    }

    func scheduleLocalReminders() async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        let now = Date()
        let assigned = trips
            .filter { $0.driver == currentParentName && $0.status != .cancelled && $0.status != .completed }
            .sorted { $0.date < $1.date }

        for trip in assigned.prefix(50) {
            guard let tripTime = scheduledStart(for: trip), tripTime > now else { continue }
            let fireDate = tripTime.addingTimeInterval(-30 * 60)
            guard fireDate > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = trip.kind == .morningDrop ? "Morning carpool in 30 minutes" : "School pickup in 30 minutes"
            content.body = "You are driving for \(trip.childNames.count) children at \(trip.timeLabel)."
            content.sound = .default
            content.badge = 1
            content.userInfo = ["tripID": trip.id.uuidString]

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = phoenixTimeZone
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            try? await center.add(
                UNNotificationRequest(
                    identifier: "trip-\(trip.id.uuidString)",
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                )
            )
        }
    }

    static let seedParents = [
        ParentProfile(
            id: UUID(uuidString: "30000000-0000-4000-8000-000000000001")!,
            name: "Kiran",
            childName: "Thanishka",
            grade: 4,
            canDriveMorning: true,
            pickupWeekdays: Set(2...6),
            dropWeekdays: Set(2...6),
            notes: ""
        ),
        ParentProfile(
            id: UUID(uuidString: "30000000-0000-4000-8000-000000000002")!,
            name: "Mohan",
            childName: "Saanvi",
            grade: 5,
            canDriveMorning: true,
            pickupWeekdays: Set(2...6),
            dropWeekdays: Set(2...6),
            notes: ""
        ),
        ParentProfile(
            id: UUID(uuidString: "30000000-0000-4000-8000-000000000003")!,
            name: "Pavan",
            childName: "Ishi",
            grade: 1,
            canDriveMorning: true,
            pickupWeekdays: Set(2...6),
            dropWeekdays: Set(2...6),
            notes: "Thursday preferred"
        ),
        ParentProfile(
            id: UUID(uuidString: "30000000-0000-4000-8000-000000000004")!,
            name: "Santosh",
            childName: "Kavish",
            grade: 5,
            canDriveMorning: false,
            pickupWeekdays: [3, 5],
            dropWeekdays: [],
            notes: "Pickup only; Tuesday or Thursday"
        )
    ]
}
