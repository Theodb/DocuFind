import SwiftUI

/// The parts of setup, each with its own bar: the runtime's packages, the search model's download, then its
/// one-time preparation for this Mac's Neural Engine.
struct SetupProgressView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(title: "Runtime", icon: "arrow.down.circle", done: model.dependenciesReady, fraction: model.runtimeProgress ?? 0,
                detail: model.dependenciesReady ? "Installed" : (model.runtimeStep.isEmpty ? "Waiting to start…" : model.runtimeStep))
            row(title: "Search model", icon: "arrow.down.circle", done: model.modelDownloaded, fraction: model.modelDownload?.fraction ?? 0,
                detail: model.modelDownloaded ? "Downloaded" : model.modelDownload?.detail() ?? "Starts in a moment…")
            // Redrawn twice a second: the bar fills within each step from the pace the backend reported.
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                row(title: "Optimizing for your Mac's chip", icon: "cpu", done: model.modelPrepared,
                    fraction: model.modelPreparation?.fraction(at: context.date) ?? 0, detail: preparationDetail)
            }
        }
    }

    /// In plain words, one message per part as the backend reports it ("text", "photos", "recordings", "checking it").
    private var preparationDetail: String {
        if model.modelPrepared { return "Ready" }
        guard model.modelDownloaded else { return "After the download" }
        guard model.modelPreparation != nil else { return "Starts in a moment…" }
        switch model.modelPreparationPart {
        case "text": return "Now: document search. A few minutes in all, only this once."
        case "photos": return "Now: photo search, for the Neural Engine in your Mac's chip."
        case "recordings": return "Now: recording search, almost there."
        case "checking it": return "Last: checking results match the original model."
        default: return "Tuning the search model for the Neural Engine in your Mac's chip."
        }
    }

    private func row(title: String, icon: String, done: Bool, fraction: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: done ? "checkmark.circle.fill" : icon)
                    .foregroundStyle(done ? Color.green : Color.secondary)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if !done { Text("\(Int(fraction * 100))%").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit() }
            }
            ProgressView(value: done ? 1 : fraction).progressViewStyle(.linear)
                .animation(.easeOut(duration: 0.3), value: fraction)
            Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "Done" : "\(Int(fraction * 100)) percent, \(detail)")
    }
}
