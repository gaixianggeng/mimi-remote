using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace MimiRemote.Core;

/// <summary>
/// Native Windows CryptoAPI CMS SignedData verifier for the maintenance
/// identity receipt (mimi.windows.maintenance/v1).
/// </summary>
[SupportedOSPlatform("windows")]
public static class WindowsMaintenanceCmsVerifier
{
    private const uint X509AsnEncoding = 0x00000001;
    private const uint Pkcs7AsnEncoding = 0x00010000;
    private const uint CertMsgEncoding = X509AsnEncoding | Pkcs7AsnEncoding;
    private const uint CmsgSigned = 2;
    private const uint CmsgTypeParam = 1;
    private const uint CmsgContentParam = 2;
    private const uint CmsgSignerCountParam = 5;
    private const uint CmsgSignerCertInfoParam = 7;
    private const uint CmsgCtrlVerifySignature = 1;
    private const int CertStoreProvMsg = 1;
    private const string CodeSigningOid = "1.3.6.1.5.5.7.3.3";

    public static byte[] VerifyCmsReceipt(byte[] rawReceipt, ReadOnlySpan<byte> expectedPublisher)
    {
        ArgumentNullException.ThrowIfNull(rawReceipt);
        return VerifyCmsReceiptCore(rawReceipt, expectedPublisher, customTrustRoots: null);
    }

    internal static byte[] VerifyCmsReceiptForTesting(
        byte[] rawReceipt,
        ReadOnlySpan<byte> expectedPublisher,
        X509Certificate2Collection customTrustRoots)
    {
        ArgumentNullException.ThrowIfNull(rawReceipt);
        ArgumentNullException.ThrowIfNull(customTrustRoots);
        return VerifyCmsReceiptCore(rawReceipt, expectedPublisher, customTrustRoots);
    }

    private static byte[] VerifyCmsReceiptCore(
        byte[] rawReceipt,
        ReadOnlySpan<byte> expectedPublisher,
        X509Certificate2Collection? customTrustRoots)
    {
        if (rawReceipt.Length == 0
            || rawReceipt.Length > WindowsMaintenanceClient.ReceiptMaxBytes
            || expectedPublisher.Length != SHA256.HashSizeInBytes)
        {
            throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
        }
        var hMsg = CryptMsgOpenToDecode(CertMsgEncoding, 0, 0, 0, 0, 0);
        if (hMsg == 0)
        {
            throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
        }
        var hStore = (nint)0;
        var signerCertPtr = (nint)0;
        var signerInfoPtr = (nint)0;
        try
        {
            if (!CryptMsgUpdate(hMsg, rawReceipt, (uint)rawReceipt.Length, true))
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
            }

            uint msgType = 0;
            uint msgTypeSize = sizeof(uint);
            if (!CryptMsgGetParamUInt(hMsg, CmsgTypeParam, 0, ref msgType, ref msgTypeSize) || msgType != CmsgSigned)
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
            }

