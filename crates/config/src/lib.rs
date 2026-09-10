use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
pub enum VideoCodec {
    H264,
    Hevc,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
pub enum CaptureResolution {
    Source,
    P720,
    P1080,
    P1440,
    P2160,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
pub struct RecordingConfig {
    pub resolution: CaptureResolution,
    pub fps: u32,
    pub codec: VideoCodec,
    pub microphone_enabled: bool,
    pub system_audio_enabled: bool,
}

impl Default for RecordingConfig {
    fn default() -> Self {
        Self {
            resolution: CaptureResolution::Source,
            fps: 60,
            codec: VideoCodec::H264,
            microphone_enabled: true,
            system_audio_enabled: false,
        }
    }
}
