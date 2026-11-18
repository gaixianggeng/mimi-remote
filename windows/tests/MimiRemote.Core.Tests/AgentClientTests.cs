using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using MimiRemote.Core;
using Xunit;

namespace MimiRemote.Core.Tests;

public sealed class AgentClientTests
{
    [Fact]
    public async Task 含凭据链接只经标准输入且不会被错误输出堵塞()
    {
        var root = Path.Combine(Path.GetTempPath(), "mimi-cli-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var source = Path.Combine(root, "probe.go");
        var executable = Path.Combine(root, OperatingSystem.IsWindows() ? "probe.exe" : "probe");
        try
        {
            await File.WriteAllTextAsync(source, """
                package main
                import ("os"; "io"; "encoding/json"; "crypto/sha256"; "fmt"; "strings")
                func main() {
                    fmt.Fprint(os.Stderr, strings.Repeat("diagnostic ", 200000))
                    input, _ := io.ReadAll(os.Stdin)
                    json.NewEncoder(os.Stdout).Encode(map[string]any{"args": os.Args[1:], "hash": fmt.Sprintf("%x", sha256.Sum256(input))})
                }
                """);
            var start = new ProcessStartInfo("go") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true };
            foreach (var argument in new[] { "build", "-o", executable, source }) { start.ArgumentList.Add(argument); }
            using var build = Process.Start(start)!;
            var errors = build.StandardError.ReadToEndAsync();
            await build.WaitForExitAsync();
            Assert.True(build.ExitCode == 0, await errors);
            const string input = "https://harness.example.invalid/#token=test-only-凭据";
            var result = await new AgentClient(executable).RunWithInputAsync(["runtime", "--deepseek-url-stdin"], input);
            using var document = JsonDocument.Parse(result);
            Assert.Equal(["runtime", "--deepseek-url-stdin"], document.RootElement.GetProperty("args").Deserialize<string[]>()!);
            Assert.Equal(Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(input))), document.RootElement.GetProperty("hash").GetString());
            Assert.DoesNotContain("test-only", result);
        }
        finally
        {
            if (File.Exists(source)) { File.Delete(source); }
            if (File.Exists(executable)) { File.Delete(executable); }
            Directory.Delete(root);
        }
    }
}
