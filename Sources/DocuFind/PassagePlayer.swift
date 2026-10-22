import AVFoundation
import SwiftUI

/// A recording's loudness outline and matched passage. The worker decodes the file,
/// so the outline is available for every indexed format.
struct AudioPreview: Sendable {
    let duration: Double
    let peaks: [Double]
    /// A decoded copy of the audio; only present when it was requested.
    let clip: URL?
    let clipStart: Double
    let clipEnd: Double
}

extension AppModel {
    func audioPreview(path: String, start: Double, end: Double, clip: Bool = false) async throws -> AudioPreview {
        let response = try await client.request("audio_preview", ["path": path, "start": start, "end": end, "bins": 44, "clip": clip])
        guard let duration = response["duration"] as? Double, let peaks = response["peaks"] as? [Double] else {
            throw BackendFailure(message: "The recording preview could not be prepared.")
        }
        return AudioPreview(duration: duration, peaks: peaks, clip: (response["clip"] as? String).map(URL.init(fileURLWithPath:)),
                            clipStart: response["clipStart"] as? Double ?? start, clipEnd: response["clipEnd"] as? Double ?? end)
    }
}

/// Plays one recording at a time with AVPlayer, starting at its matched passage.
/// Seeks are exact (zero tolerance) and playback starts only once a seek has landed.
/// macOS seeks unreliably inside Ogg/Opus, so those play from a full-length copy
/// decoded by the worker; common formats play from the original file.
@MainActor
final class PassagePlayer: ObservableObject {
    static let shared = PassagePlayer()
    /// Containers AVFoundation decodes and seeks accurately.
    private static let seekable: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "caf", "m4a", "aac", "mp3", "flac"]
    @Published private(set) var currentPath: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = false
    /// Position in the whole recording, 0...1.
    @Published private(set) var position: Double = 0
    /// Where a recording that is still loading will start, in seconds: shown as its position until it plays,
    /// so the playhead doesn't flash at the beginning first.
    @Published private(set) var startingAt: Double?
    private var player: AVPlayer?
    private var duration: Double = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var pendingStart: Double?
    private var finished = false
    private var seeking = false
    private var chaseTarget: Double?

    /// Plays or pauses; a new recording starts at `start` seconds.
    func toggle(path: String, start: Double) {
        if currentPath == path {
            guard player != nil else { return }
            if isPlaying { pause() } else { play() }
            return
        }
        load(path: path, at: start)
    }

    /// Plays or pauses a recording result from its matched passage.
    func toggle(_ item: SearchItem) {
        toggle(path: item.path, start: RecordingPlayer.passage(from: item.location).start)
    }

    /// Moves to a point in the whole recording and plays from there.
    func seek(path: String, to fraction: Double, duration total: Double) {
        let f = max(0, min(1, fraction))
        guard currentPath == path else {
            load(path: path, at: f * total)
            return
        }
        guard player != nil, duration > 0 else {
            pendingStart = f * total
            return
        }
        finished = false
        position = f
        chase(to: f * duration)
    }

    func stop() {
        loadTask?.cancel()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player?.pause()
        player = nil
        currentPath = nil
        isPlaying = false
        isPreparing = false
        finished = false
        seeking = false
        chaseTarget = nil
        pendingStart = nil
        startingAt = nil
        duration = 0
        position = 0
    }

    private func load(path: String, at seconds: Double) {
        stop()
        currentPath = path
        isPreparing = true
        pendingStart = seconds
        startingAt = seconds
        loadTask = Task {
            do {
                var url = URL(fileURLWithPath: path)
                if !Self.seekable.contains(url.pathExtension.lowercased()) {
                    let preview = try await AppModel.shared.audioPreview(path: path, start: 0, end: .greatestFiniteMagnitude, clip: true)
                    guard let clip = preview.clip else { throw BackendFailure(message: "The recording could not be decoded.") }
                    url = clip
                }
                // Without precise timing, seeks in variable-bitrate MP3s land seconds away from the passage.
                let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                let length = try await asset.load(.duration).seconds
                guard !Task.isCancelled, currentPath == path else { return }
                start(AVPlayerItem(asset: asset), duration: length)
            } catch {
                guard !Task.isCancelled, currentPath == path else { return }
                stop()
                AppModel.shared.error = "This recording could not be played: \(error.localizedDescription)"
            }
        }
    }

    private func start(_ item: AVPlayerItem, duration length: Double) {
        let next = AVPlayer(playerItem: item)
        next.automaticallyWaitsToMinimizeStalling = false
        player = next
        duration = length
        isPreparing = false
        timeObserver = next.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.seeking, self.chaseTarget == nil, self.duration > 0 else { return }
                self.position = min(1, max(0, time.seconds / self.duration))
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.finished = true
                self.position = 1
            }
        }
        let target = pendingStart ?? 0
        pendingStart = nil
        startingAt = nil
        position = length > 0 ? target / length : 0
        chase(to: target)
    }

    /// Exact seeks, one at a time, always finishing at the latest requested time (Apple QA1820).
    private func chase(to seconds: Double) {
        chaseTarget = seconds
        if !seeking { nextSeek() }
    }

    private func nextSeek() {
        guard let player, let target = chaseTarget else { return }
        chaseTarget = nil
        seeking = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] landed in
            Task { @MainActor in
                guard let self, self.player === player else { return }
                self.seeking = false
                if self.chaseTarget != nil { self.nextSeek() } else if landed { self.play() }
            }
        }
    }

    private func play() {
        guard let player else { return }
        if finished {
            finished = false
            position = 0
            chase(to: 0)
            return
        }
        player.play()
        isPlaying = true
    }

    private func pause() {
        player?.pause()
        isPlaying = false
    }
}

