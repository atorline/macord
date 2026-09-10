# Macord

Native macOS-first screen recorder foundation built around a SwiftUI shell and a Rust core.

## Architecture

- `crates/config`: serializable recording configuration and codec/resolution types.
- `crates/core`: recorder lifecycle and platform-independent orchestration.
- `crates/ffi`: C ABI surface for Swift integration.
- `macos/Sources/Macord`: SwiftUI presentation and macOS capability discovery.

The current MVP records a selected display through ScreenCaptureKit into an AVAssetWriter using hardware H.264 or HEVC encoding. When enabled, the latest webcam frame is composited into the screen frame and microphone audio is muxed as AAC. Rust owns recorder lifecycle, timestamp validation, frame acceptance, backpressure decisions, and pipeline statistics through the C ABI bridge; Swift owns the native media adapters and UI.

Recordings are written to `~/Movies/Macord`. Screen Recording permission, Camera permission, and Microphone permission are required for the corresponding enabled sources. System audio is captured by ScreenCaptureKit as a separate AAC track; the current UI intentionally excludes Macord's own process audio to prevent feedback.

## Verify

```sh
cargo test --workspace
swift build
make run
```

`make run` builds the Rust dynamic library before launching the Swift app. Recording intentionally fails if that Rust library is unavailable.

For a production app bundle, add a native Xcode target with Screen Recording and Camera usage descriptions, then link the universal Rust static library for `aarch64-apple-darwin` and `x86_64-apple-darwin`.
