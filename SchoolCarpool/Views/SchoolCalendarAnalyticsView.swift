import SwiftUI
import Foundation
import UniformTypeIdentifiers

struct SchoolCalendarAnalyticsView: View {
    @Environment(CarpoolStore.self) private var store
    @State private var showingCalendarImporter = false

    private var analytics: CalendarAnalytics { store.calendarAnalytics }
    private var events: [SchoolCalendarEvent] {
        store.displayCalendarEvents.sorted { $0.startDate < $1.startDate }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                analyticsGrid
                calendarHighlights
                sourceCard
                upcomingLongWeekends
                eventTimeline
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("School Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refreshGroupWorkspace(showSuccess: false) }
        .fileImporter(
            isPresented: $showingCalendarImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    Task {
                        await store.uploadAuthoritativeCalendar(
                            sourceName: url.lastPathComponent,
                            sourceData: data
                        )
                    }
                } catch {
                    store.alertMessage = "Could not read the selected calendar PDF: \(error.localizedDescription)"
                }
            case .failure(let error):
                store.alertMessage = "Calendar selection failed: \(error.localizedDescription)"
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Authoritative calendar", systemImage: "calendar.badge.checkmark")
                .font(.title2.bold())
            Text(store.activeGroup?.schoolName ?? "BASIS Phoenix Primary")
                .font(.headline)
            Text(store.activeGroup?.academicYear ?? "2026–27")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .foregroundStyle(.white)
        .background(KCPTheme.heroGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: KCPTheme.navy.opacity(0.18), radius: 14, y: 7)
    }

    private var analyticsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metric("School days", value: "\(analytics.instructionalDays)", icon: "building.2.fill", color: KCPTheme.blue)
            metric("Holiday periods", value: "\(analytics.holidayPeriods)", icon: "calendar.badge.minus", color: KCPTheme.orange)
            metric("Long weekends", value: "\(analytics.longWeekends)", icon: "sun.max.fill", color: KCPTheme.green)
            metric("Still upcoming", value: "\(analytics.upcomingLongWeekends)", icon: "forward.fill", color: KCPTheme.cyan)
            metric("Early pickups", value: "\(analytics.earlyPickups)", icon: "clock.badge.exclamationmark", color: KCPTheme.violet)
            metric("No Late Bird", value: "\(analytics.noLateBirdDays)", icon: "person.crop.circle.badge.exclamationmark", color: KCPTheme.red)
            metric("No-school weekdays", value: "\(analytics.noSchoolWeekdays)", icon: "calendar.day.timeline.left", color: KCPTheme.orange)
            metric("Project Week days", value: "\(analytics.projectWeekDays)", icon: "hammer.fill", color: KCPTheme.blue)
        }
    }

    private func metric(_ title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.title3.bold()).foregroundStyle(color)
            Text(value).font(.system(size: 28, weight: .black, design: .rounded))
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        .kcpCard()
    }

    private var calendarHighlights: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Calendar highlights", systemImage: "sparkles")
                .font(.headline)

            if store.calendarRegistration == nil {
                Text("Upload the authoritative calendar to calculate the next event, longest break and coverage impact.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("NEXT EVENT")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        Text(analytics.nextEventTitle ?? "Academic year complete")
                            .font(.subheadline.bold())
                        if let date = analytics.nextEventDate {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(KCPTheme.blue)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider().frame(height: 58)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("LONGEST BREAK")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        Text(analytics.longestBreakTitle ?? "None")
                            .font(.subheadline.bold())
                        Text("\(analytics.longestBreakDays) calendar days")
                            .font(.caption)
                            .foregroundStyle(KCPTheme.orange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .kcpCard()
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Calendar source").font(.headline)
                Spacer()
                if store.calendarRegistration != nil {
                    Label("Active", systemImage: "checkmark.seal.fill")
                        .font(.caption.bold()).foregroundStyle(KCPTheme.green)
                }
            }

            if let registration = store.calendarRegistration {
                LabeledContent("Uploaded by", value: registration.uploadedBy)
                LabeledContent("Source", value: registration.sourceName)
                LabeledContent("Events", value: "\(registration.eventCount ?? events.count)")
                if let bytes = registration.sourceFileSize {
                    LabeledContent("Stored PDF", value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                }
                if let fingerprint = registration.sourceSHA256, !fingerprint.isEmpty {
                    LabeledContent("Fingerprint", value: String(fingerprint.prefix(12)) + "…")
                }
                Text("Holiday schedule is already uploaded and considered in the carpool schedule. Duplicate uploads by another parent are rejected by the database.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if store.isCurrentUserAdmin {
                Button("Select and upload calendar PDF") {
                    showingCalendarImporter = true
                }
                .buttonStyle(.borderedProminent)
                .tint(KCPTheme.blue)
                Text("The pilot stores the PDF, file size and SHA-256 fingerprint with the parsed school dates for audit purposes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("An owner or admin must upload the authoritative school calendar.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .kcpCard()
    }

    private var upcomingLongWeekends: some View {
        let longWeekends = SchoolCalendarData.upcomingLongWeekendEvents(events: events)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Upcoming long weekends", systemImage: "sun.horizon.fill")
                    .font(.headline)
                Spacer()
                Text("\(longWeekends.count)").font(.caption.bold()).foregroundStyle(.secondary)
            }
            if longWeekends.isEmpty {
                Text("No long weekends remain in this academic year.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(longWeekends.prefix(5)) { event in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "calendar.badge.minus")
                            .foregroundStyle(KCPTheme.green)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title).font(.subheadline.bold())
                            Text(event.dateRangeLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if event.id != longWeekends.prefix(5).last?.id { Divider() }
                }
            }
        }
        .kcpCard()
    }

    private var eventTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Published dates", systemImage: "list.bullet.rectangle.portrait.fill")
                .font(.headline)

            if events.isEmpty {
                Text("No calendar has been published for this group yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach(events) { event in
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(eventColor(event.type).opacity(0.12))
                        Image(systemName: event.type.symbol)
                            .foregroundStyle(eventColor(event.type))
                    }
                    .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(event.title).font(.subheadline.bold())
                            Spacer()
                            Text(event.type.displayName)
                                .font(.caption2.bold())
                                .foregroundStyle(eventColor(event.type))
                        }
                        Text(event.dateRangeLabel).font(.caption).foregroundStyle(.secondary)
                        if !event.notes.isEmpty {
                            Text(event.notes).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 3)
                if event.id != events.last?.id { Divider() }
            }
        }
        .kcpCard()
    }

    private func eventColor(_ type: SchoolCalendarEventType) -> Color {
        switch type {
        case .noSchool: return KCPTheme.orange
        case .earlyRelease: return KCPTheme.violet
        case .noLateBird: return KCPTheme.red
        case .projectWeek: return KCPTheme.blue
        case .firstDay, .lastDay: return KCPTheme.green
        }
    }
}