/// A recording played straight from its painted cover: a bold loudness outline of
/// the whole recording with the matched passage lit up. Click or drag anywhere to move.
struct RecordingPlayer: View {
    let item: SearchItem
    /// One row: play button, waveform and time, for list rows.
    var compact = false
    @ObservedObject private var player = PassagePlayer.shared
    @State private var preview: AudioPreview?
    @State private var failed = false
    /// Outlines already fetched, so a recording coming back into view draws at once.
    @MainActor private static var outlines: [String: AudioPreview] = [:]
    private var outlineKey: String { "\(item.path)|\(passage.start)|\(passage.end)" }

    private var passage: (start: Double, end: Double) { RecordingPlayer.passage(from: item.location) }
    private var active: Bool { player.currentPath == item.path }
    private var accent: Color { Color(red: 0.42, green: 0.32, blue: 0.95) }
    private var duration: Double { preview?.duration ?? passage.end }
    private var passageEnd: Double { min(passage.end, duration) }
    /// Where this recording is, 0...1: its start point while it loads, then the player's position.
    private var current: Double { player.startingAt.map { $0 / max(duration, 0.001) } ?? player.position }

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 12) {
                    playButton(size: 34)
                    waveform.frame(height: 30)
                    Text(active ? "\(time(current * duration)) / \(time(duration))" : "\(time(passage.start))–\(time(passageEnd))")
                        .font(.system(size: 11.5, weight: .bold)).monospacedDigit()
                        .foregroundStyle(.white).shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .fixedSize()
                }
                .padding(.horizontal, 12)
            } else {
                full.padding(20)
            }
        }
        .task(id: outlineKey) {
            if let known = Self.outlines[outlineKey] { preview = known; return }
            failed = false
            let fetched = try? await AppModel.shared.audioPreview(path: item.path, start: passage.start, end: passage.end)
            guard !Task.isCancelled else { return }
            if let fetched {
                if Self.outlines.count > 64 { Self.outlines.removeAll() }
                Self.outlines[outlineKey] = fetched
                preview = fetched
            } else {
                // The worker couldn't read it: plain bars rather than a spinner that never stops.
                failed = true
            }
        }
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 14) {
            waveform.frame(maxHeight: 150)
            HStack(spacing: 12) {
                playButton(size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(active ? "\(time(current * duration)) / \(time(duration))" : "Plays from the matched passage")
                        .font(.system(size: 14, weight: .bold)).monospacedDigit()
                    Text("Matched passage \(time(passage.start))–\(time(passageEnd))")
                        .font(.system(size: 11.5, weight: .semibold)).monospacedDigit().opacity(0.85)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
        }
    }

    private func playButton(size: CGFloat) -> some View {
                Button { player.toggle(path: item.path, start: passage.start) } label: {
                    ZStack {
                        Circle().fill(.white)
                        if active && player.isPreparing {
                            ProgressView().controlSize(.small).tint(accent)
                        } else {
                            Image(systemName: active && player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: size * 0.37, weight: .bold)).foregroundStyle(accent)
                                .offset(x: active && player.isPlaying ? 0 : size * 0.033)
                        }
                    }
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.22), radius: size * 0.22, y: size * 0.11)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(active && player.isPlaying ? "Pause" : "Play from the matched passage")
    }

    private var waveform: some View {
        GeometryReader { geometry in
            let peaks = preview?.peaks ?? []
            let lower = passage.start / max(duration, 0.001), upper = passageEnd / max(duration, 0.001)
            let playhead = active ? current : lower
            Canvas { context, size in
                guard !peaks.isEmpty else { return }
                let step = size.width / CGFloat(peaks.count)
                let barWidth = max(3, step * 0.72)
                let thinWidth = max(2, step * 0.42)
                for (index, peak) in peaks.enumerated() {
                    let t = (Double(index) + 0.5) / Double(peaks.count)
                    let inside = t >= lower && t <= upper
                    // The matched passage is always bold and solid; the rest is thinner,
                    // brightening as it plays, so the passage never blends in.
                    let width = inside ? barWidth : thinWidth
                    let height = max(width, CGFloat(0.1 + 0.9 * pow(peak, 1.4)) * size.height)
                    let rect = CGRect(x: CGFloat(index) * step + (step - width) / 2, y: (size.height - height) / 2, width: width, height: height)
                    let opacity = inside ? 1 : (active && t <= playhead ? 0.72 : 0.34)
                    context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(.white.opacity(opacity)))
                }
                if active {
                    let x = CGFloat(playhead) * size.width
                    context.fill(Path(roundedRect: CGRect(x: x - 1.5, y: -8, width: 3, height: size.height + 16), cornerRadius: 1.5), with: .color(.white))
                }
            }
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            .overlay {
                if preview == nil && failed { WaveformBars(seed: item.path) }
                else if preview == nil { ProgressView().controlSize(.small).tint(.white) }
            }
            .contentShape(Rectangle())
            // A click jumps straight to that point (native spatial tap); dragging scrubs.
            // Both read positions in the waveform's own coordinates.
            .onTapGesture(coordinateSpace: .local) { location in scrub(to: location.x, width: geometry.size.width) }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .local)
                .onChanged { value in scrub(to: value.location.x, width: geometry.size.width) })
            .onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.pointingHand.set()
                case .ended: NSCursor.arrow.set()
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Recording position")
        .accessibilityValue(time((active ? current : passage.start / max(duration, 0.001)) * duration))
        .accessibilityAdjustableAction { direction in
            let step = 10 / max(duration, 1)
            let now = active ? current : passage.start / max(duration, 1)
            player.seek(path: item.path, to: now + (direction == .increment ? step : -step), duration: duration)
        }
    }

    private func scrub(to x: CGFloat, width: CGFloat) {
        guard preview != nil, width > 0 else { return }
        player.seek(path: item.path, to: Double(x / width), duration: duration)
    }

    private func time(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Parses locations such as "30.0–60.0 seconds" or "0:30–1:00".
    static func passage(from location: String?) -> (start: Double, end: Double) {
        guard let location else { return (0, 30) }
        let parts = location.replacingOccurrences(of: " seconds", with: "").split(whereSeparator: { $0 == "–" || $0 == "-" })
        func seconds(_ text: Substring) -> Double? {
            let pieces = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
            if pieces.count == 2, let m = Double(pieces[0]), let s = Double(pieces[1]) { return m * 60 + s }
            return Double(text.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count == 2, let start = seconds(parts[0]), let end = seconds(parts[1]), end > start else { return (0, 30) }
        return (start, end)
    }
}
