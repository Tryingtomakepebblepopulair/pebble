// The macOS output sink for the portable synth. Everything that MAKES sound —
// voices, recipes, the mixer, music, discs, the underwater and cave
// treatments — lives in PebbleCoreBase/Audio/PebAudio so Windows gets the
// same audio. This file is only AVAudioEngine plumbing (PORTING module 10).

import AVFoundation
import Foundation
import PebbleCore

final class AudioEngineM {
    let synth = PebAudioEngine()
    private let engine = AVAudioEngine()
    private var srcNode: AVAudioSourceNode!
    private var inited = false

    var volumes: [String: Double] {
        get { synth.volumes }
        set { synth.applyVolumes(newValue) }
    }
    var onSubtitle: ((String) -> Void)? {
        get { synth.onSubtitle }
        set { synth.onSubtitle = newValue }
    }

    func initEngine() {
        if inited { return }
        inited = true
        let format = engine.outputNode.outputFormat(forBus: 0)
        let rate = format.sampleRate > 0 ? format.sampleRate : 48000
        synth.start(sampleRate: rate)
        let renderFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        srcNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let outL = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let outR = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.synth.render(outL, outR, Int(frameCount))
            return noErr
        }
        engine.attach(srcNode)
        engine.connect(srcNode, to: engine.mainMixerNode, format: renderFormat)
        try? engine.start()
    }

    func applyVolumes(_ v: [String: Double]) { synth.applyVolumes(v) }
    func setEnvironment(_ underwater: Bool, _ caveFactor: Double) {
        synth.setEnvironment(underwater, caveFactor)
    }
    func setListener(_ x: Double, _ y: Double, _ z: Double, _ yaw: Double) {
        synth.setListener(x, y, z, yaw)
    }
    func play(_ name: String, _ x: Double, _ y: Double, _ z: Double,
              _ volume: Double = 1, _ pitch: Double = 1) {
        synth.play(name, x, y, z, volume, pitch)
    }
    func playUI(_ name: String) { synth.playUI(name) }
    func playDisc(_ discName: String, _ x: Double, _ y: Double, _ z: Double) {
        synth.playDisc(discName, x, y, z)
    }
    func stopDisc() { synth.stopDisc() }
    func tickMusic(_ mood: String, _ enabled: Bool) { synth.tickMusic(mood, enabled) }
}
