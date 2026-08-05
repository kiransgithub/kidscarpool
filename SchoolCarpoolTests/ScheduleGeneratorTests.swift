import XCTest
@testable import SchoolCarpool

final class ScheduleGeneratorTests: XCTestCase {
    func testScheduleHasTwoTripsPerSchoolDay() {
        let trips = ScheduleGenerator.generate()
        XCTAssertEqual(trips.count, 360)
    }

    func testSantoshNeverGetsMorningDrop() {
        let trips = ScheduleGenerator.generate()
        XCTAssertFalse(trips.contains { $0.kind == .morningDrop && $0.driver == "Santosh" })
    }

    func testNoTripsDuringFallBreak() {
        let calendar = Calendar(identifier: .gregorian)
        let trips = ScheduleGenerator.generate()
        XCTAssertFalse(trips.contains { trip in
            let d = calendar.startOfDay(for: trip.date)
            return d >= calendar.startOfDay(for: SchoolCalendarData.date(2026, 10, 12)) &&
                   d <= calendar.startOfDay(for: SchoolCalendarData.date(2026, 10, 16))
        })
    }

    func testConstraintsAreRespected() {
        let parents = CarpoolStore.seedParents
        let trips = ScheduleGenerator.generate(parents: parents)
        let santoshTrips = trips.filter { $0.driver == "Santosh" }
        XCTAssertTrue(santoshTrips.allSatisfy { $0.kind == .afternoonPickup })
        let weekdays = Set(santoshTrips.map { Calendar(identifier: .gregorian).component(.weekday, from: $0.date) })
        XCTAssertTrue(weekdays.isSubset(of: [3, 5]))
    }

    func testVolunteerCompletionAwardsDoublePoints() {
        let trip = CarpoolTrip(id: UUID(), date: .now, kind: .morningDrop,
                               scheduledDriver: "Kiran", actualDriver: "Mohan",
                               status: .completed, timeLabel: "7:00–7:30 AM", notes: "",
                               childNames: ["Thanishka"], completedAt: .now,
                               startedAt: .now.addingTimeInterval(-600), volunteerAssignment: true)
        XCTAssertEqual(trip.points, 20)
    }

    func testRegularCompletionAwardsTenPoints() {
        let trip = CarpoolTrip(id: UUID(), date: .now, kind: .morningDrop,
                               scheduledDriver: "Kiran", actualDriver: "",
                               status: .completed, timeLabel: "7:00–7:30 AM", notes: "",
                               childNames: ["Thanishka"], completedAt: .now,
                               startedAt: .now.addingTimeInterval(-600), volunteerAssignment: false)
        XCTAssertEqual(trip.points, 10)
    }
    func testAuthoritativeCalendarAnalytics() {
        let analytics = SchoolCalendarData.analytics(
            events: SchoolCalendarData.events,
            now: SchoolCalendarData.date(2026, 8, 3)
        )
        XCTAssertEqual(analytics.instructionalDays, 180)
        XCTAssertEqual(analytics.holidayPeriods, 10)
        XCTAssertEqual(analytics.noSchoolWeekdays, 33)
        XCTAssertEqual(analytics.longWeekends, 9)
        XCTAssertEqual(analytics.earlyPickups, 7)
        XCTAssertEqual(analytics.noLateBirdDays, 2)
        XCTAssertEqual(analytics.projectWeekDays, 5)
        XCTAssertEqual(analytics.longestBreakTitle, "Winter Break")
        XCTAssertEqual(analytics.longestBreakDays, 16)
    }

    func testOwnerAndAdminCanAdministerGroup() {
        XCTAssertTrue(GroupRole.owner.canAdminister)
        XCTAssertTrue(GroupRole.admin.canAdminister)
        XCTAssertFalse(GroupRole.parent.canAdminister)
        XCTAssertFalse(GroupRole.viewer.canAdminister)
    }

    func testScheduleUsesActiveGroupChildren() {
        let parents = [
            ParentProfile(
                id: UUID(), name: "Parent A", childName: "Child A", grade: 3,
                canDriveMorning: true, pickupWeekdays: Set(2...6), dropWeekdays: Set(2...6), notes: nil
            ),
            ParentProfile(
                id: UUID(), name: "Parent B", childName: "Child B", grade: 4,
                canDriveMorning: true, pickupWeekdays: Set(2...6), dropWeekdays: Set(2...6), notes: nil
            )
        ]
        let trips = ScheduleGenerator.generate(parents: parents)
        XCTAssertEqual(Set(trips.first?.childNames ?? []), Set(["Child A", "Child B"]))
    }

    func testUnavailableWeekdayCreatesCoverageGapInsteadOfViolatingConstraint() {
        let mondayOnly = ParentProfile(
            id: UUID(), name: "Monday Parent", childName: "Child", grade: 3,
            canDriveMorning: true, pickupWeekdays: [2], dropWeekdays: [2], notes: nil
        )
        let trips = ScheduleGenerator.generate(parents: [mondayOnly])
        let calendar = Calendar(identifier: .gregorian)
        let tuesdayTrip = trips.first {
            calendar.component(.weekday, from: $0.date) == 3 && $0.kind == .morningDrop
        }
        XCTAssertEqual(tuesdayTrip?.driver, "Unassigned")
    }

}
