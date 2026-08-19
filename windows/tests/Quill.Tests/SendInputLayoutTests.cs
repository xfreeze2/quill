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
        Assert.True(Marshal.SizeOf<SendInputLayout.MOUSEINPUT>() >= 24);
        Assert.True(Marshal.SizeOf<SendInputLayout.KEYBDINPUT>() >= 16);
        Assert.Equal(
            Marshal.SizeOf<SendInputLayout.MOUSEINPUT>(),
            Marshal.SizeOf<SendInputLayout.InputUnion>());
    }
}
