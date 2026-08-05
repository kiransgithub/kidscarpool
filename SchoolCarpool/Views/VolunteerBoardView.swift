import SwiftUI

struct VolunteerBoardView: View {
    @Environment(CarpoolStore.self) private var store

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Be a hero. Help a family.", systemImage: "heart.fill")
                        .font(.title2.bold())
                    Text("Volunteer for an open ride and the fairness ledger will credit your completed trip.")
                        .foregroundStyle(.white.opacity(0.86))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.white)
                .padding(20)
                .background(KCPTheme.actionGradient, in: RoundedRectangle(cornerRadius: 24))

                if store.coverRequests.isEmpty {
                    ContentUnavailableView("No cover requests", systemImage: "checkmark.circle.fill", description: Text("Everyone is covered right now."))
                        .kcpCard()
                }

                ForEach(store.coverRequests.sorted { $0.createdAt > $1.createdAt }) { request in
                    if let trip = store.trips.first(where: { $0.id == request.tripID }) {
                        VStack(alignment: .leading, spacing: 14) {
                            TripRow(trip: trip)
                            Divider()
                            LabeledContent("Requested by", value: request.requestedBy)
                            if !request.note.isEmpty {
                                Label(request.note, systemImage: "text.bubble")
                                    .font(.subheadline)
                            }
                            if let acceptedBy = request.acceptedBy {
                                Label("Accepted by \(acceptedBy)", systemImage: "checkmark.seal.fill")
                                    .font(.headline)
                                    .foregroundStyle(KCPTheme.green)
                            } else {
                                Button {
                                    store.acceptCover(request.id)
                                } label: {
                                    Label("Volunteer for this trip", systemImage: "hand.raised.fill")
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(KCPTheme.orange)
                            }
                        }
                        .kcpCard()
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Volunteers")
    }
}
