# Macord

Native macOS-first screen recorder foundation built around a SwiftUI shell and a Rust core.

## Architecture

- `crates/config`: serializable recording configuration and codec/resolution types.
- `crates/core`: recorder lifecycle and platform-independent orchestration.
- `crates/ffi`: C ABI surface for Swift integration.
- `macos/Sources/Macord`: SwiftUI presentation and macOS capability discovery.

The current MVP records a selected display through ScreenCaptureKit into an AVAssetWriter using hardware H.264 or HEVC encoding. Rust owns the recorder lifecycle and configuration through the C ABI bridge; Swift owns the native media APIs and UI.

Recordings are written to `~/Movies/Macord`. Screen Recording permission is required. The webcam preview/control and microphone muxing are represented in the UI but are not yet composited into the output file; those belong in the next capture adapters.

## Verify

```sh
cargo test --workspace
swift build
make run
```

For a production app bundle, add a native Xcode target with Screen Recording and Camera usage descriptions, then link the universal Rust static library for `aarch64-apple-darwin` and `x86_64-apple-darwin`.
