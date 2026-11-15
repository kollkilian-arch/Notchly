import Foundation

/// Small sound effects synthesised in code (no audio files to ship or license).
/// Each is a few layers of decaying noise and sine "voices", rendered to a 16-bit mono WAV.
enum SynthSounds {
    static let sampleRate = 44_100.0

    /// A lock closing: one clean clack. Sharp latch click, a short low thunk and a faint metallic ring.
    static func lockClack() -> Data {
        render(length: 0.18) { s in
            noise(&s, at: 0.000, amp: 0.90, decay: 0.0012, dur: 0.012, seed: 7)                 // latch click
            tone(&s, at: 0.000, from: 210, to: 130, amp: 0.70, decay: 0.028, dur: 0.16)         // body thunk
            tone(&s, at: 0.001, from: 2350, to: 2350, amp: 0.16, decay: 0.010, dur: 0.06)       // metal ring
            tone(&s, at: 0.001, from: 3620, to: 3620, amp: 0.09, decay: 0.007, dur: 0.05)
        }
    }

    /// The same lock opening: lighter and higher, with two quick taps instead of one heavy one.
    static func unlockClick() -> Data {
        render(length: 0.22) { s in
            noise(&s, at: 0.000, amp: 0.70, decay: 0.0010, dur: 0.010, seed: 31)
            tone(&s, at: 0.000, from: 340, to: 250, amp: 0.38, decay: 0.020, dur: 0.11)
            tone(&s, at: 0.001, from: 3000, to: 3000, amp: 0.14, decay: 0.008, dur: 0.05)
            noise(&s, at: 0.058, amp: 0.46, decay: 0.0011, dur: 0.010, seed: 43)
            tone(&s, at: 0.058, from: 430, to: 330, amp: 0.22, decay: 0.016, dur: 0.09)
            tone(&s, at: 0.059, from: 3900, to: 3900, amp: 0.08, decay: 0.006, dur: 0.04)
        }
    }

    // MARK: Building blocks

    /// A decaying sine whose pitch glides from `from` to `to` Hz.
    private static func tone(_ s: inout [Float], at start: Double, from f0: Double, to f1: Double,
                             amp: Float, decay: Double, dur: Double) {
        let first = Int(start * sampleRate), count = Int(dur * sampleRate)
        var phase = 0.0
        for i in 0..<count where first + i < s.count {
            let t = Double(i) / sampleRate
            let f = f0 + (f1 - f0) * min(t / dur, 1)
            phase += 2 * .pi * f / sampleRate
            let attack = min(t / 0.0004, 1)                      // 0.4 ms ramp: no speaker pop
            s[first + i] += Float(sin(phase) * exp(-t / decay) * attack) * amp
        }
    }

    /// A burst of high-passed noise (the "click"). Seeded so the sound is identical every time.
    private static func noise(_ s: inout [Float], at start: Double, amp: Float, decay: Double,
                              dur: Double, seed: UInt32) {
        let first = Int(start * sampleRate), count = Int(dur * sampleRate)
        var state = seed, low: Float = 0
        for i in 0..<count where first + i < s.count {
            state = state &* 1_664_525 &+ 1_013_904_223
            let white = Float(Int32(bitPattern: state)) / Float(Int32.max)
            low += 0.35 * (white - low)                          // one-pole low-pass ...
            let high = white - low                               // ... subtracted = high-pass
            let t = Double(i) / sampleRate
            let attack = Float(min(t / 0.0002, 1))
            s[first + i] += high * Float(exp(-t / decay)) * attack * amp
        }
    }

    /// Mixes the layers, normalises to a safe peak, fades the tail and wraps everything as a WAV.
    private static func render(length: Double, _ build: (inout [Float]) -> Void) -> Data {
        var samples = [Float](repeating: 0, count: Int(length * sampleRate))
        build(&samples)

        let peak = max(samples.map { abs($0) }.max() ?? 1, 0.0001)
        let gain = 0.85 / peak
        let fade = Int(0.004 * sampleRate)
        for i in 0..<fade { samples[samples.count - 1 - i] *= Float(i) / Float(fade) }   // 4 ms fade-out

        let pcm = samples.map { Int16(clamping: Int(($0 * gain * 32_767).rounded())) }
        return wav(pcm)
    }

    private static func wav(_ pcm: [Int16]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataSize = UInt32(pcm.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)          // PCM, mono
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2); u16(2); u16(16)       // rate, byte rate, align, bits
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        for sample in pcm { u16(UInt16(bitPattern: sample)) }
        return d
    }
}
