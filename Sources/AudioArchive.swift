import AVFoundation
import Foundation

/// Keeps the sound of a meeting — only when the person chose to.
///
/// Each source's audio is appended to a plain file as it arrives, so a crash
/// loses nothing; at the end the sources are mixed into one small `audio.m4a`
/// and the plain files are removed. All of it is 16 kHz mono, which is all
/// speech needs: about 14 MB an hour.
final class AudioArchive {

    static let sampleRate = 16_000
    /// Bytes of 16-bit mono audio in one second.
    static let bytesPerSecond = sampleRate * 2

    private let folder: URL
    private let queue = DispatchQueue(label: "com.freeze.quill.audio-archive", qos: .utility)
    private var handles: [Int: FileHandle] = [:]
    private var failed = false

    init(folder: URL) {
        self.folder = folder
        AppSupport.ensure(folder)
    }

    private static func rawURL(_ folder: URL, lane: Int) -> URL {
        folder.appendingPathComponent("lane-\(lane).raw")
    }

    static func finalURL(in folder: URL) -> URL {
        folder.appendingPathComponent("audio.m4a")
    }

    /// Called from the main thread with each chunk a source delivers.
    func append(lane: Int, pcm: Data) {
        queue.async { [self] in
            guard !failed else { return }
            if handles[lane] == nil {
                let url = Self.rawURL(folder, lane: lane)
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                guard let handle = try? FileHandle(forWritingTo: url) else {
                    failed = true
                    return
                }
                handles[lane] = handle
            }
            handles[lane]?.write(pcm)
        }
    }

    /// Mixes and compresses what was kept. `completion` runs on the main queue with
    /// whether there is now an `audio.m4a`.
    func finish(completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            for handle in handles.values { try? handle.close() }
            handles = [:]
            let ok = !failed && Self.assemble(folder: folder)
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Whether `folder` still holds plain files waiting to become a recording.
    static func hasLeftovers(folder: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { $0.hasPrefix("lane-") && $0.hasSuffix(".raw") }
    }

    /// A recording that was cut short leaves the plain files behind. Turns them
    /// into the audio file, so a crash costs nothing.
    @discardableResult
    static func recover(folder: URL) -> Bool {
        assemble(folder: folder)
    }

    /// Everything kept in `folder` becomes `audio.m4a`, and the plain files go.
    private static func assemble(folder: URL) -> Bool {
        let lanes = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("lane-") && $0.pathExtension == "raw" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !lanes.isEmpty else { return false }

        let target = finalURL(in: folder)
        try? FileManager.default.removeItem(at: target)
        do {
            try encode(lanes: lanes, to: target)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            lanes.forEach { try? FileManager.default.removeItem(at: $0) }
            return true
        } catch {
            // The plain files stay, so the next launch can try again.
            try? FileManager.default.removeItem(at: target)
            Log.write("meeting audio: couldn't write the recording — \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Mixing

    /// Adds sources together sample by sample, the shorter ones padded with
    /// silence, clipping rather than wrapping when they overlap loudly.
    static func mix(_ sources: [Data]) -> Data {
        guard let longest = sources.map(\.count).max(), longest > 1 else { return Data() }
        let samples = longest / 2
        var total = [Int32](repeating: 0, count: samples)
        for source in sources {
            source.withUnsafeBytes { raw in
                let values = raw.bindMemory(to: Int16.self)
                for index in 0..<min(samples, values.count) { total[index] += Int32(values[index]) }
            }
        }
        var out = Data(count: samples * 2)
        out.withUnsafeMutableBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            for index in 0..<samples {
                values[index] = Int16(max(Int32(Int16.min), min(Int32(Int16.max), total[index])))
            }
        }
        return out
    }

    private static func encode(lanes: [URL], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings,
                                                 commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file!.processingFormat
        let handles = try lanes.map { try FileHandle(forReadingFrom: $0) }
        defer { handles.forEach { try? $0.close() } }

        let second = bytesPerSecond
        while true {
            let slices = handles.map { $0.readData(ofLength: second) }
            let mixed = slices.count == 1 ? slices[0] : mix(slices)
            let frames = mixed.count / 2
            if frames == 0 { break }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let channel = buffer.floatChannelData?[0] else { break }
            buffer.frameLength = AVAudioFrameCount(frames)
            mixed.withUnsafeBytes { raw in
                let values = raw.bindMemory(to: Int16.self)
                for index in 0..<frames { channel[index] = Float(values[index]) / 32_768 }
            }
            try file?.write(from: buffer)
        }
        file = nil
    }
}
