import AVFoundation
import SwiftUI

/// Records a short clip from the microphone to search with, such as a song
/// playing nearby. Clips are 16 kHz mono WAV in the private data folder; only
/// the newest few are kept, and nothing is recorded outside an explicit request.
@MainActor
final class QueryRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let shared = QueryRecorder()
    /// The model listens in 30-second windows, so a longer clip adds nothing.
    static let maxDuration: Double = 30

    @Published private(set) var isRecording = false
    /// Whether the floating bar started the current recording; hiding the bar only discards its own.
    var startedByQuickBar = false
    @Published private(set) var elapsed: Double = 0
    /// Recent input levels, 0...1, newest last.
    @Published private(set) var levels: [Double] = []
    private var recorder: AVAudioRecorder?
    private var meter: Task<Void, Never>?
    private var onFinish: ((URL) -> Void)?

    func start(onFinish: @escaping (URL) -> Void) async {
        guard !isRecording else { return }
        guard await Self.microphoneAllowed() else {
            AppModel.shared.error = "DocuFind can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone, then try again."
            return
        }
        do {
            let folder = AppModel.shared.dataDirectory.appendingPathComponent("recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            Self.prune(folder)
            let stamp = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            let url = folder.appendingPathComponent("Recording \(stamp.replacingOccurrences(of: ":", with: ".")).wav")
            let next = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ])
            next.delegate = self
            next.isMeteringEnabled = true
            guard next.record(forDuration: Self.maxDuration) else { throw BackendFailure(message: "Recording could not start.") }
            recorder = next
            self.onFinish = onFinish
            PassagePlayer.shared.stop()
            elapsed = 0
            levels = []
            isRecording = true
            meter = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard let self, let recorder = self.recorder, recorder.isRecording else { return }
                    recorder.updateMeters()
                    // -50 dB…0 dB mapped to 0…1.
                    let level = max(0, min(1, (Double(recorder.averagePower(forChannel: 0)) + 50) / 50))
                    self.levels = Array((self.levels + [level]).suffix(48))
                    self.elapsed = recorder.currentTime
                }
            }
        } catch {
            AppModel.shared.error = "Recording could not start: \(error.localizedDescription)"
        }
    }

    /// Stops and searches with what was recorded.
    func stop() { recorder?.stop() }

    /// Stops and discards the clip.
    func cancel() {
        onFinish = nil
        recorder?.stop()
        recorder?.deleteRecording()
    }

    nonisolated func audioRecorderDidFinishRecording(_ finished: AVAudioRecorder, successfully flag: Bool) {
        let url = finished.url
        Task { @MainActor in
            meter?.cancel()
            isRecording = false
            recorder = nil
            let handler = onFinish
            onFinish = nil
            // Ignore taps so short there is nothing to compare.
            if flag, elapsed >= 1, let handler { handler(url) }
            else { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private static func prune(_ folder: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files.compactMap { url in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (url, $0) } }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(4) { try? FileManager.default.removeItem(at: url) }
    }
}

/// Replaces the text field while recording: a pulsing dot, the live input level and the time.
struct RecordingStrip: View {
    @ObservedObject var recorder: QueryRecorder
    let compact: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.red).frame(width: 9, height: 9)
                .opacity(pulse ? 0.35 : 1)
                .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true } }
            Canvas { context, size in
                let count = 48
                let step = size.width / CGFloat(count)
                let levels = recorder.levels
                for index in 0..<count {
                    let source = index - (count - levels.count)
                    let level = source >= 0 ? levels[source] : 0
                    let height = max(3, CGFloat(level) * size.height)
                    let rect = CGRect(x: CGFloat(index) * step + step * 0.2, y: (size.height - height) / 2, width: step * 0.6, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: step * 0.3), with: .color(.primary.opacity(source >= 0 ? 0.75 : 0.15)))
                }
            }
            .frame(height: compact ? 18 : 26)
            Text("\(Self.time(recorder.elapsed)) / \(Self.time(QueryRecorder.maxDuration))")
                .font(.system(size: compact ? 12 : 13, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording, \(Int(recorder.elapsed)) seconds")
    }

    private static func time(_ seconds: Double) -> String { String(format: "0:%02d", Int(seconds)) }
}