            uint signerCount = 0;
            uint signerCountSize = sizeof(uint);
            if (!CryptMsgGetParamUInt(hMsg, CmsgSignerCountParam, 0, ref signerCount, ref signerCountSize) || signerCount != 1)
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
            }

            var content = GetCmsBytesParam(hMsg, CmsgContentParam, 0, WindowsMaintenanceClient.ReceiptMaxBytes);
            if (content.Length == 0)
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
            }

            // CMSG_SIGNER_CERT_INFO_PARAM populates a CERT_INFO containing internal
            // pointers into the same buffer; allocate fixed unmanaged memory from the
            // native write through certificate lookup so GC can never relocate it.
            uint signerInfoSize = 0;
            if (!CryptMsgGetParamPtr(hMsg, CmsgSignerCertInfoParam, 0, 0, ref signerInfoSize)
                || signerInfoSize == 0
                || signerInfoSize > 65_536)
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
            }
            signerInfoPtr = Marshal.AllocHGlobal((int)signerInfoSize);
            if (!CryptMsgGetParamPtr(hMsg, CmsgSignerCertInfoParam, 0, signerInfoPtr, ref signerInfoSize)
                || signerInfoSize == 0)
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
            }

            hStore = CertOpenStore(CertStoreProvMsg, CertMsgEncoding, 0, 0, hMsg);
            if (hStore == 0)
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
            }

            signerCertPtr = CertGetSubjectCertificateFromStore(hStore, CertMsgEncoding, signerInfoPtr);
            if (signerCertPtr == 0)
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
            }
            var signerContext = Marshal.PtrToStructure<CertContextNative>(signerCertPtr);
            if (signerContext.CertInfo == 0
                || signerContext.EncodedCert == 0
                || signerContext.EncodedLength == 0
                || signerContext.EncodedLength > 1_048_576)
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
            }

            if (!CryptMsgControl(hMsg, 0, CmsgCtrlVerifySignature, signerContext.CertInfo))
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
            }

            var signerDer = new byte[signerContext.EncodedLength];
            Marshal.Copy(signerContext.EncodedCert, signerDer, 0, signerDer.Length);
            var signerHash = SHA256.HashData(signerDer);
            if (!CryptographicOperations.FixedTimeEquals(signerHash, expectedPublisher))
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
            }

            VerifyCodeSigningChain(signerDer, hStore, customTrustRoots);
            return content;
        }
        finally
        {
            if (signerCertPtr != 0)
            {
                _ = CertFreeCertificateContext(signerCertPtr);
            }
            if (signerInfoPtr != 0)
            {
                Marshal.FreeHGlobal(signerInfoPtr);
            }
            if (hStore != 0)
            {
                _ = CertCloseStore(hStore, 0);
            }
            _ = CryptMsgClose(hMsg);
        }
    }

    private static void VerifyCodeSigningChain(byte[] signerDer, nint hStore, X509Certificate2Collection? customTrustRoots)
    {
        using var signerCert = X509CertificateLoader.LoadCertificate(signerDer);
        var extraCerts = new List<X509Certificate2>();
        var prev = (nint)0;
        try
        {
            while ((prev = CertEnumCertificatesInStore(hStore, prev)) != 0)
            {
                var ctx = Marshal.PtrToStructure<CertContextNative>(prev);
                if (ctx.EncodedCert != 0 && ctx.EncodedLength > 0 && ctx.EncodedLength <= 1_048_576)
                {
                    var der = new byte[ctx.EncodedLength];
                    Marshal.Copy(ctx.EncodedCert, der, 0, der.Length);
                    extraCerts.Add(X509CertificateLoader.LoadCertificate(der));
                }
            }
            using var chain = new X509Chain();
            chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
            chain.ChainPolicy.DisableCertificateDownloads = true;
            chain.ChainPolicy.VerificationFlags = X509VerificationFlags.NoFlag;
            chain.ChainPolicy.ApplicationPolicy.Add(new Oid(CodeSigningOid));
            if (customTrustRoots is not null)
            {
                chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
                chain.ChainPolicy.CustomTrustStore.AddRange(customTrustRoots);
            }
            foreach (var extra in extraCerts)
            {
                chain.ChainPolicy.ExtraStore.Add(extra);
            }
            if (!chain.Build(signerCert))
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
            }
        }
        finally
        {
            if (prev != 0)
            {
                _ = CertFreeCertificateContext(prev);
            }
            foreach (var cert in extraCerts)
            {
                cert.Dispose();
            }
        }
    }

    private static byte[] GetCmsBytesParam(nint hMsg, uint paramType, uint index, int maxBytes)
    {
        uint size = 0;
        if (!CryptMsgGetParamBytes(hMsg, paramType, index, null, ref size) || size == 0 || size > maxBytes)
        {
            throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
        }
        var buffer = new byte[size];
        if (!CryptMsgGetParamBytes(hMsg, paramType, index, buffer, ref size))
        {
            throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
        }
        return size == buffer.Length ? buffer : buffer[..(int)size];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CertContextNative
    {
        public uint EncodingType;
        public nint EncodedCert;
        public uint EncodedLength;
        public nint CertInfo;
        public nint CertStore;
    }

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern nint CryptMsgOpenToDecode(uint msgEncodingType, uint flags, uint msgType, nint cryptProv, nint recipientInfo, nint streamInfo);

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptMsgUpdate(nint cryptMsg, byte[] data, uint dataLength, [MarshalAs(UnmanagedType.Bool)] bool final);

    [DllImport("crypt32.dll", EntryPoint = "CryptMsgGetParam", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptMsgGetParamUInt(nint cryptMsg, uint paramType, uint index, ref uint data, ref uint dataLength);

    [DllImport("crypt32.dll", EntryPoint = "CryptMsgGetParam", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptMsgGetParamBytes(nint cryptMsg, uint paramType, uint index, [Out] byte[]? data, ref uint dataLength);

    [DllImport("crypt32.dll", EntryPoint = "CryptMsgGetParam", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptMsgGetParamPtr(nint cryptMsg, uint paramType, uint index, nint data, ref uint dataLength);

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptMsgControl(nint cryptMsg, uint flags, uint ctrlType, nint ctrlPara);

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptMsgClose(nint cryptMsg);

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern nint CertOpenStore(nint storeProvider, uint encodingType, nint cryptProv, uint flags, nint para);

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern nint CertGetSubjectCertificateFromStore(nint certStore, uint certEncodingType, nint certId);

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern nint CertEnumCertificatesInStore(nint certStore, nint prevCertContext);

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CertFreeCertificateContext(nint certContext);

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CertCloseStore(nint certStore, uint flags);
}
