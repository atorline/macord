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

typedef struct {
    uint64_t video_frames;
    uint64_t audio_frames;
    uint64_t dropped_video_frames;
    uint64_t dropped_audio_frames;
} MacordRecorderStats;

MacordRecorder *macord_recorder_create(const MacordRecordingConfig *config);
void macord_recorder_destroy(MacordRecorder *recorder);
bool macord_recorder_start(MacordRecorder *recorder);
void macord_recorder_mark_recording(MacordRecorder *recorder);
bool macord_recorder_stop(MacordRecorder *recorder);
void macord_recorder_finish(MacordRecorder *recorder);
bool macord_recorder_on_video_frame(MacordRecorder *recorder, int64_t timestamp_ns);
bool macord_recorder_on_audio_frame(MacordRecorder *recorder, int64_t timestamp_ns);
bool macord_recorder_get_stats(const MacordRecorder *recorder, MacordRecorderStats *output);

#ifdef __cplusplus
}
#endif

#endif
