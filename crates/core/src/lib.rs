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
}

impl Recorder {
    pub fn new(config: RecordingConfig) -> Self {
        Self {
            config,
            state: RecorderState::Idle,
        }
    }

    pub fn state(&self) -> RecorderState {
        self.state
    }

    pub fn config(&self) -> RecordingConfig {
        self.config
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
}
