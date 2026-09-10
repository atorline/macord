import Foundation
import Darwin
import Metal
import OSLog

struct ResourceMetrics {
    var cpuPercent = 0.0
    var memoryMB = 0.0
    var gpuAllocatedMB = 0.0
    var gpuBudgetMB = 0.0
    var previewFPS = 0.0
    var videoFrames: UInt64 = 0
    var audioFrames: UInt64 = 0
    var droppedVideoFrames: UInt64 = 0
    var droppedAudioFrames: UInt64 = 0
    var fileSizeMB = 0.0
    var estimatedSizeMBPerMinute = 0.0
    var elapsedSeconds = 0.0

    var gpuStatus: String {
        guard gpuBudgetMB > 0 else { return "n/a" }
        return "\(Int(gpuAllocatedMB)) / \(Int(gpuBudgetMB)) MB"
    }
}

@MainActor
final class ResourceMonitor: ObservableObject {
    @Published private(set) var metrics = ResourceMetrics()
    var onMetrics: ((ResourceMetrics) -> Void)?
    private let logger = Logger(subsystem: "com.macord.app", category: "performance")
    private let device = MTLCreateSystemDefaultDevice()
    private var task: Task<Void, Never>?
    private var startedAt: Date?
    private var previousCPUTime = 0.0
    private var previousWallTime = ProcessInfo.processInfo.systemUptime
    private var previewFrameCount: UInt64 = 0
    private var previousPreviewFrameCount: UInt64 = 0
    private var previousFileSize = 0
    private var currentBitrateBitsPerSecond = 0

    deinit {
        task?.cancel()
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.sample()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        startedAt = nil
        currentBitrateBitsPerSecond = 0
        metrics = ResourceMetrics()
    }

    func beginRecording(bitrateBitsPerSecond: Int) {
        startedAt = Date()
        currentBitrateBitsPerSecond = bitrateBitsPerSecond
        previousFileSize = 0
        metrics.elapsedSeconds = 0
    }

    func endRecording() {
        startedAt = nil
        currentBitrateBitsPerSecond = 0
    }

    func recordPreviewFrame() {
        previewFrameCount &+= 1
    }

    func updateRustStats(_ stats: RustRecorderStats?, fileURL: URL?) {
        guard let stats else { return }
        metrics.videoFrames = stats.videoFrames
        metrics.audioFrames = stats.audioFrames
        metrics.droppedVideoFrames = stats.droppedVideoFrames
        metrics.droppedAudioFrames = stats.droppedAudioFrames
        if let fileURL, let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? NSNumber {
            previousFileSize = size.intValue
            metrics.fileSizeMB = Double(size.intValue) / 1_000_000
        }
    }

    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        let wallDelta = max(0.001, now - previousWallTime)
        let cpuTime = processCPUTime()
        let cpuDelta = max(0, cpuTime - previousCPUTime)
        let cpuPercent = min(100, (cpuDelta / wallDelta) * 100 / Double(max(1, ProcessInfo.processInfo.activeProcessorCount)))
        previousCPUTime = cpuTime
        previousWallTime = now

        let previewDelta = previewFrameCount - previousPreviewFrameCount
        previousPreviewFrameCount = previewFrameCount
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let estimatedSize = Double(currentBitrateBitsPerSecond) * elapsed / 8 / 1_000_000
        let memory = residentMemoryMB()
        let gpuAllocated = Double(device?.currentAllocatedSize ?? 0) / 1_000_000
        let gpuBudget = Double(device?.recommendedMaxWorkingSetSize ?? 0) / 1_000_000

        metrics.cpuPercent = cpuPercent
        metrics.memoryMB = memory
        metrics.gpuAllocatedMB = gpuAllocated
        metrics.gpuBudgetMB = gpuBudget
        metrics.previewFPS = Double(previewDelta) / wallDelta
        metrics.elapsedSeconds = elapsed
        metrics.estimatedSizeMBPerMinute = Double(currentBitrateBitsPerSecond) * 60 / 8 / 1_000_000
        if previousFileSize > 0 {
            metrics.fileSizeMB = Double(previousFileSize) / 1_000_000
        } else if elapsed > 0 {
            metrics.fileSizeMB = estimatedSize
        }

        onMetrics?(metrics)

        logger.info("process_cpu_total=\(cpuPercent, format: .fixed(precision: 1))% memory=\(memory, format: .fixed(precision: 1))MB gpu=\(gpuAllocated, format: .fixed(precision: 1))/\(gpuBudget, format: .fixed(precision: 1))MB preview_fps=\(self.metrics.previewFPS, format: .fixed(precision: 1)) dropped_video=\(self.metrics.droppedVideoFrames) dropped_audio=\(self.metrics.droppedAudioFrames) file_mb=\(self.metrics.fileSizeMB, format: .fixed(precision: 2))")
    }

    private func processCPUTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }

    private func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_000_000
    }
}
