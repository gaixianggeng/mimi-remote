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
            await BuildGoProbeAsync(source, executable);
            const string input = "https://harness.example.invalid/#token=test-only-凭据";
            var result = await new AgentClient(executable).RunWithInputAsync(["runtime", "--deepseek-url-stdin"], input);
            using var document = JsonDocument.Parse(result);
            Assert.Equal(["runtime", "--deepseek-url-stdin"], document.RootElement.GetProperty("args").Deserialize<string[]>()!);
            Assert.Equal(Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(input))), document.RootElement.GetProperty("hash").GetString());
            Assert.DoesNotContain("test-only", result);
        }
        finally
        {
            CleanupDirectory(root, source, executable);
        }
    }

    [Fact]
    public async Task 命令客户端支持流式预检和无票设置与标准输出错误信封()
    {
        var root = Path.Combine(Path.GetTempPath(), "mimi-cli-ui1-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var source = Path.Combine(root, "stub.go");
        var executable = Path.Combine(root, OperatingSystem.IsWindows() ? "stub.exe" : "stub");
        try
        {
            await File.WriteAllTextAsync(source, """
                package main
                import ("fmt"; "os"; "strings"; "time")
                func main() {
                    mode := os.Args[1]
                    switch mode {
                    case "preflight":
                        ndjson, _ := os.ReadFile(os.Getenv("MIMI_TEST_NDJSON"))
                        report, _ := os.ReadFile(os.Getenv("MIMI_TEST_REPORT"))
                        lines := strings.Split(strings.TrimSpace(string(ndjson)), "\n")
                        fmt.Fprintln(os.Stderr, "malformed noise line")
                        for i := 0; i < 26 && i < len(lines); i++ {
                            fmt.Fprintln(os.Stderr, lines[i])
                        }
                        time.Sleep(200 * time.Millisecond)
                        for i := 26; i < len(lines); i++ {
                            fmt.Fprintln(os.Stderr, lines[i])
                        }
                        os.Stdout.Write(report)
                    case "setup":
                        if os.Getenv("MIMI_TEST_ERR") != "" {
                            data, _ := os.ReadFile(os.Getenv("MIMI_TEST_ERR"))
                            os.Stdout.Write(data)
                            fmt.Fprintln(os.Stderr, "raw stderr")
                            os.Exit(1)
                        }
                        data, _ := os.ReadFile(os.Getenv("MIMI_TEST_SETUP"))
                        os.Stdout.Write(data)
                    }
                }
                """);
            await BuildGoProbeAsync(source, executable);

            var ndjsonPath = Path.Combine(AppContext.BaseDirectory, "fixtures", "preflight-progress-slow-assistant.ndjson");
            var reportPath = Path.Combine(AppContext.BaseDirectory, "fixtures", "preflight-codex-chatgpt-app.json");
            var setupPath = Path.Combine(AppContext.BaseDirectory, "fixtures", "setup-ok-pairing-deferred.json");
            var errPath = Path.Combine(AppContext.BaseDirectory, "fixtures", "setup-error-config-invalid.json");

            Environment.SetEnvironmentVariable("MIMI_TEST_NDJSON", ndjsonPath);
            Environment.SetEnvironmentVariable("MIMI_TEST_REPORT", reportPath);
            Environment.SetEnvironmentVariable("MIMI_TEST_SETUP", setupPath);
            Environment.SetEnvironmentVariable("MIMI_TEST_ERR", null);

            var client = new AgentClient(executable);
            var progress = new List<OnboardingCheck>();
            var report = await client.PreflightAsync(
                new OnboardingPreflightOptions { Stage = "pair", ProgressJson = true },
                check =>
                {
                    lock (progress)
                    {
                        progress.Add(check);
                    }
                },
                platform: "macos");
            Assert.True(report.Ok);
            Assert.Equal(36, progress.Count);
            var codexOkIdx = progress.FindIndex(c => c.Id == "assistant_codex" && c.State == "ok");
            var claudeFinalIdx = progress.FindIndex(c => c.Id == "assistant_claude" && c.State == "action_needed");
            Assert.True(codexOkIdx >= 0 && codexOkIdx < claudeFinalIdx);

            var receipt = await client.SetupAsync("/fixture/workspace");
            Assert.True(receipt.Ok);
            Assert.Equal(true, receipt.PairingDeferred);
            Assert.False(receipt.HasTicket);

            Environment.SetEnvironmentVariable("MIMI_TEST_ERR", errPath);
            var error = await Assert.ThrowsAsync<OnboardingCliException>(() => client.SetupAsync("/fixture/workspace"));
            Assert.NotNull(error.Diagnostic);
            Assert.True(error.Diagnostic!.Trusted);
            Assert.Equal("config_invalid", error.Diagnostic.Code);
            Assert.Equal("host_recovery", error.Diagnostic.AllowedFix?.Target);
        }
        finally
        {
            Environment.SetEnvironmentVariable("MIMI_TEST_NDJSON", null);
            Environment.SetEnvironmentVariable("MIMI_TEST_REPORT", null);
            Environment.SetEnvironmentVariable("MIMI_TEST_SETUP", null);
            Environment.SetEnvironmentVariable("MIMI_TEST_ERR", null);
            CleanupDirectory(root, source, executable);
        }
    }

    private static async Task BuildGoProbeAsync(string source, string executable)
    {
        var start = new ProcessStartInfo("go") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true };
        foreach (var argument in new[] { "build", "-o", executable, source })
        {
            start.ArgumentList.Add(argument);
        }
        using var build = Process.Start(start)!;
        var errors = build.StandardError.ReadToEndAsync();
        await build.WaitForExitAsync();
        Assert.True(build.ExitCode == 0, await errors);
    }

    private static void CleanupDirectory(string root, string source, string executable)
    {
        if (File.Exists(source))
        {
            File.Delete(source);
        }
        if (File.Exists(executable))
        {
            File.Delete(executable);
        }
        if (Directory.Exists(root))
        {
            Directory.Delete(root);
        }
    }
}
