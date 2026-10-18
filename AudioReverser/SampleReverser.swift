import AVFoundation

enum AudioError: LocalizedError {
    case microphoneUnavailable
    case emptyRecording
    case buffer
    case unsupportedFormat
    case missingReverse
    case unreadable

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            "The microphone isn’t available right now."
        case .emptyRecording:
            "That recording was empty. Try again."
        case .buffer:
            "There isn’t enough memory to reverse this clip."
        case .unsupportedFormat:
            "This recording’s format can’t be reversed."
        case .missingReverse:
            "Reverse isn’t ready for this clip."
        case .unreadable:
            "That clip couldn’t be read."
        }
    }
}

/// Reverses PCM frames in time. Each channel is reversed on its own.
/// Playback never uses a negative rate.
enum SampleReverser {
    static func writeReversedCopy(of sourceURL: URL, to destinationURL: URL) throws {
        let input = try AVAudioFile(forReading: sourceURL)
        let format = input.processingFormat
        let length = input.length
        guard length > 0 else { throw AudioError.emptyRecording }
        guard length <= AVAudioFramePosition(AVAudioFrameCount.max) else { throw AudioError.buffer }

        let frameCount = AVAudioFrameCount(length)
        guard let forward = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioError.buffer
        }
        try input.read(into: forward)
        guard forward.frameLength > 0 else { throw AudioError.emptyRecording }

        guard let backward = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: forward.frameLength) else {
            throw AudioError.buffer
        }
        try reverse(forward, into: backward)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        let output = try AVAudioFile(
            forWriting: destinationURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try output.write(from: backward)
    }

    static func reverse(_ source: AVAudioPCMBuffer, into destination: AVAudioPCMBuffer) throws {
        let frames = Int(source.frameLength)
        let channels = Int(source.format.channelCount)
        guard frames > 0, channels > 0 else { throw AudioError.emptyRecording }
        destination.frameLength = source.frameLength

        let sampleStride = Int(source.stride)
        if let sourcePlanes = source.floatChannelData, let destinationPlanes = destination.floatChannelData {
            reversePlanes(sourcePlanes, destinationPlanes, channels: channels, frames: frames, stride: sampleStride)
            return
        }
        if let sourcePlanes = source.int16ChannelData, let destinationPlanes = destination.int16ChannelData {
            reversePlanes(sourcePlanes, destinationPlanes, channels: channels, frames: frames, stride: sampleStride)
            return
        }
        if let sourcePlanes = source.int32ChannelData, let destinationPlanes = destination.int32ChannelData {
            reversePlanes(sourcePlanes, destinationPlanes, channels: channels, frames: frames, stride: sampleStride)
            return
        }
        throw AudioError.unsupportedFormat
    }

    private static func reversePlanes<T>(
        _ sourcePlanes: UnsafePointer<UnsafeMutablePointer<T>>,
        _ destinationPlanes: UnsafePointer<UnsafeMutablePointer<T>>,
        channels: Int,
        frames: Int,
        stride: Int
    ) {
        let step = max(stride, 1)
        for channel in 0..<channels {
            let source = sourcePlanes[channel]
            let destination = destinationPlanes[channel]
            for frame in 0..<frames {
                destination[frame * step] = source[(frames - 1 - frame) * step]
            }
        }
    }
}
