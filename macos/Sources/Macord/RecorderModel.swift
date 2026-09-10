import AVFoundation
import Combine
import ScreenCaptureKit

struct CaptureSource: Identifiable, Hashable {
    let id: String
    let name: String
    let width: Int
    let height: Int
    let maxFPS: Int

    var nativeLabel: String { "\(width) × \(height)" }
}

enum ResolutionOption: String, CaseIterable, Identifiable {
    case source = "Source / Native"
    case p720 = "720p"
    case p1080 = "1080p"
    case p1440 = "1440p"
    case p2160 = "4K"

    var id: String { rawValue }
}

enum CameraPosition: String, CaseIterable, Identifiable {
    case bottomRight = "Bottom right"
    case bottomLeft = "Bottom left"
    case topRight = "Top right"
    case topLeft = "Top left"

    var id: String { rawValue }
}

enum StressProfile: String {
    case easy
    case normal
    case medium
    case extreme
}

@MainActor
final class RecorderModel: ObservableObject {
    @Published var sources: [CaptureSource] = []
    @Published var selectedSourceID: String?
    @Published var resolution: ResolutionOption = .source
    @Published var fps = 60
    @Published var codec = "H.264"
    @Published var cameraEnabled = true
    @Published var microphoneEnabled = true
    @Published var systemAudioEnabled = false
    @Published var cameraPosition: CameraPosition = .bottomRight
    @Published var cameraName = "FaceTime HD Camera"
    @Published var isRecording = false
    @Published var permissionMessage: String?
    @Published var lastOutputURL: URL?
    @Published var previewImage: CGImage?
    @Published var isPreparing = false
    @Published var resourceMetrics = ResourceMetrics()
    let stressProfile: StressProfile?

    private var displays: [SCDisplay] = []
    private let captureEngine = CaptureEngine()
    private var rustBridge: RustRecorderBridge?
    private let resourceMonitor = ResourceMonitor()
    private var metricsTask: Task<Void, Never>?

    init() {
        stressProfile = Self.commandLineStressProfile()
        switch stressProfile {
        case .easy:
            resolution = .source
            fps = 30
            codec = "H.264"
            cameraEnabled = false
            microphoneEnabled = false
            systemAudioEnabled = false
        case .normal:
            resolution = .p1080
            fps = 60
            codec = "H.264"
        case .medium:
            resolution = .p1440
            fps = 60
            codec = "HEVC"
            systemAudioEnabled = true
        case .extreme:
            resolution = .p2160
            fps = 120
            codec = "HEVC"
            cameraEnabled = true
            microphoneEnabled = true
            systemAudioEnabled = true
        case .none:
            break
        }
        captureEngine.onPreviewImage = { [weak self] image in
            Task { @MainActor in
                self?.previewImage = image
                self?.resourceMonitor.recordPreviewFrame()
            }
        }
        resourceMonitor.onMetrics = { [weak self] metrics in
            self?.resourceMetrics = metrics
        }
    }

    private static func commandLineStressProfile() -> StressProfile? {
        guard let index = CommandLine.arguments.firstIndex(of: "--stress-profile"),
              index + 1 < CommandLine.arguments.count else { return nil }
        return StressProfile(rawValue: CommandLine.arguments[index + 1])
    }

    var selectedSource: CaptureSource? {
        sources.first { $0.id == selectedSourceID }
    }

    var availableFPS: [Int] {
        let maximum = selectedSource?.maxFPS ?? 60
        return [30, 60, 120].filter { $0 <= maximum }
    }

    func loadSources() async {
        do {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            displays = shareableContent.displays
            sources = shareableContent.displays.map {
                CaptureSource(id: String($0.displayID), name: "Display \($0.displayID)", width: $0.width, height: $0.height, maxFPS: 60)
            }
            selectedSourceID = sources.first?.id
        } catch {
            permissionMessage = "Screen recording permission is required to list displays."
        }
    }

