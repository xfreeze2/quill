using System.Runtime.InteropServices;
using System.Text;
using Quill;

namespace Quill.Win.Native;

sealed class CredentialStore : IApiKeyStore
{
    const string Target = "com.freeze.quill:xai-api-key";

    public bool HasKey => Load() is not null;
    public string? Redacted => Auth.Redact(Load());

    public string? Load()
    {
        if (!Win32.CredRead(Target, Win32.CRED_TYPE_GENERIC, 0, out var ptr) || ptr == IntPtr.Zero)
            return null;
        try
        {
            var cred = Marshal.PtrToStructure<Win32.CREDENTIAL>(ptr);
            if (cred.CredentialBlob == IntPtr.Zero || cred.CredentialBlobSize == 0) return null;
            var bytes = new byte[cred.CredentialBlobSize];
            Marshal.Copy(cred.CredentialBlob, bytes, 0, bytes.Length);
            var key = Encoding.Unicode.GetString(bytes).TrimEnd('\0').Trim();
            return string.IsNullOrEmpty(key) ? null : key;
        }
        finally
        {
            Win32.CredFree(ptr);
        }
    }

    public bool Save(string key)
    {
        var trimmed = key.Trim();
        if (string.IsNullOrEmpty(trimmed)) return false;
        Remove();
        var bytes = Encoding.Unicode.GetBytes(trimmed);
        var blob = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var cred = new Win32.CREDENTIAL
            {
                Type = Win32.CRED_TYPE_GENERIC,
                TargetName = Target,
                CredentialBlobSize = (uint)bytes.Length,
                CredentialBlob = blob,
                Persist = Win32.CRED_PERSIST_LOCAL_MACHINE,
                UserName = "xai-api-key",
                Comment = "Quill — xAI API key",
            };
            return Win32.CredWrite(ref cred, 0);
        }
        finally
        {
            Marshal.FreeHGlobal(blob);
        }
    }

    public bool Remove() => Win32.CredDelete(Target, Win32.CRED_TYPE_GENERIC, 0);
}
