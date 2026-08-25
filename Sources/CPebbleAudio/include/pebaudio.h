// Pebble audio sink — C ABI (PORTING module 10). Pebble ships no sound
// files: every effect is synthesized in PebbleCoreBase/Audio/PebAudio, so a
// platform only has to hand finished stereo samples to the speakers.
//
// Windows uses winmm's waveOut. Deliberately not WASAPI or XAudio2: both are
// COM, and this is a plain-C ring of eight calls that has shipped in every
// Windows since 1991. No SDK to install, no library to vendor. Stubs
// elsewhere so every platform builds the target.

#ifndef PEBAUDIO_H
#define PEBAUDIO_H

#ifdef __cplusplus
extern "C" {
#endif

// open the default output device. `frames` is the buffer size in stereo
// frames, `buffers` how many are in flight (latency = frames*buffers/rate).
// Returns 0 on success — anything else: read pb_audio_last_error().
int pb_audio_open(int sampleRate, int frames, int buffers);

// how many ring buffers are free to refill right now (0 = the device is
// still busy with all of them; the feeder should sleep briefly)
int pb_audio_free_buffers(void);

// hand over one buffer of interleaved stereo float in [-1, 1]. `frames` must
// match the value passed to pb_audio_open. Returns 0 on success, 1 when the
// ring is full (nothing was consumed), -1 on a device error.
int pb_audio_submit(const float* interleavedStereo, int frames);

// the rate the device actually opened at (0 before open)
int pb_audio_sample_rate(void);

void pb_audio_close(void);

// human-readable reason for the last failure (static buffer)
const char* pb_audio_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
