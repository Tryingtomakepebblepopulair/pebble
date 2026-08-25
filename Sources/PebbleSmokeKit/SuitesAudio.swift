// Audio goldens: the synthesized engine renders offline, so what a Windows
// machine hears can be checked on a Mac (and in headless CI) without a sound
// device anywhere in sight — PORTING module 10's verification gate.

import Foundation
import PebbleCoreBase

/// render `blocks` of stereo and report when sound first appears and how loud
/// it gets. Time is in seconds from the engine's start.
private func renderPeak(_ e: PebAudioEngine, blocks: Int,
                        frames: Int = 512, rate: Double = 48000) -> (first: Double, peak: Float) {
    var l = [Float](repeating: 0, count: frames)
    var r = [Float](repeating: 0, count: frames)
    var peak: Float = 0
    var first = -1.0
    for b in 0..<blocks {
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                e.render(lp.baseAddress!, rp.baseAddress!, frames)
            }
        }
        for i in 0..<frames {
            let a = max(abs(l[i]), abs(r[i]))
            if a > 0.0001 && first < 0 { first = Double(b * frames + i) / rate }
            peak = max(peak, a)
        }
    }
    return (first, peak)
}

private func engine(_ volumes: [String: Double]? = nil) -> PebAudioEngine {
    let e = PebAudioEngine()
    e.applyVolumes(volumes ?? Settings().volumes)
    e.start(sampleRate: 48000)
    e.setListener(0, 0, 0, 0)
    return e
}

/// the synth actually makes sound, the mixer respects volumes and distance
public func smokeAudioSuite() {
    section("audio: synth, mixer, volumes (offline render)")

    var e = engine()
    e.playUI("ui.button.click")
    check("UI click is audible", renderPeak(e, blocks: 40).peak > 0.0001)

    e = engine()
    e.play("entity.item.pickup", 1, 0, 1, 1, 1)
    check("positional sound nearby is audible", renderPeak(e, blocks: 40).peak > 0.0001)

    e = engine()
    e.play("entity.item.pickup", 500, 0, 500, 1, 1)
    check("out of range is silent", renderPeak(e, blocks: 20).peak == 0)

    var muted = Settings().volumes
    muted["master"] = 0
    e = engine(muted)
    e.playUI("ui.button.click")
    check("master at 0 is silent", renderPeak(e, blocks: 20).peak == 0)

    // a near sound must beat the same sound far away — the distance
    // attenuation is squared, so this is a wide margin
    e = engine()
    e.play("entity.generic.explode", 0, 0, 1, 1, 1)
    let near = renderPeak(e, blocks: 40).peak
    e = engine()
    e.play("entity.generic.explode", 0, 0, 14, 1, 1)
    let far = renderPeak(e, blocks: 40).peak
    check("distance attenuates", near > far * 1.5, "near \(near) far \(far)")

    e = engine()
    e.setEnvironment(true, 0)
    e.play("entity.generic.explode", 0, 0, 1, 1, 1)
    check("underwater lowpass still passes sound", renderPeak(e, blocks: 40).peak > 0.0001)

    // a 60-second disc schedules ~600 voices up front. The scheduled-voice
    // cap used to evict the EARLIEST of them, so the disc stayed silent for
    // its first ~23 seconds — this pins the first note where it belongs.
    e = engine()
    e.playDisc("jukebox.play.wander", 0, 0, 0)
    let disc = renderPeak(e, blocks: 400)
    check("disc starts on schedule", disc.first > 0 && disc.first < 0.5,
          "first sound at \(disc.first)s")
    check("disc is audible", disc.peak > 0.0001)

    // generative music only starts once its countdown expires
    e = engine()
    var ticks = 0
    while e.musicTimer > 0 && ticks < 6000 {
        e.tickMusic("calm", true)
        ticks += 1
    }
    e.tickMusic("calm", true)
    check("generative music plays after its timer", renderPeak(e, blocks: 200).peak > 0.0001)
}
