import LLMTrayCore
import SwiftUI

/// The download queue in the popover (adr/0013), one compact row while
/// anything waits, runs or failed: the running item with its progress and
/// how many wait; a failed one with Retry.
@MainActor
struct DownloadQueueRow: View {
    @EnvironmentObject private var queue: DownloadQueue

    var body: some View {
        let items = queue.state.items
        let running = queue.state.current
        let waiting = items.filter { $0.status == .pending }.count
        let failed = items.first { if case .failed = $0.status { return true } else { return false } }
        if running != nil || waiting > 0 || failed != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let running {
                    runningRow(running, waiting: waiting)
                } else if waiting > 0 {
                    Text(String(format: NSLocalizedString("Downloads waiting: %lld", comment: "download queue row"), waiting))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let failed, case .failed(let message) = failed.status {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(String(format: NSLocalizedString("%@ didn't download: %@", comment: "download queue row: item, reason"),
                                    DownloadQueue.name(of: failed), message))
                            .font(.caption).lineLimit(2)
                        Spacer()
                        Button("Retry") { queue.retry(failed.id) }.controlSize(.small)
                        Button { queue.dismiss(failed.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).controlSize(.small)
                            .help(Text("Dismiss"))
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
        }
    }

    private func runningRow(_ item: DownloadQueueState.Item, waiting: Int) -> some View {
        let progress: Double? = { if case .running(let p) = item.status { return p } else { return nil } }()
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                Text(String(format: NSLocalizedString("Downloading %@", comment: "download queue row"), DownloadQueue.name(of: item)))
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                if waiting > 0 {
                    Text(String(format: NSLocalizedString("%lld more", comment: "download queue row: items waiting"), waiting))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { queue.cancel(item.id) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help(Text("Cancel this download"))
            }
            if let progress {
                ProgressView(value: progress).controlSize(.small)
            } else {
                ProgressView().progressViewStyle(.linear).controlSize(.small)
            }
            if !queue.detail.isEmpty {
                Text(verbatim: queue.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
