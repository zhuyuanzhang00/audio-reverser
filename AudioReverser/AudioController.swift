import AVFoundation
import Combine

enum MicAccess: Equatable {
    case unknown
    case granted
    case denied
}

enum PlaybackDirection: String, CaseIterable, Identifiable {
    case normal
    case reverse

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal: "Normal"
        case .reverse: "Reverse"
        }
    }
}

@MainActor
final class AudioController: ObservableObject {
    @Published private(set) var permission: MicAccess = .unknown
    @Published private(set) var isRecording = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isReversing = false
    @Published private(set) var clipDuration: TimeInterval?
    @Published private(set) var recordingElapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var statusMessage: String?
    @Published var direction: PlaybackDirection = .normal
    @Published var speed: Double = 1.0 {
        didSet {
            let clamped = min(3, max(0.1, speed))
            if clamped != speed {
                speed = clamped
                return
            }
            timePitch.rate = Float(clamped)
        }
    }

    var hasClip: Bool { clipDuration != nil }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let writer = RecordingWriter()
    private var recordingURL: URL?
    private var reversedURL: URL?
    private var levelTimer: Timer?
    private var recordStartedAt: Date?
    private var playbackToken = 0
    private var graphConnected = false
    private var tapInstalled = false
    private var interruptionObserver: NSObjectProtocol?

    init() {
        timePitch.pitch = 0
        timePitch.rate = 1
        observeInterruptions()
        restoreExistingClip()
    }

    func refreshPermission() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            permission = .granted
        case .denied:
            permission = .denied
        case .undetermined:
            permission = .unknown
        @unknown default:
            permission = .unknown
        }
    }

    func toggleRecording() async {
        if isRecording {
            await finishRecording()
            return
        }
        guard !isReversing else { return }
        guard await ensurePermission() else { return }
        do {
            try startRecording()
            statusMessage = nil
        } catch {
            cleanupFailedRecording()
            statusMessage = error.localizedDescription
        }
    }

    func togglePlayback() {
        if isPlaying {
            stopPlayback()
            return
        }
        guard !isRecording, !isReversing, hasClip else { return }
        do {
            try beginPlayback()
            statusMessage = nil
        } catch {
            isPlaying = false
            statusMessage = error.localizedDescription
        }
    }

    func directionChanged() {
        guard isPlaying else { return }
        stopPlayback()
        togglePlayback()
    }

    private func ensurePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            permission = .granted
            return true
        case .denied:
            permission = .denied
            return false
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            permission = granted ? .granted : .denied
            return granted
        @unknown default:
            permission = .denied
            return false
        }
    }

    private func startRecording() throws {
        stopPlayback()
        try activateSession()
        tearDownGraph()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioError.microphoneUnavailable
        }

        let url = try clipsDirectory().appendingPathComponent("latest.caf")
        try writer.open(url: url, hardware: format)

        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [writer] buffer, _ in
            writer.append(buffer)
        }
        tapInstalled = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            writer.close()
            throw error
        }

        recordingURL = url
        reversedURL = nil
        clipDuration = nil
        isRecording = true
        recordingElapsed = 0
        recordStartedAt = Date()
        startLevelTimer()
    }

    private func finishRecording() async {
        guard isRecording else { return }
        removeTapAndStopEngine()
        writer.close()
        stopLevelTimer()
        isRecording = false
        level = 0
        recordingElapsed = 0

        guard let recordingURL else { return }
        let seconds: TimeInterval
        do {
            let file = try AVAudioFile(forReading: recordingURL)
            let sampleRate = file.fileFormat.sampleRate
            guard file.length > 0, sampleRate > 0 else { throw AudioError.emptyRecording }
            seconds = Double(file.length) / sampleRate
        } catch {
            self.recordingURL = nil
            reversedURL = nil
            clipDuration = nil
            statusMessage = error.localizedDescription
            return
        }

        clipDuration = seconds
        isReversing = true
        await Task.yield()
        do {
            let reversed = try clipsDirectory().appendingPathComponent("latest-reversed.caf")
            try SampleReverser.writeReversedCopy(of: recordingURL, to: reversed)
            reversedURL = reversed
            statusMessage = nil
        } catch {
            reversedURL = nil
            statusMessage = error.localizedDescription
        }
        isReversing = false
    }

    private func cleanupFailedRecording() {
        removeTapAndStopEngine()
        writer.close()
        stopLevelTimer()
        isRecording = false
        level = 0
    }

    private func beginPlayback() throws {
        try activateSession()
        playbackToken += 1
        let token = playbackToken
        let url = try playbackURL()

        tearDownGraph()
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.unreadable }

        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        graphConnected = true
        timePitch.pitch = 0
        timePitch.rate = Float(min(3, max(0.1, speed)))

        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.playbackToken == token else { return }
                self.isPlaying = false
            }
        }

        engine.prepare()
        try engine.start()
        player.play()
        isPlaying = true
    }

    private func stopPlayback() {
        playbackToken += 1
        player.stop()
        isPlaying = false
        if engine.isRunning, !isRecording {
            engine.pause()
        }
    }

    private func playbackURL() throws -> URL {
        switch direction {
        case .normal:
            guard let recordingURL else { throw AudioError.unreadable }
            return recordingURL
        case .reverse:
            guard let reversedURL else { throw AudioError.missingReverse }
            return reversedURL
        }
    }

    private func tearDownGraph() {
        player.stop()
        if engine.isRunning {
            engine.stop()
        }
        if graphConnected {
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(timePitch)
            graphConnected = false
        }
        if !engine.attachedNodes.contains(player) {
            engine.attach(player)
        }
        if !engine.attachedNodes.contains(timePitch) {
            engine.attach(timePitch)
        }
    }

    private func removeTapAndStopEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        try? session.overrideOutputAudioPort(.speaker)
    }

    private func startLevelTimer() {
        levelTimer?.invalidate()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isRecording else { return }
                self.level = self.writer.currentLevel()
                if let recordStartedAt = self.recordStartedAt {
                    self.recordingElapsed = Date().timeIntervalSince(recordStartedAt)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        recordStartedAt = nil
    }

    private func clipsDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Clips", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func restoreExistingClip() {
        guard let directory = try? clipsDirectory() else { return }
        let recording = directory.appendingPathComponent("latest.caf")
        guard FileManager.default.fileExists(atPath: recording.path) else { return }
        guard let file = try? AVAudioFile(forReading: recording),
              file.length > 0,
              file.fileFormat.sampleRate > 0
        else { return }

        recordingURL = recording
        clipDuration = Double(file.length) / file.fileFormat.sampleRate
        let reversed = directory.appendingPathComponent("latest-reversed.caf")
        if FileManager.default.fileExists(atPath: reversed.path) {
            reversedURL = reversed
        } else if (try? SampleReverser.writeReversedCopy(of: recording, to: reversed)) != nil {
            reversedURL = reversed
        }
    }

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .began
            else { return }
            Task { @MainActor in
                guard let self else { return }
                if self.isRecording {
                    await self.finishRecording()
                } else if self.isPlaying {
                    self.stopPlayback()
                }
            }
        }
    }
}

