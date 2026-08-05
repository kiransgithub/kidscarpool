import Foundation

struct CreateGroupPayload: Codable, Sendable {
    var code: String?
    var name: String
    var schoolKey: String
    var schoolName: String
    var academicYear: String
    var creatorChildName: String
    var creatorGrade: Int
    var initialDropWeekdays: [Int]
    var initialPickupWeekdays: [Int]
    var initialNotes: String
}

struct CreateInvitationPayload: Codable, Sendable {
    var invitedParentName: String
    var phone: String?
    var childName: String
    var grade: Int
    var role: GroupRole
}

struct AcceptInvitationPayload: Codable, Sendable {
    var phone: String
    var parentName: String
}

struct ConstraintRequestPayload: Codable, Sendable {
    var requestedDropWeekdays: [Int]
    var requestedPickupWeekdays: [Int]
    var notes: String
}

struct ConstraintReviewPayload: Codable, Sendable {
    var decision: String
    var reviewNote: String
}

struct MemberRolePayload: Codable, Sendable {
    var role: GroupRole
}

struct CalendarUploadPayload: Codable, Sendable {
    var schoolKey: String
    var schoolName: String
    var academicYear: String
    var sourceName: String
    var sourceSHA256: String?
    var sourceFileSize: Int?
    var sourceContentBase64: String?
    var events: [SchoolCalendarEvent]
}

struct InvitationResponse: Codable, Sendable {
    var invitation: GroupInvitation
}

struct ConstraintResponse: Codable, Sendable {
    var request: ConstraintChangeRequest
    var constraint: ApprovedConstraint?
    var scheduleVersion: ScheduleRevision?
}

struct CalendarUploadResponse: Codable, Sendable {
    var status: String
    var calendar: CalendarRegistration
    var analytics: CalendarAnalytics
}


struct AuditAppendPayload: Codable, Sendable {
    var action: String
    var entityType: String
    var entityID: String
    var details: [String: String]
}

struct ScheduleRevisionResponse: Codable, Sendable {
    var scheduleVersion: ScheduleRevision
}

struct PilotAPIError: LocalizedError {
    let statusCode: Int
    let message: String
    var errorDescription: String? { message }
}

struct PilotAPIClient {
    let baseURL: URL
    let parentName: String
    let phone: String

