import QuickLook
import SwiftUI

struct DownloadsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var preview: URL?

    var body: some View {
        let store = env.downloads
        List {
            ForEach(store.records) { record in
                DownloadRow(
                    record: record, canRetry: store.canRetry(record.id),
                    open: { preview = store.fileURL(of: record) },
                    cancel: {
                        env.haptics.fire(.settingsChange)
                        store.cancel(record.id)
                    },
                    retry: {
                        env.haptics.fire(.settingsChange)
                        store.retry(record.id)
                    })
            }
            .onDelete { offsets in
                for id in offsets.map({ store.records[$0].id }) {
                    env.haptics.fire(.archiveDelete)
                    store.delete(id)
                }
            }
        }
        .overlay {
            if store.records.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle")
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($preview)
        .sheetDoneButton()
    }
}

private struct DownloadRow: View {
    let record: DownloadRecord
    let canRetry: Bool
    let open: () -> Void
    let cancel: () -> Void
    let retry: () -> Void

    var body: some View {
        HStack {
            // Only a finished file opens; a running or failed row answers through its own button.
            Button {
                if record.state == .finished {
                    open()
                }
            } label: {
                HStack {
                    Image(systemName: "doc")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .frame(width: Theme.Metrics.downloadIcon, height: Theme.Metrics.downloadIcon)
                    VStack(alignment: .leading) {
                        Text(record.filename)
                            .font(Theme.Typography.downloadTitle)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        detail
                    }
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .tint(.primary)
            switch record.state {
            case .running:
                Button("Cancel", systemImage: "xmark.circle.fill", action: cancel)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .tint(.secondary)
            case .failed where canRetry:
                Button("Retry", systemImage: "arrow.clockwise.circle.fill", action: retry)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            case .failed, .finished:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var detail: some View {
        let host = record.sourceURL?.host() ?? ""
        switch record.state {
        case .running:
            if record.total > 0 {
                ProgressView(value: Double(record.bytes), total: Double(max(record.total, record.bytes)))
            }
            Text(progressText)
                .font(Theme.Typography.downloadDetail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .finished:
            Text("\(record.bytes.formatted(.byteCount(style: .file))) \u{00B7} \(host)")
                .font(Theme.Typography.downloadDetail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .failed:
            Text("Failed \u{00B7} \(host)")
                .font(Theme.Typography.downloadDetail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var progressText: String {
        let bytes = record.bytes.formatted(.byteCount(style: .file))
        guard record.total > 0 else { return bytes }
        return "\(bytes) of \(record.total.formatted(.byteCount(style: .file)))"
    }
}
