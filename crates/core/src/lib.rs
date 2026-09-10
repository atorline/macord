use macord_config::RecordingConfig;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecorderState {
    Idle,
    Preparing,
    Recording,
    Finishing,
    Failed,
}

#[derive(Debug)]
pub struct Recorder {
    config: RecordingConfig,
    state: RecorderState,
    stats: FrameStats,
    last_video_timestamp_ns: Option<i64>,
    last_audio_timestamp_ns: Option<i64>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct FrameStats {
    pub video_frames: u64,
    pub audio_frames: u64,
    pub dropped_video_frames: u64,
    pub dropped_audio_frames: u64,
}

impl Recorder {
    pub fn new(config: RecordingConfig) -> Self {
        Self {
            config,
            state: RecorderState::Idle,
            stats: FrameStats::default(),
            last_video_timestamp_ns: None,
            last_audio_timestamp_ns: None,
        }
    }

    pub fn state(&self) -> RecorderState {
        self.state
    }

    pub fn config(&self) -> RecordingConfig {
        self.config
    }

    pub fn stats(&self) -> FrameStats {
        self.stats
    }

    pub fn accept_video_frame(&mut self, timestamp_ns: i64) -> bool {
        if self.state != RecorderState::Recording || !self.accept_timestamp(self.last_video_timestamp_ns, timestamp_ns) {
            self.stats.dropped_video_frames += 1;
            return false;
        }
        self.last_video_timestamp_ns = Some(timestamp_ns);
        self.stats.video_frames += 1;
        true
    }

    pub fn accept_audio_frame(&mut self, timestamp_ns: i64) -> bool {
        if self.state != RecorderState::Recording || !self.accept_timestamp(self.last_audio_timestamp_ns, timestamp_ns) {
            self.stats.dropped_audio_frames += 1;
            return false;
        }
        self.last_audio_timestamp_ns = Some(timestamp_ns);
        self.stats.audio_frames += 1;
        true
    }

    fn accept_timestamp(&self, previous: Option<i64>, timestamp_ns: i64) -> bool {
        timestamp_ns >= 0 && previous.is_none_or(|value| timestamp_ns >= value)
    }

    pub fn start(&mut self) -> Result<(), &'static str> {
        if self.state != RecorderState::Idle {
            return Err("recorder is not idle");
        }
        self.state = RecorderState::Preparing;
        Ok(())
    }

    pub fn mark_recording(&mut self) {
        if self.state == RecorderState::Preparing {
            self.state = RecorderState::Recording;
        }
    }

    pub fn stop(&mut self) -> Result<(), &'static str> {
        if self.state != RecorderState::Recording {
            return Err("recorder is not recording");
        }
        self.state = RecorderState::Finishing;
        Ok(())
    }

    pub fn finish(&mut self) {
        if self.state == RecorderState::Finishing {
            self.state = RecorderState::Idle;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lifecycle_rejects_invalid_transitions() {
        let mut recorder = Recorder::new(RecordingConfig::default());
        assert!(recorder.stop().is_err());
        recorder.start().unwrap();
        recorder.mark_recording();
        recorder.stop().unwrap();
        assert_eq!(recorder.state(), RecorderState::Finishing);
    }

    #[test]
    fn frame_pipeline_rejects_out_of_order_frames() {
        let mut recorder = Recorder::new(RecordingConfig::default());
        recorder.start().unwrap();
        recorder.mark_recording();
        assert!(recorder.accept_video_frame(10));
        assert!(!recorder.accept_video_frame(9));
        assert_eq!(recorder.stats().video_frames, 1);
        assert_eq!(recorder.stats().dropped_video_frames, 1);
    }
}
