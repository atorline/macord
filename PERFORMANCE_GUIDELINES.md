# Macord Performance and Resource Quality Guidelines

This document is the acceptance contract for Macord recording quality. A feature is not complete when it records; it is complete when recording is predictable, bounded, and does not make the machine feel materially different from idle.

## Scope

Target: Intel macOS first, with Apple Silicon compatibility preserved where APIs are available.

The native boundary is intentional:

- Swift owns ScreenCaptureKit, AVFoundation, CoreVideo, CoreImage, VideoToolbox/AVAssetWriter, permissions, and UI.
- Rust owns lifecycle, timestamp validation, frame acceptance, backpressure decisions, configuration validation, and counters.
- Pixel buffers must not cross the Rust FFI boundary. Only scalar metadata and control commands cross it.

## Hard Budgets

Measurements are taken after a 60-second warm-up and reported as a 10-minute p95, not a best sample.

| Metric | Idle with preview | Recording target | Hard failure |
| --- | ---: | ---: | ---: |
| Macord process CPU | <= 5% | <= 15% at 1080p60 | > 25% sustained for 30 s |
| Macord resident memory | <= 300 MB | <= 600 MB | > 1 GB or monotonic growth |
| Preview render rate | 10-15 FPS | 10-15 FPS | UI freezes or drops below 5 FPS |
| Capture frame drops | 0 expected | < 0.1% | >= 1% |
| Audio frame drops | 0 expected | 0 | Any sustained loss |
| GPU allocation | stable after warm-up | stable after warm-up | continuous growth |
| Stop-to-file-finalized | n/a | <= 2 s | > 5 s |

GPU utilization is not reported as a fabricated percentage because public macOS APIs do not expose a consistent cross-generation utilization metric. Macord reports Metal allocated memory and recommended working-set budget instead. Use Instruments or Xcode GPU counters for utilization investigations.

## Quality Rules

1. Never use software video encoding in the production path.
2. Never copy a `CVPixelBuffer` through Rust FFI. Rust receives timestamps and counters only.
3. Never block the capture callback on the main actor, filesystem, logging I/O, or UI rendering.
4. Every capture callback must have bounded work and a drop policy.
5. Webcam input must use `alwaysDiscardsLateVideoFrames = true`.
6. Preview rendering is diagnostic UI, not the recording path, and is capped around 15 FPS.
7. The writer must use `expectsMediaDataInRealTime = true` and check `isReadyForMoreMediaData`.
8. Timestamps must be monotonic per stream. Out-of-order samples are rejected and counted.
9. Audio and video must use the same recording timeline and must be finalized before the writer is released.
10. Recording configuration changes must not restart capture while recording. Disable or defer controls that would invalidate the session.
11. All queues must be labelled and have an explicit QoS. Unbounded queues are prohibited.
12. Every new allocation in the hot path requires a reason and a measurement.
13. Logs must be sampled or rate-limited. Per-frame logs are forbidden.
14. A recording failure must finalize or cancel the writer and leave no corrupted output presented as successful.
15. A missing Rust library is a hard startup error, never a silent Swift-only fallback.

## File Size Policy

File size is controlled by bitrate, not by accidental raw-frame retention.

Approximate size:

```text
size in MB per minute = video bitrate bits/s * 60 / 8 / 1,000,000
                     + audio bitrate bits/s * 60 / 8 / 1,000,000
```

Current video bitrate policy is bounded between 4 Mbps and 24 Mbps:

```text
bitrate = clamp(width * height * fps / 20, 4,000,000, 24,000,000)
```

Expected approximate video-only sizes:

| Setting | Approximate size/minute |
| --- | ---: |
| 720p30 | 30 MB |
| 1080p30 | 30 MB |
| 1080p60 | 54 MB |
| 1440p60 | 107 MB |
| 4K60 | 187 MB |

Audio adds roughly 1 MB/minute for microphone AAC and 1.4 MB/minute for stereo system AAC. These are estimates; the benchmark panel reports actual file size while recording.

## Visible Diagnostics

The Performance panel must show:

- process CPU percentage;
- resident memory;
- Metal allocated memory and working-set budget;
- preview FPS;
- Rust accepted and dropped video/audio frames;
- current file size;
- estimated file size per minute.

The same metrics are written once per second to the `com.macord.app/performance` unified log category. Never log raw audio, pixels, permission secrets, or file contents.

## Intel Validation Matrix

Before release, test at minimum:

- Intel Mac with 8 GB RAM, 1080p30, H.264, camera off;
- Intel Mac with 16 GB RAM, 1080p60, H.264, camera on;
- Intel Mac with 16 GB RAM, 1080p60, HEVC if VideoToolbox reports support;
- external 4K display downscaled to 1080p;
- native ultrawide source resolution;
- microphone plus system audio together;
- 10-minute recording and stop/finalize;
- permission denied, display removed, camera removed, and disk nearly full.

## Acceptance Procedure

1. Start Macord with preview enabled and wait 60 seconds.
2. Record the selected profile for 10 minutes.
3. Capture the visible diagnostics every minute and save the unified log.
4. Verify CPU, memory, drops, and file size against the budgets above.
5. Open the resulting MP4 and verify video, webcam, microphone, and system audio tracks.
6. Repeat with preview disabled once that mode exists; recording resource use must not regress when preview is enabled.
7. Investigate any hard failure with Instruments before changing budgets.

A benchmark that passes only because frames are silently dropped is not a pass. Drops, latency, output integrity, and resource usage must be considered together.
