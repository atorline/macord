import AVFoundation
import ScreenCaptureKit

final class CaptureEngine: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var hasStartedSession = false
    private let sampleQueue = DispatchQueue(label: "com.macord.capture.samples", qos: .userInitiated)

    @MainActor
    func start(display: SCDisplay, resolution: ResolutionOption, fps: Int, codec: String) async throws -> URL {
        let outputURL = try makeOutputURL()
        let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
        let dimensions = outputDimensions(display: display, resolution: resolution)
        let codecType: AVVideoCodecType = codec == "HEVC" ? .hevc : .h264
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: codecType,
                AVVideoWidthKey: dimensions.width,
                AVVideoHeightKey: dimensions.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate(width: dimensions.width, height: dimensions.height, fps: fps),
                    AVVideoExpectedSourceFrameRateKey: fps,
                    AVVideoMaxKeyFrameIntervalKey: fps * 2
                ]
            ]
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureError.writerInputUnavailable }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CaptureError.writerStartFailed }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        configuration.showsCursor = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()

        self.stream = stream
        self.writer = writer
        self.videoInput = input
        self.hasStartedSession = false
        return outputURL
    }

    @MainActor
    func stop() async throws {
        try await stream?.stopCapture()
        stream = nil
        videoInput?.markAsFinished()
        await withCheckedContinuation { continuation in
            writer?.finishWriting {
                continuation.resume()
            }
        }
        writer = nil
        videoInput = nil
        hasStartedSession = false
    }

    private func makeOutputURL() throws -> URL {
        let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Macord", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let filename = "Recording-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")).mp4"
        return directory.appendingPathComponent(filename)
    }

    private func outputDimensions(display: SCDisplay, resolution: ResolutionOption) -> (width: Int, height: Int) {
        let sourceWidth = display.width
        let sourceHeight = display.height
        let targetWidth: Int
        switch resolution {
        case .source: return (sourceWidth, sourceHeight)
        case .p720: targetWidth = 1280
        case .p1080: targetWidth = 1920
        case .p1440: targetWidth = 2560
        case .p2160: targetWidth = 3840
        }
        let scale = min(1.0, Double(targetWidth) / Double(sourceWidth))
        let width = max(2, Int(Double(sourceWidth) * scale) / 2 * 2)
        let height = max(2, Int(Double(sourceHeight) * scale) / 2 * 2)
        return (width, height)
    }

    private func bitrate(width: Int, height: Int, fps: Int) -> Int {
        max(4_000_000, min(45_000_000, width * height * fps / 12))
    }
}

extension CaptureEngine: SCStreamOutput, SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let input = videoInput, input.isReadyForMoreMediaData else { return }
        if !hasStartedSession {
            writer?.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            hasStartedSession = true
        }
        input.append(sampleBuffer)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.writer?.cancelWriting()
        }
    }
}

enum CaptureError: LocalizedError {
    case writerInputUnavailable
    case writerStartFailed

    var errorDescription: String? {
        switch self {
        case .writerInputUnavailable: return "The selected video format is unavailable."
        case .writerStartFailed: return "The recording file could not be opened."
        }
    }
}
