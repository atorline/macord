# Macord

Native macOS-first screen recorder foundation built around a SwiftUI shell and a Rust core.

## Architecture

- `crates/config`: serializable recording configuration and codec/resolution types.
- `crates/core`: recorder lifecycle and platform-independent orchestration.
- `crates/ffi`: C ABI surface for Swift integration.
- `macos/Sources/Macord`: SwiftUI presentation and macOS capability discovery.

The current MVP records a selected display through ScreenCaptureKit into an AVAssetWriter using hardware H.264 or HEVC encoding. When enabled, the latest webcam frame is composited into the screen frame and microphone audio is muxed as AAC. Rust owns recorder lifecycle, timestamp validation, frame acceptance, backpressure decisions, and pipeline statistics through the C ABI bridge; Swift owns the native media adapters and UI.

Live performance diagnostics are shown in the UI and written once per second to the `com.macord.app/performance` unified log. See [PERFORMANCE_GUIDELINES.md](PERFORMANCE_GUIDELINES.md) for resource budgets, file-size policy, and the Intel validation matrix.

Recordings are written to `~/Movies/Macord`. Screen Recording permission, Camera permission, and Microphone permission are required for the corresponding enabled sources. System audio is captured by ScreenCaptureKit as a separate AAC track; the current UI intentionally excludes Macord's own process audio to prevent feedback.

## Verify

```sh
cargo test --workspace
swift build
make run
```

`make run` builds the Rust dynamic library before launching the Swift app. Recording intentionally fails if that Rust library is unavailable.

Run the resource stress harness with:

```sh
make stress-test STRESS_ARGS="--mode easy"
make stress-test STRESS_ARGS="--mode normal --record"
make stress-test STRESS_ARGS="--mode medium --record --duration 300"
make stress-test STRESS_ARGS="--mode extreme"
```

Profiles configure the app itself: easy uses source/30 FPS/H.264 without camera or audio; normal uses 1080p60/H.264 with camera and microphone; medium uses 1440p60/HEVC with all audio; extreme targets 4K/120 FPS/HEVC with camera and all audio. The extreme profile automatically waits for a real recording session. If hardware cannot support 4K120, the capture API must reject it and the failure is reported rather than silently lowering quality.

The final output reports CPU, RAM, thread count, and min/max/average values. Raw samples are retained in `artifacts/`. GPU allocation, frame drops, and file size are reported by the in-app Performance panel and unified log.

For a production app bundle, add a native Xcode target with Screen Recording and Camera usage descriptions, then link the universal Rust static library for `aarch64-apple-darwin` and `x86_64-apple-darwin`.
