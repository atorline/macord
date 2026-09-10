@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import ScreenCaptureKit

final class CaptureEngine: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var rustBridge: RustRecorderBridge?
    private var hasStartedSession = false
    private var outputDimensions = CGSize.zero
    private var cameraPosition: CameraPosition = .bottomRight
    private var cameraSession: AVCaptureSession?
    private var latestCameraBuffer: CVPixelBuffer?
    private var lastPreviewTime = CMTime.zero
    private var preparedDisplayID: CGDirectDisplayID?
    private var preparedResolution: ResolutionOption?
    private var preparedFPS: Int?
    private var preparedCameraEnabled = false
    private var preparedMicrophoneEnabled = false
    private var preparedSystemAudioEnabled = false
    private let cameraLock = NSLock()
    private let sampleQueue = DispatchQueue(label: "com.macord.capture.samples", qos: .userInitiated)
    private let cameraQueue = DispatchQueue(label: "com.macord.capture.camera", qos: .userInitiated)
    private let renderContext = CIContext(options: [.cacheIntermediates: false])
    var onPreviewImage: (@Sendable (CGImage) -> Void)?

    var isPrepared: Bool { stream != nil }

    @MainActor
    func prepare(display: SCDisplay, resolution: ResolutionOption, fps: Int, cameraEnabled: Bool, microphoneEnabled: Bool, systemAudioEnabled: Bool, cameraPosition: CameraPosition) async throws {
        if stream != nil,
           preparedDisplayID == display.displayID,
           preparedResolution == resolution,
           preparedFPS == fps,
           preparedCameraEnabled == cameraEnabled,
           preparedMicrophoneEnabled == microphoneEnabled,
           preparedSystemAudioEnabled == systemAudioEnabled {
            self.cameraPosition = cameraPosition
            return
        }
        if stream != nil {
            try await stopCaptureSession()
        }

        let dimensions = outputDimensions(for: display, resolution: resolution)
        if cameraEnabled || microphoneEnabled {
            try configureCameraAndMicrophone(cameraEnabled: cameraEnabled, microphoneEnabled: microphoneEnabled)
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.capturesAudio = systemAudioEnabled
        configuration.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if systemAudioEnabled {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }

        self.stream = stream
        self.outputDimensions = CGSize(width: dimensions.width, height: dimensions.height)
        self.cameraPosition = cameraPosition
        self.preparedDisplayID = display.displayID
        self.preparedResolution = resolution
        self.preparedFPS = fps
        self.preparedCameraEnabled = cameraEnabled
        self.preparedMicrophoneEnabled = microphoneEnabled
        self.preparedSystemAudioEnabled = systemAudioEnabled
        self.hasStartedSession = false
        self.lastPreviewTime = .zero
        try await stream.startCapture()
    }

    @MainActor
    func start(display: SCDisplay, resolution: ResolutionOption, fps: Int, codec: String, cameraEnabled: Bool, microphoneEnabled: Bool, systemAudioEnabled: Bool, cameraPosition: CameraPosition, rustBridge: RustRecorderBridge?) async throws -> URL {
        guard stream != nil else { throw CaptureError.captureSessionNotPrepared }
        let outputURL = try makeOutputURL()
        let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
        let dimensions = outputDimensions(for: display, resolution: resolution)
        let codecType: AVVideoCodecType = codec == "HEVC" ? .hevc : .h264
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: dimensions.width,
            AVVideoHeightKey: dimensions.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate(width: dimensions.width, height: dimensions.height, fps: fps),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw CaptureError.writerInputUnavailable }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: dimensions.width,
                kCVPixelBufferHeightKey as String: dimensions.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )

        var audioInput: AVAssetWriterInput?
        if microphoneEnabled {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw CaptureError.audioInputUnavailable }
            writer.add(input)
            audioInput = input
        }

        var systemAudioInput: AVAssetWriterInput?
        if systemAudioEnabled {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw CaptureError.systemAudioInputUnavailable }
            writer.add(input)
            systemAudioInput = input
        }

        guard writer.startWriting() else { throw writer.error ?? CaptureError.writerStartFailed }
        self.writer = writer
        self.videoInput = videoInput
        self.videoAdaptor = adaptor
        self.audioInput = audioInput
        self.systemAudioInput = systemAudioInput
        self.outputDimensions = CGSize(width: dimensions.width, height: dimensions.height)
        self.cameraPosition = cameraPosition
        self.rustBridge = rustBridge
        self.hasStartedSession = false
        return outputURL
    }

    @MainActor
    func stopRecording() async throws {
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        await withCheckedContinuation { continuation in
            writer?.finishWriting { continuation.resume() }
        }
        writer = nil
        videoInput = nil
        videoAdaptor = nil
        audioInput = nil
        systemAudioInput = nil
        rustBridge = nil
        hasStartedSession = false
    }

    @MainActor
    func shutdown() async throws {
        try await stopRecordingIfNeeded()
        try await stopCaptureSession()
    }

    @MainActor
    private func stopRecordingIfNeeded() async throws {
        guard writer != nil else { return }
        try await stopRecording()
    }

    @MainActor
    private func stopCaptureSession() async throws {
        try await stream?.stopCapture()
        stream = nil
        cameraSession?.stopRunning()
        cameraSession = nil
        preparedDisplayID = nil
        preparedResolution = nil
        preparedFPS = nil
        clearCameraBuffer()
    }

    private func configureCameraAndMicrophone(cameraEnabled: Bool, microphoneEnabled: Bool) throws {
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high

        if cameraEnabled, let device = AVCaptureDevice.default(for: .video) {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: cameraQueue)
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.connection(with: .video)?.videoMinFrameDuration = CMTime(value: 1, timescale: 30)
            }
        }

        if microphoneEnabled, let device = AVCaptureDevice.default(for: .audio) {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: cameraQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }

        session.commitConfiguration()
        cameraSession = session
        cameraQueue.async { session.startRunning() }
    }

    private func clearCameraBuffer() {
        cameraLock.lock()
        latestCameraBuffer = nil
        cameraLock.unlock()
    }

    private func makeOutputURL() throws -> URL {
        let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Macord", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return directory.appendingPathComponent("Recording-\(stamp).mp4")
    }

    private func outputDimensions(for display: SCDisplay, resolution: ResolutionOption) -> (width: Int, height: Int) {
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
        return (max(2, Int(Double(sourceWidth) * scale) / 2 * 2), max(2, Int(Double(sourceHeight) * scale) / 2 * 2))
    }

    private func bitrate(width: Int, height: Int, fps: Int) -> Int {
        max(4_000_000, min(45_000_000, width * height * fps / 12))
    }

    private func timestampNanoseconds(_ sampleBuffer: CMSampleBuffer) -> Int64 {
        CMTimeConvertScale(sampleBuffer.presentationTimeStamp, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
    }

    private func compositedImage(screenBuffer: CVPixelBuffer) -> CIImage {
        var image = CIImage(cvPixelBuffer: screenBuffer)
        cameraLock.lock()
        let cameraBuffer = latestCameraBuffer
        cameraLock.unlock()
        guard let cameraBuffer else { return image }

        let cameraImage = CIImage(cvPixelBuffer: cameraBuffer)
        let cameraWidth = outputDimensions.width * 0.24
        let cameraHeight = cameraWidth * 0.75
        let scale = min(cameraWidth / cameraImage.extent.width, cameraHeight / cameraImage.extent.height)
        let scaled = cameraImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = cameraPosition == .bottomLeft || cameraPosition == .topLeft ? 32.0 : outputDimensions.width - cameraWidth - 32.0
        let y = cameraPosition == .topLeft || cameraPosition == .topRight ? outputDimensions.height - cameraHeight - 32.0 : 32.0
        let overlay = scaled.transformed(by: CGAffineTransform(translationX: x, y: y))
        image = overlay.composited(over: image)
        return image
    }

    private func emitPreview(image: CIImage, timestamp: CMTime) {
        guard timestamp - lastPreviewTime >= CMTime(value: 1, timescale: 15) else { return }
        lastPreviewTime = timestamp
        let extent = CGRect(x: 0, y: 0, width: outputDimensions.width, height: outputDimensions.height)
        guard let previewImage = renderContext.createCGImage(image, from: extent) else { return }
        onPreviewImage?(previewImage)
    }
}

