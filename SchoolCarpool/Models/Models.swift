import Foundation

// MARK: - Trips

enum TripKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case morningDrop = "Morning drop"
    case afternoonPickup = "Afternoon pickup"

    var id: String { rawValue }
    var symbol: String { self == .morningDrop ? "sunrise.fill" : "sunset.fill" }
}

enum TripStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case scheduled = "Scheduled"
    case coverRequested = "Cover requested"
    case accepted = "Cover accepted"
    case inProgress = "In progress"
    case completed = "Completed"
    case cancelled = "Cancelled"

    var id: String { rawValue }
}

struct ParentProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var childName: String
    var grade: Int
    var canDriveMorning: Bool
    var pickupWeekdays: Set<Int>
    var dropWeekdays: Set<Int>?
    var notes: String?

    var effectiveDropWeekdays: Set<Int> {
        dropWeekdays ?? (canDriveMorning ? Set(2...6) : [])
    }
}

struct CarpoolTrip: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var date: Date
    var kind: TripKind
    var scheduledDriver: String
    var actualDriver: String
    var status: TripStatus
    var timeLabel: String
    var notes: String
    var childNames: [String]
    var completedAt: Date?
    var startedAt: Date?
    var volunteerAssignment: Bool?

    var driver: String { actualDriver.isEmpty ? scheduledDriver : actualDriver }
    var isVolunteerTrip: Bool {
        volunteerAssignment == true || (!actualDriver.isEmpty && actualDriver != scheduledDriver)
    }
    var points: Int { status == .completed ? (isVolunteerTrip ? 20 : 10) : 0 }
}

struct CoverRequest: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var tripID: UUID
    var requestedBy: String
    var note: String
    var createdAt: Date
    var acceptedBy: String?
}

struct LeaderboardRow: Identifiable, Hashable {
    var id: String { parentName }
    let parentName: String
    let scheduledCompleted: Int
    let volunteerCompleted: Int
    let points: Int
}

// MARK: - Group collaboration

enum GroupRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case owner
    case admin
    case parent
    case viewer

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
    var canAdminister: Bool { self == .owner || self == .admin }
    var symbol: String {
        switch self {
        case .owner: return "crown.fill"
        case .admin: return "person.badge.key.fill"
        case .parent: return "person.fill"
        case .viewer: return "eye.fill"
        }
    }
}

enum MembershipStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case invited
    case pending
    case active
    case suspended
    case removed

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

enum InvitationStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending
    case accepted
    case declined
    case expired
    case revoked

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

struct CarpoolGroup: Identifiable, Codable, Hashable, Sendable {
    var id: String { code }
    var code: String
    var name: String
    var schoolKey: String
    var schoolName: String
    var academicYear: String
    var status: String
    var createdBy: String
    var createdAt: Date
    var updatedAt: Date
    var currentScheduleVersion: Int
}

struct GroupMember: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(groupCode)-\(parentName)" }
    var groupCode: String
    var parentName: String
    var phone: String?
    var childName: String
    var grade: Int
    var role: GroupRole
    var status: MembershipStatus
    var invitedBy: String?
    var joinedAt: Date?
    var updatedAt: Date
}

struct UserGroupSummary: Identifiable, Codable, Hashable, Sendable {
    var id: String { group.code }
    var group: CarpoolGroup
    var role: GroupRole
    var membershipStatus: MembershipStatus
    var childName: String
    var grade: Int
    var activeMemberCount: Int
    var pendingInvitationCount: Int
    var pendingConstraintCount: Int
    var calendarRegistered: Bool
    var lastActivityAt: Date
}

struct GroupsResponse: Codable, Sendable {
    var groups: [UserGroupSummary]
}

struct GroupInvitation: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var groupCode: String
    var token: String
    var invitedParentName: String
    var phone: String?
    var childName: String
    var grade: Int
    var role: GroupRole
    var status: InvitationStatus
    var invitedBy: String
    var createdAt: Date
    var expiresAt: Date
    var acceptedAt: Date?
    var acceptedBy: String?

    var shareText: String {
        "Join \(groupCode) in Kidscarpool. Invite code: \(token)"
    }
}

struct ApprovedConstraint: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(groupCode)-\(parentName)" }
    var groupCode: String
    var parentName: String
    var dropWeekdays: Set<Int>
    var pickupWeekdays: Set<Int>
    var notes: String
    var version: Int
    var effectiveFrom: Date?
    var updatedBy: String
    var updatedAt: Date
}

enum ConstraintRequestStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending
    case approved
    case rejected
    case withdrawn

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

