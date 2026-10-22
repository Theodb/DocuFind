import AppKit
import SwiftUI

/// Opens the custom About window from the app menu.
struct AboutButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About DocuFind") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "about")
        }
    }
}

/// The About window: the icon and the pixel wordmark over the launch screen's painted glow.
struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Version \(info?["CFBundleShortVersionString"] as? String ?? "–") (\(info?["CFBundleVersion"] as? String ?? "–"))"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            DocuFindBanner(width: 260)
                .accessibilityLabel("DocuFind")
            Text(version).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            Text("Find anything on your Mac by describing it")
                .font(.system(size: 13))
            Text("© 2026 Théo Deschamps-Berger · MIT License")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 48).padding(.top, 36).padding(.bottom, 30)
        .frame(width: 380)
        .background(AboutBackdrop())
    }
}

private struct AboutBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            // The seed keeps the app's earlier name, so the artwork stays the same.
            PaintedCoverView(key: "magnifind-about-glow", palette: .aura)
                .clipShape(Circle())
                .scaleEffect(1.1)
                .blur(radius: 50)
                .opacity(0.45)
        }
        .ignoresSafeArea()
    }
}

/// The About page in the main window: who made the app, the BidirLM model behind it, and how that model scores
/// on the public embedding leaderboards.
struct AboutPage: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Version \(info?["CFBundleShortVersionString"] as? String ?? "–") (\(info?["CFBundleVersion"] as? String ?? "–"))"
    }

    var body: some View {
        SettingsPage(title: "About", subtitle: "Find anything on your Mac by describing it.") {
            SettingsSection("DocuFind") {
                SettingsSurface {
                    HStack(spacing: 18) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 6) {
                            DocuFindBanner(width: 180).accessibilityLabel("DocuFind")
                            Text(version).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                            // Names link to their LinkedIn profiles (Markdown links in a literal Text).
                            Text("Made by [Théo Deschamps-Berger](https://www.linkedin.com/in/theodb). Free and open source under the MIT License.")
                                .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                            link("Source code on GitHub", "https://github.com/Theodb/DocuFind")
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(18)
                }
            }
            SettingsSection("The search model") {
                SettingsSurface {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("BidirLM-Omni-2.5B-Embedding").font(.system(size: 14, weight: .semibold))
                            Text("BidirLM at Diabolocom Research × CentraleSupélec").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        }
                        Text("An open embedding model that places text, images and audio in one shared space, so a few words can find a photo or a recording. Released by [Nicolas Boizard](https://www.linkedin.com/in/nicolas-boizard/), [Théo Deschamps-Berger](https://www.linkedin.com/in/theodb), Hippolyte Gisserot-Boukhlef, Céline Hudelot and Pierre Colombo.")
                            .font(.system(size: 12.5)).foregroundStyle(.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 16) {
                            link("BidirLM on Hugging Face", "https://huggingface.co/BidirLM")
                            link("Paper on arXiv", "https://arxiv.org/abs/2604.02045")
                        }
                        Divider().padding(.vertical, 4)
                        // Kept apart from the model's credits: the conversion is DocuFind's work, not the research team's.
                        Text("For DocuFind, the model was converted to Core ML so it runs on this Mac's Neural Engine, with the same results as the original.")
                            .font(.system(size: 12.5)).foregroundStyle(.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                        link("Core ML version on Hugging Face", "https://huggingface.co/BidirLM/BidirLM-Omni-2.5B-Embedding-CoreML")
                    }
                    .padding(18)
                }
            }
            SettingsSection("Results") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        result("MAEB", "Audio", score: "45.2", standing: "#1", palette: .recordings)
                        result("MIEB", "Images", score: "58.1", standing: "#1 with open training data", palette: .photos)
                        result("MTEB", "Text", score: "63.1", standing: "#2 with open training data", palette: .documents)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Rankings among models under 4B parameters. Scores average all tasks (MTEB Multilingual v2, MIEB lite, MAEB beta), from the paper's snapshot of 30 March 2026.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        link("MTEB leaderboard", "https://huggingface.co/spaces/mteb/leaderboard")
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    private func result(_ benchmark: String, _ kind: String, score: String, standing: String, palette: CoverPalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(MagniSidebar.gradient(palette)).frame(width: 9, height: 9)
                Text("\(kind) (\(benchmark))").font(.system(size: 12, weight: .semibold))
            }
            Text(score).font(.system(size: 30, weight: .semibold)).monospacedDigit()
            Text(standing).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(nsColor: .separatorColor).opacity(0.25)))
        .accessibilityElement(children: .combine)
    }

    private func link(_ title: String, _ address: String) -> some View {
        Link(destination: URL(string: address)!) {
            Label(title, systemImage: "arrow.up.right").labelStyle(TrailingIcon()).font(.system(size: 12, weight: .medium))
        }
    }
}

private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.title; configuration.icon.imageScale(.small) }
    }
}
