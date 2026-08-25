// Audio on Windows (PORTING module 10). Pebble ships no sound files — every
// effect is synthesized by the shared PebAudioEngine — so all this file does
// is run a feeder thread that renders blocks and hands them to waveOut.
//
// The synth is the SAME code the Mac runs, so a block breaks, a creeper
// hisses and the cave reverb blooms identically on both platforms.

#if os(Windows)

import Foundation
import WinSDK
import PebbleCoreBase
import CPebbleAudio

final class WinAudio {
    let synth = PebAudioEngine()

    /// 512 frames x 4 buffers at 48 kHz ≈ 43 ms of latency — waveOut cannot
    /// do better and it is well under the threshold for hit feedback
    private let frames = 512
    private let buffers = 4
    private var thread: Thread?
    private var running = false

    /// planar render targets + the interleaved block waveOut actually eats
    private var left: [Float]
    private var right: [Float]
    private var mixed: [Float]

    init() {
        left = [Float](repeating: 0, count: frames)
        right = [Float](repeating: 0, count: frames)
        mixed = [Float](repeating: 0, count: frames * 2)
    }

    /// open the device and start feeding it. Silently stays quiet if the
    /// machine has no output device — a missing speaker must never stop the
    /// game from starting.
    func start(volumes: [String: Double]) -> String? {
        if pb_audio_open(48000, Int32(frames), Int32(buffers)) != 0 {
            return String(cString: pb_audio_last_error())
        }
        synth.applyVolumes(volumes)
        synth.start(sampleRate: Double(pb_audio_sample_rate()))
        running = true
        let t = Thread { [weak self] in self?.feed() }
        t.name = "pebble-audio"
        t.stackSize = 512 * 1024
        t.start()
        thread = t
        return nil
    }

    func stop() {
        running = false
        // let the feeder notice before the device goes away under it
        Sleep(30)
        pb_audio_close()
    }

    private func feed() {
        // a block that failed to submit is kept and retried rather than
        // dropped — a lost buffer is an audible click
        var pending = false
        while running {
            if !pending {
                if pb_audio_free_buffers() <= 0 {
                    Sleep(2)         // the device is still chewing; wait a tick
                    continue
                }
                left.withUnsafeMutableBufferPointer { l in
                    right.withUnsafeMutableBufferPointer { r in
                        synth.render(l.baseAddress!, r.baseAddress!, frames)
                    }
                }
                for i in 0..<frames {
                    mixed[i * 2] = left[i]
                    mixed[i * 2 + 1] = right[i]
                }
                pending = true
            }
            let rc = mixed.withUnsafeBufferPointer {
                pb_audio_submit($0.baseAddress, Int32(frames))
            }
            if rc == 0 {
                pending = false
            } else {
                Sleep(2)             // ring full, or a device hiccup — retry
            }
        }
    }
}

#endif
