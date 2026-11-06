using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace MimiRemote.App;

internal static class InstallerTrust
{
    // Both files must have trusted Authenticode signatures by the same certificate.
    // Unsigned previews fail closed. Certificate rotation requires a manual verified install.
    internal static void Verify(string installer, string currentExecutable)
    {
        VerifyFile(currentExecutable);
        VerifyFile(installer);
#pragma warning disable SYSLIB0057 // Authenticode PKCS#7 certificate extraction, not a PFX import.
        using var current = new X509Certificate2(X509Certificate.CreateFromSignedFile(currentExecutable));
        using var candidate = new X509Certificate2(X509Certificate.CreateFromSignedFile(installer));
#pragma warning restore SYSLIB0057
        if (!CryptographicOperations.FixedTimeEquals(SHA256.HashData(current.RawData), SHA256.HashData(candidate.RawData)))
        {
            throw new InvalidDataException("更新发布者证书与当前客户端不一致，未运行更新。请从正式发布页面手动核实。");
        }
    }

    private static void VerifyFile(string path)
    {
        var file = new TrustFile { Size = (uint)Marshal.SizeOf<TrustFile>(), Path = path };
        var pointer = Marshal.AllocHGlobal(Marshal.SizeOf<TrustFile>());
        Marshal.StructureToPtr(file, pointer, false);
        var data = new TrustData
        {
            Size = (uint)Marshal.SizeOf<TrustData>(),
            UiChoice = 2,
            RevocationChecks = 1,
            UnionChoice = 1,
            File = pointer,
            StateAction = 1,
            ProviderFlags = 0x80,
        };
        var action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");
        try
        {
            var result = WinVerifyTrust(new nint(-1), ref action, ref data);
            if (result != 0) { throw new InvalidDataException("签名验证未通过。未签名预览版不能自动更新；请使用正式签名版本。"); }
        }
        finally
        {
            data.StateAction = 2;
            var cleanupResult = WinVerifyTrust(new nint(-1), ref action, ref data);
            if (cleanupResult != 0) { System.Diagnostics.Debug.WriteLine("WinVerifyTrust state cleanup failed."); }
            Marshal.DestroyStructure<TrustFile>(pointer);
            Marshal.FreeHGlobal(pointer);
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct TrustFile
    {
        public uint Size;
        [MarshalAs(UnmanagedType.LPWStr)] public string Path;
        public nint Handle, KnownSubject;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TrustData
    {
        public uint Size;
        public nint PolicyCallback, SipClient;
        public uint UiChoice, RevocationChecks, UnionChoice;
        public nint File;
        public uint StateAction;
        public nint StateData, UrlReference;
        public uint ProviderFlags, UiContext;
        public nint SignatureSettings;
    }

    [DllImport("wintrust.dll", ExactSpelling = true, PreserveSig = true)]
    private static extern int WinVerifyTrust(nint window, ref Guid action, ref TrustData data);
}
