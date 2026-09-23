import AVFoundation
import AudioToolbox
import CoreAudio

/// Anything live translation can listen to. Delivers 16 kHz mono PCM16 — what
/// the speech-to-text socket wants — plus a 0…1 level for the meter. Both
/// callbacks arrive on a capture thread.
protocol AudioSource: AnyObject {
    var onPCM: (Data) -> Void { get set }
    var onLevel: (Float) -> Void { get set }
    func start() throws
    func stop()
}

extension Recorder: AudioSource {}

/// Everything the Mac is playing — the other side of a call, a video, a browser
/// tab — in the same shape `Recorder` delivers from the microphone.
///
/// A Core Audio process tap reads the system mix below every app. An app can
/// hide its windows from screen capture, but there is no way for it to opt out
/// of this: calls in Zoom, Meet, Teams, FaceTime, Slack or a browser are all
/// just audio being played. Audio headed for AirPods or any other output is
/// caught the same way, because the tap sits before the device.
///
/// The aggregate device holds only the tap. Adding the output device as its
/// clock pins it to that device's rate, and a Bluetooth headset dropping to
/// 24 kHz for a call then stops the stream without an error; it can also drag
/// the headset's microphone in, which switches it to call-quality audio.
@available(macOS 14.2, *)
final class SystemAudio: AudioSource {

    var onPCM: (Data) -> Void = { _ in }
    var onLevel: (Float) -> Void = { _ in }
    /// Capture was rebuilt underneath the caller — for the log and the panel.
    var onRestart: (String) -> Void = { _ in }

    private let queue = DispatchQueue(label: "com.freeze.quill.system-audio", qos: .userInitiated)
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                       channels: 1, interleaved: true)!

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    // Owned by `queue` while capture runs.
    private var converter: AVAudioConverter?
    private var tapFormat: AVAudioFormat?

    private var outputListener: AudioObjectPropertyListenerBlock?
    private var watchdog: Timer?
    private var lastRestartAt = Date.distantPast

    private let counterLock = NSLock()
    private var callbacks = 0
    private var callbacksAtLastCheck = 0
    private var stalledChecks = 0

    private(set) var isRunning = false
    private(set) var formatDescription = "not started"

    func start() throws {
        guard !isRunning else { return }
        try build()
        isRunning = true
        watchOutputDevice()
        startWatchdog()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        watchdog?.invalidate()
        watchdog = nil
        unwatchOutputDevice()
        teardown()
        onLevel(0)
    }

    // MARK: Build and tear down

    private func build() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Quill live translation"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "create the system audio tap")
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        do {
            try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), "read the tap's format")
        } catch {
            teardown()
            throw error
        }
        guard let format = AVAudioFormat(streamDescription: &asbd),
              let converter = AVAudioConverter(from: format, to: target) else {
            teardown()
            throw Self.failure("System audio arrived in a format Quill can't read")
        }
        converter.downmix = true
        formatDescription = "\(Int(format.sampleRate))Hz x\(format.channelCount)"

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Quill System Audio",
            kAudioAggregateDeviceUIDKey: "com.freeze.quill.system-audio.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]

        do {
            var device = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device),
                      "create the capture device")
            aggregateID = device

            queue.sync {
                self.tapFormat = format
                self.converter = converter
            }

            var proc: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { [weak self] _, input, _, _, _ in
                self?.process(input)
            }, "attach to the capture device")
            procID = proc
            try check(AudioDeviceStart(aggregateID, procID), "start capturing")
        } catch {
            teardown()
            throw error
        }
        Log.write("system audio capture started — \(formatDescription)")
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
        queue.sync {
            self.converter = nil
            self.tapFormat = nil
        }
    }

    /// Rebuild from scratch. A tap made for one output device goes stale when
    /// the default output changes — AirPods connecting mid-call is the common
    /// case — and the only reliable repair is a new tap.
    private func restart(because reason: String) {
        guard isRunning else { return }
        guard Date().timeIntervalSince(lastRestartAt) > 2 else { return }
        lastRestartAt = Date()
        Log.write("system audio: rebuilding — \(reason)")
        teardown()
        do {
            try build()
            onRestart(reason)
        } catch {
            Log.write("system audio: rebuild failed — \(error.localizedDescription)")
            onRestart("couldn't reconnect to system audio")
        }
    }

    // MARK: Audio

    private func process(_ input: UnsafePointer<AudioBufferList>) {
        counterLock.lock()
        callbacks &+= 1
        counterLock.unlock()

        guard let format = tapFormat, let converter,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
              buffer.frameLength > 0 else { return }

        if let channels = buffer.floatChannelData {
            let n = Int(buffer.frameLength)
            let count = Int(format.channelCount)
            var sum: Float = 0
            for c in 0..<count {
                for i in 0..<n {
                    let v = channels[c][i]
                    sum += v * v
                }
            }
            onLevel(min(1, sqrt(sum / Float(max(n * count, 1))) * 14))
        }

        let ratio = target.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
        onPCM(Data(bytes: samples[0], count: Int(out.frameLength) * 2))
    }

    // MARK: Keeping it alive

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func watchOutputDevice() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.restart(because: "output device changed")
        }
        outputListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                            &Self.defaultOutputAddress, DispatchQueue.main, listener)
    }

    private func unwatchOutputDevice() {
        guard let listener = outputListener else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &Self.defaultOutputAddress, DispatchQueue.main, listener)
        outputListener = nil
    }

    /// The device keeps calling back with silence while nothing plays, so no
    /// callbacks at all for three seconds means the stream died quietly.
    private func startWatchdog() {
        stalledChecks = 0
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.counterLock.lock()
            let now = self.callbacks
            self.counterLock.unlock()
            self.stalledChecks = (now == self.callbacksAtLastCheck) ? self.stalledChecks + 1 : 0
            self.callbacksAtLastCheck = now
            if self.stalledChecks >= 3 {
                self.stalledChecks = 0
                self.restart(because: "stream stalled")
            }
        }
    }

    // MARK: Errors

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status != noErr else { return }
        throw Self.failure("Couldn't \(what) (error \(status))")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Quill", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// The "System Audio Recording" privacy grant.
///
/// macOS has no public call that reports it — a denied tap simply delivers
/// silence, indistinguishable from nothing playing. The TCC calls below are
/// what the system's own prompt uses; if they ever disappear this degrades to
/// `.unknown` and the system prompts on first capture instead.
enum SystemAudioPermission {
    enum Status { case granted, denied, unknown }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    static var status: Status {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0:  return .granted
        case 1:  return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt when the answer is not yet known. Completes on main.
    static func request(_ done: @escaping (Bool) -> Void) {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else {
            DispatchQueue.main.async { done(true) }
            return
        }
        unsafeBitCast(symbol, to: Request.self)(service, nil) { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }

    static func openSettings() {
        Inserter.openPrivacyPane("Privacy_ScreenCapture")
    }
}
