using System.Security.Cryptography;
using System.Text.Json;
using MimiRemote.Core;
using Xunit;

namespace MimiRemote.Core.Tests;

public sealed class WindowsReleaseTests
{
    [Theory]
    [InlineData("v1.2.3", "uploaded", false, false)]
    [InlineData("v1.2.3-beta", "uploaded", false, true)]
    [InlineData("nightly", "uploaded", false, true)]
    [InlineData("v1.2.3", "new", false, true)]
    [InlineData("v1.2.3", "uploaded", true, true)]
    public void 只接受已上传完成的正式版本(string tag, string state, bool prerelease, bool reject)
    {
        var json = Release(tag, state, prerelease);
        if (reject) { Assert.Throws<InvalidDataException>(() => WindowsRelease.Decode(json)); }
        else { Assert.Equal("1.2.3", WindowsRelease.Decode(json).Version); }
    }

    [Fact]
    public void 拒绝替换的下载域名或未签名安装包()
    {
        Assert.Throws<InvalidDataException>(() => WindowsRelease.Decode(Release("v1.2.3", "uploaded", false).Replace("github.com", "example.invalid", StringComparison.Ordinal)));
        Assert.Throws<InvalidDataException>(() => WindowsRelease.Decode(Release("v1.2.3", "uploaded", false).Replace("1.2.3.exe", "1.2.3-unsigned.exe", StringComparison.Ordinal)));
    }

    [Fact]
    public async Task 摘要匹配文件名与内容并拒绝篡改()
    {
        var path = Path.GetTempFileName();
        try
        {
            await File.WriteAllTextAsync(path, "fixture content");
            var hash = Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(path)));
            await WindowsRelease.VerifyHashAsync(path, $"{hash}  update.exe\r\n", "update.exe");
            await Assert.ThrowsAsync<InvalidDataException>(() => WindowsRelease.VerifyHashAsync(path, $"{hash}  other.exe", "update.exe"));
            await File.AppendAllTextAsync(path, "tampered");
            await Assert.ThrowsAsync<InvalidDataException>(() => WindowsRelease.VerifyHashAsync(path, $"{hash}  update.exe", "update.exe"));
        }
        finally { File.Delete(path); }
    }

    private static string Release(string tag, string state, bool prerelease)
    {
        var name = "Mimi-Remote-Setup-1.2.3.exe";
        return JsonSerializer.Serialize(new
        {
            tag_name = tag,
            draft = false,
            prerelease,
            assets = new[] { name, name + ".sha256" }.Select(file => new { name = file, state, browser_download_url = $"{WindowsRelease.Repository}/download/{tag}/{file}" }),
        });
    }
}