extension CaptureEngine: SCStreamOutput, SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            guard let systemAudioInput,
                  systemAudioInput.isReadyForMoreMediaData,
                  hasStartedSession else { return }
            if let rustBridge, !rustBridge.acceptAudio(timestampNs: timestampNanoseconds(sampleBuffer)) { return }
            systemAudioInput.append(sampleBuffer)
            return
        }

        guard let screenBuffer = sampleBuffer.imageBuffer else { return }
        let image = compositedImage(screenBuffer: screenBuffer)
        emitPreview(image: image, timestamp: sampleBuffer.presentationTimeStamp)

        guard let input = videoInput,
              let adaptor = videoAdaptor,
              input.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool else { return }
        if let rustBridge, !rustBridge.acceptVideo(timestampNs: timestampNanoseconds(sampleBuffer)) { return }
        if !hasStartedSession {
            writer?.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            hasStartedSession = true
        }
        var outputBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer) == kCVReturnSuccess,
              let outputBuffer else { return }
        renderContext.render(image, to: outputBuffer)
        adaptor.append(outputBuffer, withPresentationTime: sampleBuffer.presentationTimeStamp)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        writer?.cancelWriting()
    }
}

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput, let buffer = sampleBuffer.imageBuffer {
            cameraLock.lock()
            latestCameraBuffer = buffer
            cameraLock.unlock()
        } else if output is AVCaptureAudioDataOutput,
                  let audioInput,
                  audioInput.isReadyForMoreMediaData,
                  hasStartedSession {
            if let rustBridge, !rustBridge.acceptAudio(timestampNs: timestampNanoseconds(sampleBuffer)) { return }
            audioInput.append(sampleBuffer)
        }
    }
}

enum CaptureError: LocalizedError {
    case captureSessionNotPrepared
    case writerInputUnavailable
    case audioInputUnavailable
    case systemAudioInputUnavailable
    case writerStartFailed

    var errorDescription: String? {
        switch self {
        case .captureSessionNotPrepared: return "Capture is still initializing."
        case .writerInputUnavailable: return "The selected video format is unavailable."
        case .audioInputUnavailable: return "The microphone audio format is unavailable."
        case .systemAudioInputUnavailable: return "The system audio format is unavailable."
        case .writerStartFailed: return "The recording file could not be opened."
        }
    }
}
