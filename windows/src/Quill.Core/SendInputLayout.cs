using System.Runtime.InteropServices;

namespace Quill;

/// <summary>
/// Win32 INPUT layout. On x64/ARM64 this must be 40 bytes — the union is sized
/// to MOUSEINPUT, not KEYBDINPUT. A 32-byte struct makes SendInput return 0
/// and the keypress never reaches the focused app.
/// </summary>
public static class SendInputLayout
{
    public const int X64Size = 40;
    public const uint InputKeyboard = 1;
    public const uint KeyeventfKeyup = 0x0002;
    public const uint KeyeventfUnicode = 0x0004;
    public const uint KeyeventfScancode = 0x0008;
    public const uint KeyeventfExtended = 0x0001;

    public const uint LlkhfInjected = 0x00000010;

    public static bool IsInjected(uint flags) => (flags & LlkhfInjected) != 0;

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    public struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    public struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    public struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    public static int Size => Marshal.SizeOf<INPUT>();

    public static INPUT Key(ushort vk, ushort scan, bool up, bool unicode = false)
    {
        uint flags = 0;
        if (up) flags |= KeyeventfKeyup;
        if (unicode) flags |= KeyeventfUnicode;
        return new INPUT
        {
            type = InputKeyboard,
            U = new InputUnion
            {
                ki = new KEYBDINPUT
                {
                    wVk = unicode ? (ushort)0 : vk,
                    wScan = scan,
                    dwFlags = flags,
                },
            },
        };
    }
}
