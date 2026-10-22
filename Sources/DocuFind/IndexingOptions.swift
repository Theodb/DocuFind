import SwiftUI

/// Library options that decide which files are read, and in what order.
struct IndexingOptionsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsSection("Indexing") {
            SettingsSurface {
                row("Skip machine-made files",
                    detail: "Downloaded models, test fixtures and tokenizer vocabularies such as merges.txt.",
                    key: "skipMachineFiles")
                SettingsDivider()
                row("Read only the start of very long text files",
                    detail: "Logs and dumps stop after about 360,000 characters. PDFs are always read in full.",
                    key: "limitLongFiles")
                SettingsDivider()
                row("Index important files first",
                    detail: "Your Desktop, Documents and recent files come before output, cache and log folders.",
                    key: "importantFirst")
            }
            if let summary = skippedSummary { SettingsNote(summary) }
        }
    }

    private func row(_ title: String, detail: String, key: String) -> some View {
        SettingsRow(title, detail: detail, isOn: Binding(get: { model.indexingOptions[key] ?? true },
                                                        set: { value in Task { await model.setIndexingOption(key, value) } }))
            .disabled(model.indexing || !model.connected)
    }

    /// "The last update skipped 1,234 machine-made files: 1,200 in model folders, 34 tokenizer files."
    private var skippedSummary: String? {
        let counts = model.autoSkipped.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        guard !counts.isEmpty else { return nil }
        let total = counts.reduce(0) { $0 + $1.value }
        let parts = counts.map { reason, count in
            reason == "tokenizer files" ? "\(count.formatted()) tokenizer files" : "\(count.formatted()) in \(reason)"
        }
        return "The last update skipped \(total.formatted()) machine-made files: " + parts.joined(separator: ", ") + "."
    }
}

extension AppModel {
    func setIndexingOption(_ key: String, _ value: Bool) async {
        guard !indexing else { return }
        indexingOptions[key] = value
        UserDefaults.standard.set(indexingOptions, forKey: "indexingOptions")
        do { applyStatus(try await client.request("configure", configureArguments)) }
        catch { self.error = error.localizedDescription }
        await loadRecent()
    }
}
