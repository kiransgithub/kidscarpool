import SwiftUI

struct ScheduleView: View {
    @Environment(CarpoolStore.self) private var store
    @State private var onlyMine = false

    private var displayed: [CarpoolTrip] {
        store.trips.filter { !onlyMine || $0.driver == store.currentParentName }
    }

    private var grouped: [(Date, [CarpoolTrip])] {
        let groups = Dictionary(grouping: displayed) { Calendar.current.startOfDay(for: $0.date) }
        return groups.keys.sorted().map { ($0, groups[$0]!.sorted { $0.kind.rawValue < $1.kind.rawValue }) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14, pinnedViews: [.sectionHeaders]) {
                Toggle(isOn: $onlyMine) {
                    Label("Only my assignments", systemImage: "person.crop.circle")
                        .font(.headline)
                }
                .padding(16)
                .background(.background, in: RoundedRectangle(cornerRadius: 18))

                ForEach(grouped, id: \.0) { day, trips in
                    Section {
                        ForEach(trips) { trip in
                            NavigationLink(value: trip.id) { TripRow(trip: trip) }
                                .buttonStyle(.plain)
                        }
                    } header: {
                        Text(day.formatted(date: .complete, time: .omitted))
                            .font(.subheadline.bold())
                            .foregroundStyle(KCPTheme.navy)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .background(Color(.systemGroupedBackground))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Schedule")
        .navigationDestination(for: UUID.self) { id in TripDetailView(tripID: id) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SchoolCalendarAnalyticsView() } label: {
                    Image(systemName: "calendar.badge.checkmark")
                }
                .accessibilityLabel("School calendar and analytics")
            }
        }
    }
}
