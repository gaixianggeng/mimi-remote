using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace MimiRemote.Core;

public sealed record WindowsRelease(string Version, Uri DownloadUrl, Uri ChecksumUrl, Uri ReleaseUrl)
{
    public const string Repository = "https://github.com/gaixianggeng/mimi-remote/releases";
    public static Uri LatestApi { get; } = new("https://api.github.com/repos/gaixianggeng/mimi-remote/releases/latest");

    public static WindowsRelease Decode(string json)
    {
        using var document = JsonDocument.Parse(json);
        var release = document.RootElement;
        var tag = release.GetProperty("tag_name").GetString() ?? "";
        if (release.GetProperty("draft").GetBoolean() || release.GetProperty("prerelease").GetBoolean() ||
            !Regex.IsMatch(tag, @"\Av[0-9]+\.[0-9]+\.[0-9]+\z", RegexOptions.CultureInvariant) || !System.Version.TryParse(tag[1..], out _))
        {
            throw new InvalidDataException("尚无可用的 Windows 正式版本。");
        }
        var name = $"Mimi-Remote-Setup-{tag[1..]}.exe";
        Uri Asset(string filename)
        {
            var expected = $"{Repository}/download/{tag}/{filename}";
            if (!release.GetProperty("assets").EnumerateArray().Any(asset =>
                asset.GetProperty("name").GetString() == filename && asset.GetProperty("state").GetString() == "uploaded" &&
                asset.GetProperty("browser_download_url").GetString() == expected))
            {
                throw new InvalidDataException("此版本的已签名安装包或校验文件尚未上传完成。");
            }
            return new Uri(expected);
        }
        return new WindowsRelease(tag[1..], Asset(name), Asset(name + ".sha256"), new Uri($"{Repository}/tag/{tag}"));
    }

    public static async Task VerifyHashAsync(string path, string checksum, string expectedName, CancellationToken token = default)
    {
        var lines = checksum.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (lines.Length != 1 || !Regex.IsMatch(lines[0], @"^[a-fA-F0-9]{64} [ *]" + Regex.Escape(expectedName) + "$", RegexOptions.CultureInvariant))
        {
            throw new InvalidDataException("更新校验文件格式不正确。");
        }
        await using var stream = File.OpenRead(path);
        var actual = await SHA256.HashDataAsync(stream, token).ConfigureAwait(false);
        if (!CryptographicOperations.FixedTimeEquals(actual, Convert.FromHexString(lines[0][..64])))
        {
            throw new InvalidDataException("安装包 SHA-256 校验失败，未运行更新。");
        }
    }
}
