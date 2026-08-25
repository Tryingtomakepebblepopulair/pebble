// Pebble audio sink (PORTING module 10) — waveOut on Windows, stubs
// elsewhere. See include/pebaudio.h for why waveOut and not WASAPI.

#include "pebaudio.h"

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_BUFFERS 8

static char g_err[256];
#define FAIL(...) do { snprintf(g_err, sizeof g_err, __VA_ARGS__); return -1; } while (0)

static HWAVEOUT g_dev;
static WAVEHDR g_hdr[MAX_BUFFERS];
static short* g_data[MAX_BUFFERS];
static int g_bufferCount;
static int g_frames;
static int g_rate;
static int g_next;          // round-robin cursor into the ring

int pb_audio_open(int sampleRate, int frames, int buffers) {
    if (g_dev) return 0;
    if (sampleRate <= 0) sampleRate = 48000;
    if (frames <= 0) frames = 512;
    if (buffers < 2) buffers = 2;
    if (buffers > MAX_BUFFERS) buffers = MAX_BUFFERS;

    WAVEFORMATEX fmt;
    memset(&fmt, 0, sizeof fmt);
    fmt.wFormatTag = WAVE_FORMAT_PCM;      // 16-bit PCM: universally accepted
    fmt.nChannels = 2;
    fmt.nSamplesPerSec = (DWORD)sampleRate;
    fmt.wBitsPerSample = 16;
    fmt.nBlockAlign = (WORD)(fmt.nChannels * fmt.wBitsPerSample / 8);
    fmt.nAvgBytesPerSec = fmt.nSamplesPerSec * fmt.nBlockAlign;
    fmt.cbSize = 0;

    MMRESULT mr = waveOutOpen(&g_dev, WAVE_MAPPER, &fmt, 0, 0, CALLBACK_NULL);
    if (mr != MMSYSERR_NOERROR) {
        g_dev = NULL;
        FAIL("waveOutOpen failed (MMRESULT %u)", (unsigned)mr);
    }

    g_frames = frames;
    g_rate = sampleRate;
    g_bufferCount = buffers;
    g_next = 0;
    size_t bytes = (size_t)frames * 2 * sizeof(short);
    for (int i = 0; i < buffers; i++) {
        g_data[i] = (short*)calloc(1, bytes);
        if (!g_data[i]) {
            pb_audio_close();
            FAIL("out of memory for audio buffers");
        }
        memset(&g_hdr[i], 0, sizeof g_hdr[i]);
        g_hdr[i].lpData = (LPSTR)g_data[i];
        g_hdr[i].dwBufferLength = (DWORD)bytes;
        mr = waveOutPrepareHeader(g_dev, &g_hdr[i], sizeof g_hdr[i]);
        if (mr != MMSYSERR_NOERROR) {
            pb_audio_close();
            FAIL("waveOutPrepareHeader failed (MMRESULT %u)", (unsigned)mr);
        }
        // a prepared-but-never-written header is free to fill
        g_hdr[i].dwFlags |= WHDR_DONE;
    }
    g_err[0] = 0;
    return 0;
}

int pb_audio_free_buffers(void) {
    if (!g_dev) return 0;
    int n = 0;
    for (int i = 0; i < g_bufferCount; i++) {
        if (g_hdr[i].dwFlags & WHDR_DONE) n++;
    }
    return n;
}

int pb_audio_submit(const float* src, int frames) {
    if (!g_dev) return -1;
    if (!src || frames != g_frames) return -1;

    // find the next buffer the device is finished with
    int slot = -1;
    for (int k = 0; k < g_bufferCount; k++) {
        int i = (g_next + k) % g_bufferCount;
        if (g_hdr[i].dwFlags & WHDR_DONE) { slot = i; break; }
    }
    if (slot < 0) return 1;   // ring full — the caller should sleep
    g_next = (slot + 1) % g_bufferCount;

    short* dst = g_data[slot];
    int samples = frames * 2;
    for (int i = 0; i < samples; i++) {
        float s = src[i];
        if (s > 1.0f) s = 1.0f;
        if (s < -1.0f) s = -1.0f;
        dst[i] = (short)(s * 32767.0f);
    }

    // WHDR_DONE survives from the last playback; waveOutWrite rejects a
    // header that still claims to be queued, so clear it before rearming
    g_hdr[slot].dwFlags &= ~WHDR_DONE;
    g_hdr[slot].dwBufferLength = (DWORD)(samples * sizeof(short));
    MMRESULT mr = waveOutWrite(g_dev, &g_hdr[slot], sizeof g_hdr[slot]);
    if (mr != MMSYSERR_NOERROR) {
        g_hdr[slot].dwFlags |= WHDR_DONE;   // give the slot back
        snprintf(g_err, sizeof g_err, "waveOutWrite failed (MMRESULT %u)", (unsigned)mr);
        return -1;
    }
    return 0;
}

int pb_audio_sample_rate(void) { return g_rate; }

void pb_audio_close(void) {
    if (!g_dev) return;
    waveOutReset(g_dev);   // marks every queued header done
    for (int i = 0; i < g_bufferCount; i++) {
        if (g_hdr[i].lpData) waveOutUnprepareHeader(g_dev, &g_hdr[i], sizeof g_hdr[i]);
        free(g_data[i]);
        g_data[i] = NULL;
        memset(&g_hdr[i], 0, sizeof g_hdr[i]);
    }
    waveOutClose(g_dev);
    g_dev = NULL;
    g_bufferCount = 0;
    g_frames = 0;
    g_rate = 0;
    g_next = 0;
}

const char* pb_audio_last_error(void) { return g_err; }

#else   // !_WIN32 — every platform builds this target; only Windows uses it

static const char* kNotWindows = "the waveOut sink is Windows-only; macOS uses AVAudioEngine";
int pb_audio_open(int sampleRate, int frames, int buffers) {
    (void)sampleRate; (void)frames; (void)buffers; return -1;
}
int pb_audio_free_buffers(void) { return 0; }
int pb_audio_submit(const float* src, int frames) { (void)src; (void)frames; return -1; }
int pb_audio_sample_rate(void) { return 0; }
void pb_audio_close(void) {}
const char* pb_audio_last_error(void) { return kNotWindows; }

#endif