struct ConstraintChangeRequest: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var groupCode: String
    var parentName: String
    var previousDropWeekdays: Set<Int>
    var previousPickupWeekdays: Set<Int>
    var requestedDropWeekdays: Set<Int>
    var requestedPickupWeekdays: Set<Int>
    var notes: String
    var status: ConstraintRequestStatus
    var submittedAt: Date
    var reviewedAt: Date?
    var reviewedBy: String?
    var rejectionReason: String?
    var existingAssignmentsAffected: Int
    var baseVersion: Int
}

enum ScheduleVersionStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case draft
    case published
    case superseded

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

struct ScheduleRevision: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var groupCode: String
    var version: Int
    var status: ScheduleVersionStatus
    var reason: String
    var generatedBy: String
    var generatedAt: Date
    var publishedBy: String?
    var publishedAt: Date?
    var changeSummary: [String: String]
}

struct AuditEvent: Identifiable, Codable, Hashable, Sendable {
    var id: Int64
    var groupCode: String
    var actorName: String
    var action: String
    var entityType: String
    var entityID: String
    var details: [String: String]
    var occurredAt: Date
}

// MARK: - School calendar

enum SchoolCalendarEventType: String, Codable, CaseIterable, Identifiable, Sendable {
    case noSchool = "no_school"
    case earlyRelease = "early_release"
    case noLateBird = "no_late_bird"
    case projectWeek = "project_week"
    case firstDay = "first_day"
    case lastDay = "last_day"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .noSchool: return "No school"
        case .earlyRelease: return "Early pickup"
        case .noLateBird: return "No Late Bird"
        case .projectWeek: return "Project Week"
        case .firstDay: return "First day"
        case .lastDay: return "Last day"
        }
    }
    var symbol: String {
        switch self {
        case .noSchool: return "calendar.badge.minus"
        case .earlyRelease: return "clock.badge.exclamationmark"
        case .noLateBird: return "person.crop.circle.badge.exclamationmark"
        case .projectWeek: return "hammer.fill"
        case .firstDay: return "flag.checkered"
        case .lastDay: return "checkered.flag"
        }
    }
}

struct SchoolCalendarEvent: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var type: SchoolCalendarEventType
    var title: String
    var startDate: Date
    var endDate: Date
    var notes: String

    var dateRangeLabel: String {
        if Calendar.current.isDate(startDate, inSameDayAs: endDate) {
            return startDate.formatted(date: .abbreviated, time: .omitted)
        }
        return "\(startDate.formatted(date: .abbreviated, time: .omitted)) – \(endDate.formatted(date: .abbreviated, time: .omitted))"
    }
}

struct CalendarRegistration: Codable, Hashable, Sendable {
    var schoolKey: String
    var academicYear: String
    var uploadedBy: String
    var uploadedAt: Date
    var sourceName: String
    var schoolName: String?
    var eventCount: Int?
    var sourceSHA256: String? = nil
    var sourceFileSize: Int? = nil
}

struct CalendarAnalytics: Codable, Hashable, Sendable {
    var instructionalDays: Int
    var holidayPeriods: Int
    var noSchoolWeekdays: Int
    var longWeekends: Int
    var upcomingLongWeekends: Int
    var earlyPickups: Int
    var noLateBirdDays: Int
    var projectWeekDays: Int
    var longestBreakDays: Int
    var longestBreakTitle: String?
    var upcomingEventCount: Int
    var nextEventTitle: String?
    var nextEventDate: Date?
}

// MARK: - Workspace payload

struct GroupWorkspace: Codable, Sendable {
    var group: CarpoolGroup
    var members: [GroupMember]
    var invitations: [GroupInvitation]
    var constraints: [ApprovedConstraint]
    var constraintRequests: [ConstraintChangeRequest]
    var calendar: CalendarRegistration?
    var calendarEvents: [SchoolCalendarEvent]
    var calendarAnalytics: CalendarAnalytics?
    var scheduleVersions: [ScheduleRevision]
    var auditEvents: [AuditEvent]
}

// MARK: - Local snapshot

struct AppSnapshot: Codable, Sendable {
    var currentParentName: String
    var parents: [ParentProfile]
    var trips: [CarpoolTrip]
    var coverRequests: [CoverRequest]
    var calendarRegistration: CalendarRegistration?

    // Optional to decode snapshots created by earlier pilots.
    var activeGroup: CarpoolGroup? = nil
    var groupMembers: [GroupMember]? = nil
    var groupInvitations: [GroupInvitation]? = nil
    var approvedConstraints: [ApprovedConstraint]? = nil
    var constraintRequests: [ConstraintChangeRequest]? = nil
    var calendarEvents: [SchoolCalendarEvent]? = nil
    var calendarAnalytics: CalendarAnalytics? = nil
    var scheduleVersions: [ScheduleRevision]? = nil
    var auditEvents: [AuditEvent]? = nil
    var availableGroups: [UserGroupSummary]? = nil
}
