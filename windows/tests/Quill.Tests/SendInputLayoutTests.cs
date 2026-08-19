using System.Runtime.InteropServices;
using Quill;
using Xunit;

namespace Quill.Tests;

public class SendInputLayoutTests
{
    [Fact]
    public void InputStructIs40BytesOn64Bit()
    {
        Assert.Equal(8, IntPtr.Size);
        Assert.Equal(SendInputLayout.X64Size, SendInputLayout.Size);
        Assert.Equal(40, Marshal.SizeOf<SendInputLayout.INPUT>());
        Assert.Equal(8, Marshal.OffsetOf<SendInputLayout.INPUT>("U").ToInt32());
        Assert.True(Marshal.SizeOf<SendInputLayout.MOUSEINPUT>() >= 24);
        Assert.True(Marshal.SizeOf<SendInputLayout.KEYBDINPUT>() >= 16);
        Assert.Equal(
            Marshal.SizeOf<SendInputLayout.MOUSEINPUT>(),
            Marshal.SizeOf<SendInputLayout.InputUnion>());
    }

    [Fact]
    public void InjectedFlag()
    {
        Assert.True(SendInputLayout.IsInjected(0x10));
        Assert.True(SendInputLayout.IsInjected(0x10 | 0x01));
        Assert.False(SendInputLayout.IsInjected(0));
        Assert.False(SendInputLayout.IsInjected(0x01));
    }
}
