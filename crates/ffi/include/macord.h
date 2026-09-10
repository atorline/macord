#ifndef MACORD_H
#define MACORD_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int32_t resolution;
    int32_t fps;
    int32_t codec;
    bool microphone_enabled;
    bool system_audio_enabled;
} MacordRecordingConfig;

typedef struct MacordRecorder MacordRecorder;

MacordRecorder *macord_recorder_create(const MacordRecordingConfig *config);
void macord_recorder_destroy(MacordRecorder *recorder);
bool macord_recorder_start(MacordRecorder *recorder);
void macord_recorder_mark_recording(MacordRecorder *recorder);
bool macord_recorder_stop(MacordRecorder *recorder);
void macord_recorder_finish(MacordRecorder *recorder);

#ifdef __cplusplus
}
#endif

#endif
