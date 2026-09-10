use std::ffi::c_int;

use macord_config::{CaptureResolution, RecordingConfig, VideoCodec};
use macord_core::Recorder;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MacordRecordingConfig {
    pub resolution: c_int,
    pub fps: c_int,
    pub codec: c_int,
    pub microphone_enabled: bool,
    pub system_audio_enabled: bool,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn macord_recorder_create(config: *const MacordRecordingConfig) -> *mut Recorder {
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
    Box::into_raw(Box::new(Recorder::new(config)))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn macord_recorder_destroy(recorder: *mut Recorder) {
    if !recorder.is_null() {
        unsafe {
            drop(Box::from_raw(recorder));
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn macord_recorder_start(recorder: *mut Recorder) -> bool {
    if recorder.is_null() {
        return false;
    }
    unsafe { (*recorder).start().is_ok() }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn macord_recorder_mark_recording(recorder: *mut Recorder) {
    if !recorder.is_null() {
        unsafe { (*recorder).mark_recording() };
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn macord_recorder_stop(recorder: *mut Recorder) -> bool {
    if recorder.is_null() {
        return false;
    }
    unsafe { (*recorder).stop().is_ok() }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn macord_recorder_finish(recorder: *mut Recorder) {
    if !recorder.is_null() {
        unsafe { (*recorder).finish() };
    }
}
