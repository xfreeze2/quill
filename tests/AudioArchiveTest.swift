// Keeping the sound of a meeting: mixing, compressing, and recovering after a crash.
import AVFoundation
import Foundation

enum Log { static func write(_ message: String) {} }

@main
enum AudioArchiveTest {

    static func tone(_ hz: Double, seconds: Double, amplitude: Double = 0.5) -> Data {
        let count = Int(seconds * 16_000)
        var out = Data(count: count * 2)
        out.withUnsafeMutableBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            for index in 0..<count {
                values[index] = Int16(sin(2 * .pi * hz * Double(index) / 16_000) * amplitude * 32_000)
            }
        }
        return out
    }

    static func wait(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(20)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    static func samples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    static func main() {
        let check = Check()

        // Mixing.
        let a = Data([0x10, 0x00, 0x20, 0x00])                     // 16, 32
        let b = Data([0x01, 0x00])                                  // 1
        check.equal("the shorter source is padded", samples(AudioArchive.mix([a, b])), [17, 32])
        let loud = tone(440, seconds: 0.1, amplitude: 0.9)
        let clipped = samples(AudioArchive.mix([loud, loud, loud]))
        check.isTrue("loud overlap clips instead of wrapping", clipped.allSatisfy { $0 >= Int16.min && $0 <= Int16.max }
            && clipped.contains(Int16.max))
        check.isTrue("nothing mixes to nothing", AudioArchive.mix([]).isEmpty)

        // A kept meeting.
        let dir = scratchDirectory("audio")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("one")
        let archive = AudioArchive(folder: folder)
        let you = tone(300, seconds: 3)
        let them = tone(500, seconds: 2)
        stride(from: 0, to: you.count, by: 3_200).forEach { archive.append(lane: 0, pcm: you.subdata(in: $0..<min($0 + 3_200, you.count))) }
        stride(from: 0, to: them.count, by: 3_200).forEach { archive.append(lane: 1, pcm: them.subdata(in: $0..<min($0 + 3_200, them.count))) }
        var done: Bool?
        archive.finish { done = $0 }
        wait { done != nil }
        check.equal("it finished", done, true)
        let url = AudioArchive.finalURL(in: folder)
        check.isTrue("there is an audio file", FileManager.default.fileExists(atPath: url.path))
        let length = (try? AVAudioFile(forReading: url))?.length ?? 0
        let seconds = Double(length) / 16_000
        check.isTrue("as long as the longest source (got \(seconds)s)", abs(seconds - 3) < 0.2)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        check.isTrue("and small (\(size) bytes for 3 s)", size > 1_000 && size < 40_000)
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".raw") }
        check.isTrue("the plain files are gone", leftovers.isEmpty)
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
        check.equal("readable by the user alone", mode, 0o600)

        // The sound really is in it: decode and look for energy.
        if let file = try? AVAudioFile(forReading: url),
           let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000),
           (try? file.read(into: buffer, frameCount: 16_000)) != nil, let channel = buffer.floatChannelData?[0] {
            var peak: Float = 0
            for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channel[index])) }
            check.isTrue("it is not silence (peak \(peak))", peak > 0.2)
        } else {
            check.isTrue("it can be played back", false)
        }

        // A crash mid-meeting leaves the plain files; the next launch turns them into the recording.
        let crashed = dir.appendingPathComponent("crashed")
        AppSupport.ensure(crashed)
        try? tone(400, seconds: 2).write(to: crashed.appendingPathComponent("lane-0.raw"))
        check.isTrue("recovery produces the recording", AudioArchive.recover(folder: crashed))
        check.isTrue("and the recording exists", FileManager.default.fileExists(atPath: AudioArchive.finalURL(in: crashed).path))
        check.isTrue("nothing to recover in an empty folder", !AudioArchive.recover(folder: dir.appendingPathComponent("empty")))

        check.finish()
    }
}
