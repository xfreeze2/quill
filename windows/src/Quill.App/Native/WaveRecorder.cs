using System.Runtime.InteropServices;
using Quill;

namespace Quill.Win.Native;

/// <summary>
/// WASAPI-via-WinMM capture, resampled to 16 kHz mono PCM16 for the STT socket.
/// Built fresh for every recording — a handle opened before the microphone was
/// granted can stay silent for the rest of the process.
/// </summary>
sealed class WaveRecorder : IRecorder
{
    const int TargetRate = 16000;
    const int BufferBytes = 3200; // 100ms at 16 kHz 16-bit mono
    const int BufferCount = 4;

    readonly List<GCHandle> _pins = [];
    readonly List<IntPtr> _headers = [];
    Win32.WaveInProc? _proc;
    IntPtr _handle;
    int _sourceRate = TargetRate;
    bool _running;

    public bool IsRunning => _running;
    public int FramesCaptured { get; private set; }
    public float PeakLevel { get; private set; }
    public string InputDescription { get; private set; } = "unknown";
    public Action<byte[]> OnPcm { get; set; } = _ => { };
    public Action<float> OnLevel { get; set; } = _ => { };

    public static string DefaultInputName()
    {
        if (Win32.waveInGetDevCaps(UIntPtr.Zero, out var caps, Marshal.SizeOf<Win32.WAVEINCAPS>()) == 0)
            return caps.szPname;
        return "default";
    }

    public void Start()
    {
        if (_running) return;
        FramesCaptured = 0;
        PeakLevel = 0;
        _proc = Callback;

        var format = Pcm(TargetRate);
        var result = Win32.waveInOpen(out _handle, Win32.WAVE_MAPPER, ref format, _proc, IntPtr.Zero, Win32.CALLBACK_FUNCTION);
        if (result != 0)
        {
            format = Pcm(48000);
            result = Win32.waveInOpen(out _handle, Win32.WAVE_MAPPER, ref format, _proc, IntPtr.Zero, Win32.CALLBACK_FUNCTION);
            if (result != 0)
            {
                format = Pcm(44100);
                result = Win32.waveInOpen(out _handle, Win32.WAVE_MAPPER, ref format, _proc, IntPtr.Zero, Win32.CALLBACK_FUNCTION);
            }
        }
        if (result != 0 || _handle == IntPtr.Zero)
            throw new InvalidOperationException("No microphone input device available — check Sound ▸ Input.");

        _sourceRate = (int)format.nSamplesPerSec;
        InputDescription = $"{DefaultInputName()} @ {_sourceRate}Hz x1";

        var headerSize = Marshal.SizeOf<Win32.WAVEHDR>();
        for (var i = 0; i < BufferCount; i++)
        {
            var data = new byte[BufferBytes];
            var pin = GCHandle.Alloc(data, GCHandleType.Pinned);
            _pins.Add(pin);
            var hdr = new Win32.WAVEHDR
            {
                lpData = pin.AddrOfPinnedObject(),
                dwBufferLength = (uint)BufferBytes,
            };
            var hdrPtr = Marshal.AllocHGlobal(headerSize);
            Marshal.StructureToPtr(hdr, hdrPtr, false);
            _headers.Add(hdrPtr);
            Win32.waveInPrepareHeader(_handle, hdrPtr, headerSize);
            Win32.waveInAddBuffer(_handle, hdrPtr, headerSize);
        }

        if (Win32.waveInStart(_handle) != 0)
        {
            Stop();
            throw new InvalidOperationException("Could not start the microphone.");
        }
        _running = true;
    }

    public void Stop()
    {
        if (!_running && _handle == IntPtr.Zero) return;
        _running = false;
        if (_handle != IntPtr.Zero)
        {
            Win32.waveInStop(_handle);
            Win32.waveInReset(_handle);
            var headerSize = Marshal.SizeOf<Win32.WAVEHDR>();
            foreach (var h in _headers)
            {
                Win32.waveInUnprepareHeader(_handle, h, headerSize);
                Marshal.FreeHGlobal(h);
            }
            Win32.waveInClose(_handle);
            _handle = IntPtr.Zero;
        }
        foreach (var p in _pins) if (p.IsAllocated) p.Free();
        _pins.Clear();
        _headers.Clear();
        _proc = null;
        OnLevel(0);
    }

    void Callback(IntPtr hwi, uint uMsg, IntPtr dwInstance, IntPtr dwParam1, IntPtr dwParam2)
    {
        if (uMsg != Win32.WIM_DATA || !_running) return;
        var hdr = Marshal.PtrToStructure<Win32.WAVEHDR>(dwParam1);
        var n = (int)hdr.dwBytesRecorded;
        if (n > 0)
        {
            var raw = new byte[n];
            Marshal.Copy(hdr.lpData, raw, 0, n);
            Observe(raw);
            var pcm = _sourceRate == TargetRate ? raw : Resample(raw, _sourceRate, TargetRate);
            if (pcm.Length > 0) OnPcm(pcm);
        }
        if (_running && _handle != IntPtr.Zero)
        {
            hdr.dwBytesRecorded = 0;
            Marshal.StructureToPtr(hdr, dwParam1, false);
            Win32.waveInAddBuffer(_handle, dwParam1, Marshal.SizeOf<Win32.WAVEHDR>());
        }
    }

    void Observe(byte[] pcm16)
    {
        var samples = pcm16.Length / 2;
        if (samples == 0) return;
        double sum = 0;
        for (var i = 0; i < samples; i++)
        {
            var s = BitConverter.ToInt16(pcm16, i * 2) / 32768.0;
            sum += s * s;
        }
        var rms = (float)Math.Sqrt(sum / samples);
        FramesCaptured += samples;
        if (rms > PeakLevel) PeakLevel = rms;
        OnLevel(Math.Min(1, rms * 14));
    }

    static byte[] Resample(byte[] pcm16, int fromHz, int toHz)
    {
        var inSamples = pcm16.Length / 2;
        var outSamples = (int)((long)inSamples * toHz / fromHz);
        if (outSamples <= 0) return [];
        var output = new byte[outSamples * 2];
        for (var i = 0; i < outSamples; i++)
        {
            var src = (double)i * fromHz / toHz;
            var i0 = (int)src;
            var i1 = Math.Min(i0 + 1, inSamples - 1);
            var t = src - i0;
            var s0 = BitConverter.ToInt16(pcm16, i0 * 2);
            var s1 = BitConverter.ToInt16(pcm16, i1 * 2);
            var mixed = (short)(s0 + (s1 - s0) * t);
            output[i * 2] = (byte)(mixed & 0xff);
            output[i * 2 + 1] = (byte)((mixed >> 8) & 0xff);
        }
        return output;
    }

    static Win32.WAVEFORMATEX Pcm(int rate) => new()
    {
        wFormatTag = Win32.WAVE_FORMAT_PCM,
        nChannels = 1,
        nSamplesPerSec = (uint)rate,
        wBitsPerSample = 16,
        nBlockAlign = 2,
        nAvgBytesPerSec = (uint)(rate * 2),
        cbSize = 0,
    };
}
