import Foundation

/// PugglePhotos' own slideshow tune, made from scratch rather than recorded: soft chords, a low note on the first
/// and third beats, and a music-box melody over them, with a gentle echo. Eight bars in C major at 70 beats a
/// minute, which loop without a seam.
public enum Soundtrack {
    public static let tempo = 70.0
    public static let bars = 8
    static let beatsPerBar = 4.0

    public static var loopSeconds: Double { Double(bars) * beatsPerBar * 60 / tempo }

    /// The chords, as MIDI note numbers: the first is the bass, the rest the soft chord above it.
    static let chords: [[Int]] = [
        [48, 55, 60, 64], // C
        [43, 55, 59, 62], // G
        [45, 57, 60, 64], // A minor
        [41, 57, 60, 65], // F
        [48, 55, 60, 64], // C
        [40, 55, 59, 64], // E minor
        [41, 57, 60, 65], // F
        [43, 55, 59, 62], // G
    ]

    /// Each chord's notes for the music box, around the C above middle C.
    static let arpeggios: [[Int]] = [
        [72, 76, 79, 84], // C E G C
        [71, 74, 79, 83], // B D G B
        [72, 76, 81, 84], // C E A C
        [72, 77, 81, 84], // C F A C
        [72, 76, 79, 84], // C E G C
        [71, 76, 79, 83], // B E G B
        [72, 77, 81, 84], // C F A C
        [71, 74, 79, 83], // B D G B
    ]

    /// The melody's notes in each bar, as places in the chord's arpeggio (low to high); nil is a rest.
    static let pattern: [[Int?]] = [
        [0, 2, 1, 2, 3, 2, 1, 2],
        [3, 2, 1, 2, 0, 1, 2, nil],
    ]

    /// The loop as interleaved stereo samples (left, right, left, right…), peaking at 0.6.
    public static func render(sampleRate: Int = 44_100) -> [Float] {
        let rate = Double(sampleRate)
        let beat = 60 / tempo
        let bar = beat * beatsPerBar
        let loopFrames = Int((loopSeconds * rate).rounded())
        let tailFrames = Int(4 * rate)
        var left = [Float](repeating: 0, count: loopFrames + tailFrames)
        var right = left

        func frequency(_ note: Int) -> Double { 440 * pow(2, Double(note - 69) / 12) }

        /// Adds a note: a sum of harmonics, shaped by an attack and an exponential (or held, then released) fade.
        func note(at start: Double, length: Double, midi: Int, amplitude: Double, pan: Double,
                  harmonics: [(multiple: Double, level: Double, decay: Double)], attack: Double, decay: Double?, release: Double) {
            let first = Int(start * rate)
            let held = length * rate
            let end = min(left.count, first + Int((length + release) * rate))
            guard first < end else { return }
            let leftGain = amplitude * sqrt(0.5 * (1 - pan)), rightGain = amplitude * sqrt(0.5 * (1 + pan))
            for harmonic in harmonics {
                let step = 2 * Double.pi * frequency(midi) * harmonic.multiple / rate
                guard step < Double.pi else { continue }
                // A rotating phasor: two multiplications a sample instead of a sine.
                let (cosStep, sinStep) = (cos(step), sin(step))
                var (s, c) = (0.0, 1.0)
                for frame in first..<end {
                    let t = Double(frame - first)
                    var envelope = min(1, t / (attack * rate))
                    if let decay {
                        envelope *= exp(-t / (decay * harmonic.decay * rate))
                    } else if t > held {
                        envelope *= max(0, 1 - (t - held) / (release * rate))
                    }
                    let value = s * harmonic.level * envelope
                    left[frame] += Float(value * leftGain)
                    right[frame] += Float(value * rightGain)
                    (s, c) = (s * cosStep + c * sinStep, c * cosStep - s * sinStep)
                }
            }
        }

        for (index, chord) in chords.enumerated() {
            let barStart = Double(index) * bar
            // The bass, on beats one and three.
            for half in 0..<2 {
                note(at: barStart + Double(half) * 2 * beat, length: 2 * beat, midi: chord[0], amplitude: 0.16, pan: 0,
                     harmonics: [(1, 1, 1), (2, 0.18, 0.6)], attack: 0.012, decay: 1.1, release: 2)
            }
            // The chord: each note twice, a hair apart, for warmth; it swells in and fades as the next comes.
            for (voice, midi) in chord.dropFirst().enumerated() {
                let pan = voice % 2 == 0 ? -0.25 : 0.25
                for detune in [-0.0012, 0.0012] {
                    note(at: barStart, length: bar, midi: midi, amplitude: 0.045, pan: pan,
                         harmonics: [(1 + detune, 1, 1), (2 + detune, 0.12, 1)], attack: 0.9, decay: nil, release: 1.3)
                }
            }
            // The music box: the chord's notes up high, in eighth notes.
            let tones = arpeggios[index]
            for (eighth, place) in pattern[index % 2].enumerated() {
                guard let place else { continue }
                note(at: barStart + Double(eighth) * beat / 2, length: beat / 2, midi: tones[place], amplitude: 0.11,
                     pan: eighth % 2 == 0 ? -0.35 : 0.35, harmonics: [(1, 1, 1), (2, 0.22, 0.5), (4, 0.06, 0.25)],
                     attack: 0.004, decay: 0.55, release: 2.5)
            }
        }

        // A soft echo: each side repeats a little later and quieter, with the highs rolled off.
        let delays = (Int(0.33 * rate), Int(0.44 * rate))
        var (lastLeft, lastRight): (Float, Float) = (0, 0)
        var wetLeft = [Float](repeating: 0, count: left.count), wetRight = wetLeft
        for frame in 0..<left.count {
            let inLeft = frame >= delays.0 ? left[frame - delays.0] + 0.3 * wetRight[frame - delays.0] : 0
            let inRight = frame >= delays.1 ? right[frame - delays.1] + 0.3 * wetLeft[frame - delays.1] : 0
            lastLeft += 0.35 * (inLeft - lastLeft)
            lastRight += 0.35 * (inRight - lastRight)
            wetLeft[frame] = lastLeft
            wetRight[frame] = lastRight
        }
        for frame in 0..<left.count {
            left[frame] += 0.22 * wetLeft[frame]
            right[frame] += 0.22 * wetRight[frame]
        }

        // What rings past the end of the loop sounds again at its start, so the loop has no seam.
        for frame in 0..<tailFrames {
            left[frame] += left[loopFrames + frame]
            right[frame] += right[loopFrames + frame]
        }
        var samples = [Float](repeating: 0, count: loopFrames * 2)
        var peak: Float = 0
        for frame in 0..<loopFrames {
            samples[frame * 2] = left[frame]
            samples[frame * 2 + 1] = right[frame]
            peak = max(peak, abs(left[frame]), abs(right[frame]))
        }
        if peak > 0 {
            let scale = 0.6 / peak
            for index in samples.indices { samples[index] *= scale }
        }
        return samples
    }

    /// Interleaved samples as a 16-bit PCM WAV file.
    public static func wav(_ samples: [Float], sampleRate: Int = 44_100, channels: Int = 2) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * channels * 2))
        append(UInt16(channels * 2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(bytes))
        data.reserveCapacity(data.count + bytes)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * 32_767))
        }
        return data
    }
}
