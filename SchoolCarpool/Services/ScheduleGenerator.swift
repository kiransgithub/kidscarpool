import Foundation

enum ScheduleGenerator {
    static let defaultChildren = ["Thanishka", "Saanvi", "Ishi", "Kavish"]

    static func generate(parents: [ParentProfile] = CarpoolStore.seedParents) -> [CarpoolTrip] {
        var result: [CarpoolTrip] = []
        var day = SchoolCalendarData.schoolStart
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = SchoolCalendarData.phoenixTimeZone
        let groupChildren = parents.map(\.childName).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let children = groupChildren.isEmpty ? defaultChildren : groupChildren
        var assignedCounts: [String: Int] = Dictionary(uniqueKeysWithValues: parents.map { ($0.name, 0) })

        while day <= SchoolCalendarData.schoolEnd {
            defer { day = calendar.date(byAdding: .day, value: 1, to: day)! }
            guard SchoolCalendarData.isSchoolDay(day, calendar: calendar) else { continue }

            let weekday = calendar.component(.weekday, from: day)
            let morning = chooseDriver(parents: parents, weekday: weekday, kind: .morningDrop, counts: assignedCounts)
            assignedCounts[morning, default: 0] += 1
            let afternoon = chooseDriver(parents: parents, weekday: weekday, kind: .afternoonPickup, counts: assignedCounts)
            assignedCounts[afternoon, default: 0] += 1

            let note = SchoolCalendarData.earlyRelease.first(where: { calendar.isDate($0.key, inSameDayAs: day) })?.value ?? ""
            let pickupTime = note.isEmpty ? "3:35–3:45 PM" : "Confirm early-release time"
            result.append(CarpoolTrip(id: deterministicID(day: day, kind: .morningDrop), date: day, kind: .morningDrop,
                                      scheduledDriver: morning, actualDriver: "", status: morning == "Unassigned" ? .coverRequested : .scheduled,
                                      timeLabel: "7:00–7:30 AM", notes: note, childNames: children,
                                      completedAt: nil, startedAt: nil, volunteerAssignment: false))
            result.append(CarpoolTrip(id: deterministicID(day: day, kind: .afternoonPickup), date: day, kind: .afternoonPickup,
                                      scheduledDriver: afternoon, actualDriver: "", status: afternoon == "Unassigned" ? .coverRequested : .scheduled,
                                      timeLabel: pickupTime, notes: note, childNames: children,
                                      completedAt: nil, startedAt: nil, volunteerAssignment: false))
        }
        return result
    }

    private static func chooseDriver(parents: [ParentProfile], weekday: Int, kind: TripKind,
                                     counts: [String: Int]) -> String {
        let eligible = parents.filter { parent in
            switch kind {
            case .morningDrop: return parent.effectiveDropWeekdays.contains(weekday)
            case .afternoonPickup: return parent.pickupWeekdays.contains(weekday)
            }
        }
        guard !eligible.isEmpty else { return "Unassigned" }
        return eligible.min {
            let left = counts[$0.name, default: 0]
            let right = counts[$1.name, default: 0]
            return left == right ? $0.name < $1.name : left < right
        }?.name ?? "Unassigned"
    }

    private static func deterministicID(day: Date, kind: TripKind) -> UUID {
        let value = Int(day.timeIntervalSince1970 / 86_400)
        let suffix = kind == .morningDrop ? 1 : 2
        let raw = String(format: "00000000-0000-4000-8000-%012d", value * 10 + suffix)
        return UUID(uuidString: raw) ?? UUID()
    }
}