    func health() async throws {
        let (_, response) = try await URLSession.shared.data(from: baseURL.appending(path: "health"))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PilotAPIError(statusCode: -1, message: "The KCP server did not return a healthy response.")
        }
    }

    func listGroups() async throws -> [UserGroupSummary] {
        let response: GroupsResponse = try await send(
            path: "v1/groups",
            method: "GET",
            body: Optional<String>.none
        )
        return response.groups
    }

    func createGroup(_ payload: CreateGroupPayload) async throws -> GroupWorkspace {
        try await send(path: "v1/groups", method: "POST", body: payload)
    }

    func workspace(groupCode: String) async throws -> GroupWorkspace {
        try await send(path: "v1/groups/\(encoded(groupCode))/workspace", method: "GET", body: Optional<String>.none)
    }

    func snapshot(groupCode: String) async throws -> AppSnapshot? {
        var request = URLRequest(url: baseURL.appending(path: "v1/groups/\(encoded(groupCode))/snapshot"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(parentName, forHTTPHeaderField: "X-KCP-Parent")
        request.setValue(phone, forHTTPHeaderField: "X-KCP-Phone")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PilotAPIError(statusCode: -1, message: "The KCP server returned an invalid response.")
        }
        if http.statusCode == 404 { return nil }
        guard 200..<300 ~= http.statusCode else {
            throw PilotAPIError(
                statusCode: http.statusCode,
                message: errorMessage(from: data, fallback: "KCP server error \(http.statusCode).")
            )
        }
        return try JSONDecoder.kcp.decode(AppSnapshot.self, from: data)
    }

    func saveSnapshot(groupCode: String, snapshot: AppSnapshot) async throws {
        struct SaveResponse: Codable { let status: String }
        let _: SaveResponse = try await send(
            path: "v1/groups/\(encoded(groupCode))/snapshot",
            method: "PUT",
            body: snapshot
        )
    }

    func createInvitation(groupCode: String, payload: CreateInvitationPayload) async throws -> InvitationResponse {
        try await send(path: "v1/groups/\(encoded(groupCode))/invitations", method: "POST", body: payload)
    }

    func acceptInvitation(token: String, payload: AcceptInvitationPayload) async throws -> GroupWorkspace {
        try await send(path: "v1/invitations/\(encoded(token))/accept", method: "POST", body: payload)
    }

    func submitConstraintRequest(groupCode: String, payload: ConstraintRequestPayload) async throws -> ConstraintResponse {
        try await send(path: "v1/groups/\(encoded(groupCode))/constraint-requests", method: "POST", body: payload)
    }

    func reviewConstraintRequest(
        groupCode: String,
        requestID: UUID,
        payload: ConstraintReviewPayload
    ) async throws -> ConstraintResponse {
        try await send(
            path: "v1/groups/\(encoded(groupCode))/constraint-requests/\(requestID.uuidString)/review",
            method: "POST",
            body: payload
        )
    }

    func updateMemberRole(groupCode: String, parentName: String, payload: MemberRolePayload) async throws -> GroupWorkspace {
        try await send(
            path: "v1/groups/\(encoded(groupCode))/members/\(encoded(parentName))/role",
            method: "PATCH",
            body: payload
        )
    }

    func uploadCalendar(groupCode: String, payload: CalendarUploadPayload) async throws -> CalendarUploadResponse {
        try await send(path: "v1/groups/\(encoded(groupCode))/calendar", method: "POST", body: payload)
    }


    func appendAudit(groupCode: String, payload: AuditAppendPayload) async throws {
        struct Response: Codable { let status: String }
        let _: Response = try await send(
            path: "v1/groups/\(encoded(groupCode))/audit",
            method: "POST",
            body: payload
        )
    }

    func createScheduleRevision(groupCode: String, reason: String) async throws -> ScheduleRevision {
        struct Payload: Codable { let reason: String }
        let response: ScheduleRevisionResponse = try await send(
            path: "v1/groups/\(encoded(groupCode))/schedule-versions",
            method: "POST",
            body: Payload(reason: reason)
        )
        return response.scheduleVersion
    }

    private func send<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body?
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(parentName, forHTTPHeaderField: "X-KCP-Parent")
        request.setValue(phone, forHTTPHeaderField: "X-KCP-Phone")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder.kcp.encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PilotAPIError(statusCode: -1, message: "The KCP server returned an invalid response.")
        }
        guard 200..<300 ~= http.statusCode else {
            throw PilotAPIError(
                statusCode: http.statusCode,
                message: errorMessage(from: data, fallback: "KCP server error \(http.statusCode).")
            )
        }

        do {
            return try JSONDecoder.kcp.decode(Response.self, from: data)
        } catch {
            throw PilotAPIError(
                statusCode: http.statusCode,
                message: "The server response could not be read: \(error.localizedDescription)"
            )
        }
    }

    private func errorMessage(from data: Data, fallback: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return fallback }
        if let detail = object["detail"] as? String { return detail }
        if let detail = object["detail"] as? [String: Any] {
            return (detail["message"] as? String) ?? fallback
        }
        return (object["message"] as? String) ?? fallback
    }

    private func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

extension JSONEncoder {
    static var kcp: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var kcp: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }

            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) { return date }

            let dateOnly = DateFormatter()
            dateOnly.locale = Locale(identifier: "en_US_POSIX")
            dateOnly.dateFormat = "yyyy-MM-dd"
            dateOnly.timeZone = SchoolCalendarData.phoenixTimeZone
            if let date = dateOnly.date(from: value) { return date }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(value)")
        }
        return decoder
    }
}
