import SwiftUI

/// Lists tunnel changes and what the app did, newest first.
struct HistoryView: View {
    @EnvironmentObject private var state: GuardState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History")
                    .font(.headline)
                Text("last \(ActivityLog.defaultLimit) events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { state.clearActivity() }
                    .disabled(state.activity.entries.isEmpty)
            }
            .padding(12)

            Divider()

            if state.activity.entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text("Nothing yet")
                        .font(.callout.weight(.medium))
                    Text("Tunnel changes and fixes show up here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(state.activity.newestFirst) { entry in
                    HistoryRow(entry: entry)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 480, height: 420)
    }
}

private struct HistoryRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.kind.symbolName)
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .font(.callout)
                    .textSelection(.enabled)
                Text(entry.date.formatted(date: .abbreviated, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch entry.kind {
        case .tunnel: return .blue
        case .status: return .secondary
        case .action: return .green
        case .problem: return .orange
        }
    }
}
