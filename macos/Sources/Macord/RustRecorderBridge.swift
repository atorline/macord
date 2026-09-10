import Darwin
import Foundation

struct RustRecordingConfig {
    var resolution: Int32
    var fps: Int32
    var codec: Int32
    var microphoneEnabled: UInt8
    var systemAudioEnabled: UInt8
}

final class RustRecorderBridge: @unchecked Sendable {
    private typealias Create = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias Destroy = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer?) -> UInt8
    private typealias MarkRecording = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> UInt8
    private typealias Finish = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private var library: UnsafeMutableRawPointer?
    private var recorder: UnsafeMutableRawPointer?
    private let destroy: Destroy
    private let start: Start
    private let markRecording: MarkRecording
    private let stop: Stop
    private let finish: Finish

    private init(library: UnsafeMutableRawPointer, config: RustRecordingConfig) throws {
        self.library = library
        guard let createSymbol = dlsym(library, "macord_recorder_create"),
              let destroySymbol = dlsym(library, "macord_recorder_destroy"),
              let startSymbol = dlsym(library, "macord_recorder_start"),
              let markSymbol = dlsym(library, "macord_recorder_mark_recording"),
              let stopSymbol = dlsym(library, "macord_recorder_stop"),
              let finishSymbol = dlsym(library, "macord_recorder_finish") else {
            throw RustBridgeError.symbolUnavailable
        }
        let create = unsafeBitCast(createSymbol, to: Create.self)
        self.destroy = unsafeBitCast(destroySymbol, to: Destroy.self)
        self.start = unsafeBitCast(startSymbol, to: Start.self)
        self.markRecording = unsafeBitCast(markSymbol, to: MarkRecording.self)
        self.stop = unsafeBitCast(stopSymbol, to: Stop.self)
        self.finish = unsafeBitCast(finishSymbol, to: Finish.self)
        let recorderPointer = withUnsafePointer(to: config) { create(UnsafeRawPointer($0)) }
        guard let recorder = recorderPointer else { throw RustBridgeError.createFailed }
        self.recorder = recorder
    }

    static func make(config: RustRecordingConfig) -> RustRecorderBridge? {
        let root = FileManager.default.currentDirectoryPath
        let candidates = [
            "\(root)/target/debug/libmacord_ffi.dylib",
            "\(root)/target/release/libmacord_ffi.dylib"
        ]
        for path in candidates {
            guard let library = dlopen(path, RTLD_NOW) else { continue }
            do { return try RustRecorderBridge(library: library, config: config) }
            catch { dlclose(library) }
        }
        return nil
    }

    func begin() -> Bool { start(recorder) != 0 }
    func mark() { markRecording(recorder) }
    func end() -> Bool { stop(recorder) != 0 }

    deinit {
        finish(recorder)
        destroy(recorder)
        if let library { dlclose(library) }
    }
}

enum RustBridgeError: Error {
    case symbolUnavailable
    case createFailed
}