    func initializeCapture() async {
        resourceMonitor.start()
        startMetricsTask()
        await loadSources()
        await requestCameraAccess()
        await requestMicrophoneAccess()
        await prepareCapture()
    }

    private func startMetricsTask() {
        metricsTask?.cancel()
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.resourceMonitor.updateRustStats(self.rustBridge?.stats(), fileURL: self.lastOutputURL)
            }
        }
    }

    func prepareCapture() async {
        guard !isRecording,
              let selectedSourceID,
              let display = displays.first(where: { String($0.displayID) == selectedSourceID }) else { return }
        isPreparing = true
        defer { isPreparing = false }
        do {
            try await captureEngine.prepare(
                display: display,
                resolution: resolution,
                fps: fps,
                cameraEnabled: cameraEnabled,
                microphoneEnabled: microphoneEnabled,
                systemAudioEnabled: systemAudioEnabled,
                cameraPosition: cameraPosition
            )
        } catch {
            permissionMessage = error.localizedDescription
        }
    }

    func toggleRecording() async {
        if isRecording {
            do {
                try await captureEngine.stopRecording()
                _ = rustBridge?.end()
                rustBridge = nil
                resourceMonitor.endRecording()
                isRecording = false
            } catch {
                permissionMessage = error.localizedDescription
            }
            return
        }

        guard let selectedSourceID,
              let display = displays.first(where: { String($0.displayID) == selectedSourceID }) else {
            permissionMessage = "Select a display before recording."
            return
        }

        await prepareCapture()
        guard captureEngine.isPrepared else {
            permissionMessage = "Capture is still initializing."
            return
        }

        let rustConfig = RustRecordingConfig(
            resolution: Int32(resolutionCode),
            fps: Int32(fps),
            codec: codec == "HEVC" ? 1 : 0,
            microphoneEnabled: microphoneEnabled ? 1 : 0,
            systemAudioEnabled: systemAudioEnabled ? 1 : 0
        )
        guard let bridge = RustRecorderBridge.make(config: rustConfig) else {
            permissionMessage = "Rust engine library not found. Run the app through make run."
            return
        }
        guard bridge.begin() else {
            self.rustBridge = nil
            permissionMessage = "Rust recorder could not enter the recording state."
            return
        }
        rustBridge = bridge

        do {
            lastOutputURL = try await captureEngine.start(
                display: display,
                resolution: resolution,
                fps: fps,
                codec: codec,
                cameraEnabled: cameraEnabled,
                microphoneEnabled: microphoneEnabled,
                systemAudioEnabled: systemAudioEnabled,
                cameraPosition: cameraPosition,
                rustBridge: rustBridge
            )
            rustBridge?.mark()
            resourceMonitor.beginRecording(bitrateBitsPerSecond: encoderBitrate)
            isRecording = true
        } catch {
            rustBridge = nil
            permissionMessage = error.localizedDescription
        }
    }

    private var resolutionCode: Int {
        switch resolution {
        case .source: return 0
        case .p720: return 1
        case .p1080: return 2
        case .p1440: return 3
        case .p2160: return 4
        }
    }

    private var encoderBitrate: Int {
        let source = selectedSource
        let width: Int
        let height: Int
        switch resolution {
        case .source:
            width = source?.width ?? 1920
            height = source?.height ?? 1080
        case .p720: width = 1280; height = 720
        case .p1080: width = 1920; height = 1080
        case .p1440: width = 2560; height = 1440
        case .p2160: width = 3840; height = 2160
        }
        let videoBitrate = max(4_000_000, min(24_000_000, width * height * fps / 20))
        let microphoneBitrate = microphoneEnabled ? 128_000 : 0
        let systemAudioBitrate = systemAudioEnabled ? 192_000 : 0
        return videoBitrate + microphoneBitrate + systemAudioBitrate
    }

    func requestCameraAccess() async {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else { return }
        _ = await AVCaptureDevice.requestAccess(for: .video)
    }

    func requestMicrophoneAccess() async {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }
}
