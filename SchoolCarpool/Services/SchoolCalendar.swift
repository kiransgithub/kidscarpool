import Foundation

enum SchoolCalendarData {
    static let phoenixTimeZone = TimeZone(identifier: "America/Phoenix")!
    static let schoolStart = date(2026, 8, 5)
    static let schoolEnd = date(2027, 5, 28)

    static let events: [SchoolCalendarEvent] = [
        event(1, .firstDay, "First Day of School", 2026, 8, 5),
        event(2, .noSchool, "Labor Day Break", 2026, 9, 7),
        event(3, .earlyRelease, "Professional Development", 2026, 9, 25,
              notes: "Confirm the exact dismissal time before assigning pickup."),
        event(4, .earlyRelease, "Parent/Teacher Conferences", 2026, 10, 7,
              notes: "Confirm the exact dismissal time before assigning pickup."),
        event(5, .noSchool, "Fall Break", 2026, 10, 12, endYear: 2026, endMonth: 10, endDay: 16),
        event(6, .noSchool, "Veterans Day", 2026, 11, 11),
        event(7, .noSchool, "Thanksgiving Break", 2026, 11, 25, endYear: 2026, endMonth: 11, endDay: 30),
        event(8, .noLateBird, "Winter Break Early Release", 2026, 12, 18,
              notes: "Early release and no Late Bird. Confirm alternate coverage for the first-grade child."),
        event(9, .noSchool, "Winter Break", 2026, 12, 21, endYear: 2027, endMonth: 1, endDay: 1),
        event(10, .noSchool, "MLK Day", 2027, 1, 18),
        event(11, .earlyRelease, "Professional Development", 2027, 2, 12,
              notes: "Confirm the exact dismissal time before assigning pickup."),
        event(12, .noSchool, "Presidents Day", 2027, 2, 15),
        event(13, .noSchool, "February Break", 2027, 2, 22, endYear: 2027, endMonth: 2, endDay: 24),
        event(14, .earlyRelease, "Parent/Teacher Conferences", 2027, 3, 10,
              notes: "Confirm the exact dismissal time before assigning pickup."),
        event(15, .noSchool, "Spring Break", 2027, 3, 15, endYear: 2027, endMonth: 3, endDay: 19),
        event(16, .earlyRelease, "Professional Development", 2027, 4, 1,
              notes: "Confirm the exact dismissal time before assigning pickup."),
        event(17, .noSchool, "April Break", 2027, 4, 2, endYear: 2027, endMonth: 4, endDay: 5),
        event(18, .projectWeek, "Project Week", 2027, 5, 24, endYear: 2027, endMonth: 5, endDay: 28),
        event(19, .lastDay, "Last Day of School", 2027, 5, 28,
              notes: "Early release and no Late Bird. Confirm the exact dismissal time."),
    ]

    static var noSchoolRanges: [ClosedRange<Date>] {
        events.filter { $0.type == .noSchool }.map { $0.startDate...$0.endDate }
    }

    static var earlyRelease: [Date: String] {
        Dictionary(uniqueKeysWithValues: events.filter { $0.type == .earlyRelease || $0.type == .noLateBird || $0.type == .lastDay }.map { event in
            (event.startDate, event.notes.isEmpty ? event.title : "\(event.title) — \(event.notes)")
        })
    }

    static func isSchoolDay(_ date: Date, calendar: Calendar = phoenixCalendar) -> Bool {
        let day = calendar.startOfDay(for: date)
        guard day >= calendar.startOfDay(for: schoolStart), day <= calendar.startOfDay(for: schoolEnd) else { return false }
        guard !calendar.isDateInWeekend(day) else { return false }
        return !noSchoolRanges.contains { range in
            day >= calendar.startOfDay(for: range.lowerBound) && day <= calendar.startOfDay(for: range.upperBound)
        }
    }