/// Lets the converter input block flip state without capturing a mutable variable.
private final class SupplyFlag: @unchecked Sendable {
    var done = false
}

/// Writes microphone buffers from the audio thread.
private final class RecordingWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var canonical: AVAudioFormat?
    private var latestLevel: Float = 0

    func open(url: URL, hardware: AVAudioFormat) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let opened: AVAudioFile
        let converter: AVAudioConverter?
        let canonical: AVAudioFormat?
        do {
            opened = try AVAudioFile(forWriting: url, settings: hardware.settings)
            converter = nil
            canonical = nil
        } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            guard let fallback = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: hardware.sampleRate,
                channels: hardware.channelCount,
                interleaved: false
            ) else { throw error }
            opened = try AVAudioFile(
                forWriting: url,
                settings: fallback.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            converter = AVAudioConverter(from: hardware, to: fallback)
            canonical = fallback
        }

        lock.lock()
        file = opened
        self.converter = converter
        self.canonical = canonical
        latestLevel = 0
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }

        if let converter, let canonical {
            guard let converted = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: buffer.frameCapacity) else {
                return
            }
            var conversionError: NSError?
            let supply = SupplyFlag()
            converter.reset()
            converter.convert(to: converted, error: &conversionError) { _, status in
                if supply.done {
                    status.pointee = .noDataNow
                    return nil
                }
                supply.done = true
                status.pointee = .haveData
                return buffer
            }
            guard conversionError == nil, converted.frameLength > 0 else { return }
            try? file.write(from: converted)
            latestLevel = Self.level(from: converted)
            return
        }

        try? file.write(from: buffer)
        latestLevel = Self.level(from: buffer)
    }

    func currentLevel() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return latestLevel
    }

    func close() {
        lock.lock()
        file = nil
        converter = nil
        canonical = nil
        lock.unlock()
    }

    private static func level(from buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return 0 }

        var sum: Float = 0
        var count = 0
        if let planes = buffer.floatChannelData {
            for channel in 0..<channels {
                let samples = planes[channel]
                for index in 0..<frames {
                    let sample = samples[index]
                    sum += sample * sample
                    count += 1
                }
            }
        } else if let planes = buffer.int16ChannelData {
            let scale = 1 / Float(Int16.max)
            for channel in 0..<channels {
                let samples = planes[channel]
                for index in 0..<frames {
                    let sample = Float(samples[index]) * scale
                    sum += sample * sample
                    count += 1
                }
            }
        }
        guard count > 0 else { return 0 }
        return min(1, sqrt(sum / Float(count)) * 4)
    }
}
