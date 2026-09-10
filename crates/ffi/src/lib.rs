use std::ffi::c_int;
use std::sync::Mutex;

use macord_config::{CaptureResolution, RecordingConfig, VideoCodec};
use macord_core::{FrameStats, Recorder};

pub struct RecorderHandle {
    recorder: Mutex<Recorder>,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MacordRecordingConfig {
    pub resolution: c_int,
    pub fps: c_int,
    pub codec: c_int,
    pub microphone_enabled: bool,
    pub system_audio_enabled: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct MacordRecorderStats {
    pub video_frames: u64,
    pub audio_frames: u64,
    pub dropped_video_frames: u64,
    pub dropped_audio_frames: u64,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn macord_recorder_create(config: *const MacordRecordingConfig) -> *mut RecorderHandle {
    if config.is_null() {
        return std::ptr::null_mut();
    }
    let config = unsafe { *config };
    let config = RecordingConfig {
        resolution: match config.resolution {
            1 => CaptureResolution::P720,
            2 => CaptureResolution::P1080,
            3 => CaptureResolution::P1440,
            4 => CaptureResolution::P2160,
            _ => CaptureResolution::Source,
        },
        fps: config.fps.max(1) as u32,
        codec: if config.codec == 1 { VideoCodec::Hevc } else { VideoCodec::H264 },
        microphone_enabled: config.microphone_enabled,
        system_audio_enabled: config.system_audio_enabled,
    };
    Box::into_raw(Box::new(RecorderHandle {
        recorder: Mutex::new(Recorder::new(config)),
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn macord_recorder_destroy(recorder: *mut RecorderHandle) {
    if !recorder.is_null() {
        unsafe {
            drop(Box::from_raw(recorder));
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn macord_recorder_start(recorder: *mut RecorderHandle) -> bool {
    if recorder.is_null() {
        return false;
    }
    unsafe { (*recorder).recorder.lock().map(|mut value| value.start().is_ok()).unwrap_or(false) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn macord_recorder_mark_recording(recorder: *mut RecorderHandle) {
    if !recorder.is_null() {
        if let Ok(mut value) = unsafe { (*recorder).recorder.lock() } {
            value.mark_recording();
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn macord_recorder_stop(recorder: *mut RecorderHandle) -> bool {
    if recorder.is_null() {
        return false;
    }
    unsafe { (*recorder).recorder.lock().map(|mut value| value.stop().is_ok()).unwrap_or(false) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn macord_recorder_finish(recorder: *mut RecorderHandle) {
    if !recorder.is_null() {
        if let Ok(mut value) = unsafe { (*recorder).recorder.lock() } {
            value.finish();
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn macord_recorder_on_video_frame(recorder: *mut RecorderHandle, timestamp_ns: i64) -> bool {
    if recorder.is_null() {
        return false;
    }
    unsafe { (*recorder).recorder.lock().map(|mut value| value.accept_video_frame(timestamp_ns)).unwrap_or(false) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn macord_recorder_on_audio_frame(recorder: *mut RecorderHandle, timestamp_ns: i64) -> bool {
    if recorder.is_null() {
        return false;
    }
    unsafe { (*recorder).recorder.lock().map(|mut value| value.accept_audio_frame(timestamp_ns)).unwrap_or(false) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn macord_recorder_get_stats(recorder: *const RecorderHandle, output: *mut MacordRecorderStats) -> bool {
    if recorder.is_null() || output.is_null() {
        return false;
    }
    let stats = match unsafe { (*recorder).recorder.lock() } {
        Ok(value) => value.stats(),
        Err(_) => return false,
    };
    unsafe { *output = MacordRecorderStats::from(stats) };
    true
}

impl From<FrameStats> for MacordRecorderStats {
    fn from(value: FrameStats) -> Self {
        Self {
            video_frames: value.video_frames,
            audio_frames: value.audio_frames,
            dropped_video_frames: value.dropped_video_frames,
            dropped_audio_frames: value.dropped_audio_frames,
        }
    }
}