    static func analytics(events: [SchoolCalendarEvent] = events, now: Date = .now) -> CalendarAnalytics {
        let calendar = phoenixCalendar
        let closures = events.filter { $0.type == .noSchool }.sorted { $0.startDate < $1.startDate }
        let schoolDays = countDates(from: schoolStart, through: schoolEnd) { isSchoolDay($0, calendar: calendar) }
        let noSchoolWeekdays = closures.reduce(0) { total, event in
            total + countDates(from: event.startDate, through: event.endDate) { !calendar.isDateInWeekend($0) }
        }
        let longWeekendEvents = closures.filter { extendedBreakDays(for: $0, calendar: calendar) >= 3 }
        let upcomingLongWeekends = longWeekendEvents.filter {
            extendedBreakEnd(for: $0, calendar: calendar) >= calendar.startOfDay(for: now)
        }
        let upcomingEvents = events.filter { $0.endDate >= calendar.startOfDay(for: now) }
            .sorted { $0.startDate < $1.startDate }
        let longest = closures.max {
            extendedBreakDays(for: $0, calendar: calendar) < extendedBreakDays(for: $1, calendar: calendar)
        }
        let projectWeekDays = events.filter { $0.type == .projectWeek }.reduce(0) { total, event in
            total + countDates(from: event.startDate, through: event.endDate) { !calendar.isDateInWeekend($0) }
        }

        return CalendarAnalytics(
            instructionalDays: schoolDays,
            holidayPeriods: closures.count,
            noSchoolWeekdays: noSchoolWeekdays,
            longWeekends: longWeekendEvents.count,
            upcomingLongWeekends: upcomingLongWeekends.count,
            earlyPickups: events.filter { $0.type == .earlyRelease || $0.type == .noLateBird || $0.type == .lastDay }.count,
            noLateBirdDays: events.filter { $0.type == .noLateBird || $0.type == .lastDay }.count,
            projectWeekDays: projectWeekDays,
            longestBreakDays: longest.map { extendedBreakDays(for: $0, calendar: calendar) } ?? 0,
            longestBreakTitle: longest?.title,
            upcomingEventCount: upcomingEvents.count,
            nextEventTitle: upcomingEvents.first?.title,
            nextEventDate: upcomingEvents.first?.startDate
        )
    }

    static func upcomingLongWeekendEvents(events: [SchoolCalendarEvent] = events, now: Date = .now) -> [SchoolCalendarEvent] {
        events
            .filter { $0.type == .noSchool }
            .filter { extendedBreakDays(for: $0, calendar: phoenixCalendar) >= 3 }
            .filter { extendedBreakEnd(for: $0, calendar: phoenixCalendar) >= phoenixCalendar.startOfDay(for: now) }
            .sorted { $0.startDate < $1.startDate }
    }

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.calendar = phoenixCalendar
        components.timeZone = phoenixTimeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return components.date!
    }

    private static var phoenixCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = phoenixTimeZone
        return calendar
    }

    private static func event(
        _ index: Int,
        _ type: SchoolCalendarEventType,
        _ title: String,
        _ year: Int,
        _ month: Int,
        _ day: Int,
        endYear: Int? = nil,
        endMonth: Int? = nil,
        endDay: Int? = nil,
        notes: String = ""
    ) -> SchoolCalendarEvent {
        SchoolCalendarEvent(
            id: UUID(uuidString: String(format: "10000000-0000-4000-8000-%012d", index))!,
            type: type,
            title: title,
            startDate: date(year, month, day),
            endDate: date(endYear ?? year, endMonth ?? month, endDay ?? day),
            notes: notes
        )
    }

    private static func countDates(from start: Date, through end: Date, where predicate: (Date) -> Bool) -> Int {
        var count = 0
        var day = phoenixCalendar.startOfDay(for: start)
        let last = phoenixCalendar.startOfDay(for: end)
        while day <= last {
            if predicate(day) { count += 1 }
            day = phoenixCalendar.date(byAdding: .day, value: 1, to: day)!
        }
        return count
    }

    private static func extendedBreakStart(for event: SchoolCalendarEvent, calendar: Calendar) -> Date {
        var day = calendar.startOfDay(for: event.startDate)
        while let previous = calendar.date(byAdding: .day, value: -1, to: day), calendar.isDateInWeekend(previous) {
            day = previous
        }
        return day
    }

    private static func extendedBreakEnd(for event: SchoolCalendarEvent, calendar: Calendar) -> Date {
        var day = calendar.startOfDay(for: event.endDate)
        while let next = calendar.date(byAdding: .day, value: 1, to: day), calendar.isDateInWeekend(next) {
            day = next
        }
        return day
    }

    private static func extendedBreakDays(for event: SchoolCalendarEvent, calendar: Calendar) -> Int {
        let start = extendedBreakStart(for: event, calendar: calendar)
        let end = extendedBreakEnd(for: event, calendar: calendar)
        return (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
    }
}
