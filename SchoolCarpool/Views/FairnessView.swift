import SwiftUI
import Charts

struct FairnessView: View {
    @Environment(CarpoolStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("KCP Points Leaderboard", systemImage: "trophy.fill")
                        .font(.title2.bold()).foregroundStyle(KCPTheme.orange)
                    Text("A completed scheduled drop or pickup earns 10 points. Completing an additional volunteer trip earns 20 points.")
                        .foregroundStyle(.secondary)
                    Chart(store.leaderboard) { row in
                        BarMark(x: .value("Points", row.points), y: .value("Parent", row.parentName))
                            .foregroundStyle(KCPTheme.parentColor(row.parentName).gradient)
                            .cornerRadius(6)
                    }
                    .frame(height: 230)
                }
                .kcpCard()

                ForEach(Array(store.leaderboard.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill(index == 0 ? KCPTheme.orange.opacity(0.18) : KCPTheme.blue.opacity(0.10))
                            Text("\(index + 1)").font(.headline.bold())
                        }
                        .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.parentName).font(.headline)
                            Text("\(row.scheduledCompleted) regular • \(row.volunteerCompleted) volunteer")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("\(row.points)").font(.title2.bold()).foregroundStyle(KCPTheme.parentColor(row.parentName))
                            Text("points").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .kcpCard()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Fairness still matters", systemImage: "scale.3d")
                        .font(.headline).foregroundStyle(KCPTheme.violet)
                    Text("The leaderboard motivates participation, while the trip counter remains the source of truth for balancing the schedule. Points do not erase missed responsibilities.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .kcpCard()
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Leaderboard")
    }
}
