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

    private var displays: [SCDisplay] = []
    private let captureEngine = CaptureEngine()
    private var rustBridge: RustRecorderBridge?

    init() {
        captureEngine.onPreviewImage = { [weak self] image in
            Task { @MainActor in
                self?.previewImage = image
            }
        }
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
        await loadSources()
        await requestCameraAccess()
        await requestMicrophoneAccess()
        await prepareCapture()
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

    func requestCameraAccess() async {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else { return }
        _ = await AVCaptureDevice.requestAccess(for: .video)
    }

    func requestMicrophoneAccess() async {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }
}
