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
                        if os.Getenv("MIMI_TEST_BAD_PROGRESS") != "" {
                            fmt.Fprintln(os.Stderr, `{"id":"assistant_claude","group":"assistant","state":"action_needed","title":"Claude","detail":"请登录","blocking":false,"enabled":true,"available":false,"candidates":[{"path":"/fixture/bin/claude","outcome":"selected"}],"code":"claude_signed_out","fix":{"kind":"open_url","url":"https://learn.chatgpt.com/docs/codex/cli"}}`)
                            fmt.Fprintln(os.Stderr, `{"id":"service_daemon","group":"service","state":"action_needed","title":"后台服务","detail":"未运行","blocking":true,"code":"service_not_running","fix":{"kind":"run_fix","action":"restart_service"}}`)
                        }
                        ndjson, _ := os.ReadFile(os.Getenv("MIMI_TEST_NDJSON"))
                        report, _ := os.ReadFile(os.Getenv("MIMI_TEST_REPORT"))
                        lines := strings.Split(strings.TrimSpace(string(ndjson)), "\n")
                        fmt.Fprintln(os.Stderr, strings.Repeat("noise", 250000))
                        for i := 0; i < 26 && i < len(lines); i++ {
                            fmt.Fprintln(os.Stderr, lines[i])
                        }
                        time.Sleep(200 * time.Millisecond)
                        for i := 26; i < len(lines); i++ {
                            fmt.Fprintln(os.Stderr, lines[i])
                        }
                        os.Stdout.Write(report)
                    case "doctor":
                        fmt.Fprintln(os.Stderr, "Authorization: Bearer samplepassword")
                        os.Exit(1)
                    case "setup":
                        if os.Getenv("MIMI_TEST_BAD_RECEIPT") != "" {
                            fmt.Fprintln(os.Stdout, `{"network":"mimiremote://pair?pair_sig=private"}`)
                            return
                        }
                        if os.Getenv("MIMI_TEST_RAW_STDERR") != "" {
                            fmt.Fprintln(os.Stderr, os.Getenv("MIMI_TEST_RAW_STDERR"))
                            os.Exit(2)
                        }
                        if os.Getenv("MIMI_TEST_RESTART_ERR") != "" {
                            fmt.Fprintln(os.Stdout, `{"ok":false,"error":{"code":"service_not_running","step":"service_daemon","message":"未运行","fix":{"kind":"run_fix","action":"restart_service"}}}`)
                            os.Exit(1)
                        }
                        if os.Getenv("MIMI_TEST_ERR") != "" {
                            data, _ := os.ReadFile(os.Getenv("MIMI_TEST_ERR"))
                            os.Stdout.Write(data)
                            fmt.Fprintln(os.Stderr, "raw stderr")
                            os.Exit(1)
                        }
                        data, _ := os.ReadFile(os.Getenv("MIMI_TEST_SETUP"))
                        os.Stdout.Write(data)
                        if os.Getenv("MIMI_TEST_LONG_STDOUT") != "" {
                            fmt.Fprint(os.Stdout, strings.Repeat(" ", 1<<20), "invalid trailing data")
                        }
                    }
                }
                """);
            await BuildGoProbeAsync(source, executable);

            var ndjsonPath = Path.Combine(AppContext.BaseDirectory, "fixtures", "preflight-progress-slow-assistant.ndjson");
            var reportPath = Path.Combine(AppContext.BaseDirectory, "fixtures", "preflight-codex-chatgpt-app.json");
            var setupReportPath = Path.Combine(AppContext.BaseDirectory, "fixtures", "preflight-claude-only-no-network.json");
            var setupPath = Path.Combine(AppContext.BaseDirectory, "fixtures", "setup-ok-pairing-deferred.json");
            var errPath = Path.Combine(AppContext.BaseDirectory, "fixtures", "setup-error-config-invalid.json");

            Environment.SetEnvironmentVariable("MIMI_TEST_NDJSON", ndjsonPath);
            Environment.SetEnvironmentVariable("MIMI_TEST_REPORT", reportPath);
            Environment.SetEnvironmentVariable("MIMI_TEST_SETUP", setupPath);
            Environment.SetEnvironmentVariable("MIMI_TEST_BAD_RECEIPT", null);
            Environment.SetEnvironmentVariable("MIMI_TEST_LONG_STDOUT", null);
            Environment.SetEnvironmentVariable("MIMI_TEST_ERR", null);
            Environment.SetEnvironmentVariable("MIMI_TEST_BAD_PROGRESS", "1");
            Environment.SetEnvironmentVariable("MIMI_TEST_RAW_STDERR", null);
            Environment.SetEnvironmentVariable("MIMI_TEST_RESTART_ERR", null);

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
            // The 2 invalid progress rows MUST be dropped before reaching onProgress; only the 36 valid rows are delivered.
            Assert.Equal(36, progress.Count);
            var codexOkIdx = progress.FindIndex(c => c.Id == "assistant_codex" && c.State == "ok");
            var claudeFinalIdx = progress.FindIndex(c => c.Id == "assistant_claude" && c.State == "action_needed");
            Assert.True(codexOkIdx >= 0 && codexOkIdx < claudeFinalIdx);

            using var cancellation = new CancellationTokenSource();
            var callbacks = 0;
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => client.PreflightAsync(
                new OnboardingPreflightOptions { Stage = "pair", ProgressJson = true },
                _ =>
                {
                    callbacks++;
                    cancellation.Cancel();
                },
                platform: "macos",
                cancellationToken: cancellation.Token));
            Assert.Equal(1, callbacks);

            // P1-3: A valid ok:true setup report MUST NOT satisfy a pair preflight request
            Environment.SetEnvironmentVariable("MIMI_TEST_REPORT", setupReportPath);
            await Assert.ThrowsAsync<InvalidDataException>(() => client.PreflightAsync(
                new OnboardingPreflightOptions { Stage = "pair", ProgressJson = false },
                platform: "linux"));
            Environment.SetEnvironmentVariable("MIMI_TEST_REPORT", reportPath);

            var receipt = await client.SetupAsync("/fixture/workspace");
            Assert.True(receipt.Ok);
            Assert.True(receipt.PairingDeferred);
            Assert.False(receipt.HasTicket);

            // A complete receipt in the retained prefix is insufficient if stdout was truncated.
            Environment.SetEnvironmentVariable("MIMI_TEST_LONG_STDOUT", "1");
            await Assert.ThrowsAsync<InvalidDataException>(() => client.SetupAsync("/fixture/workspace"));
            Environment.SetEnvironmentVariable("MIMI_TEST_LONG_STDOUT", null);

            Environment.SetEnvironmentVariable("MIMI_TEST_ERR", errPath);
            var error = await Assert.ThrowsAsync<OnboardingCliException>(() => client.SetupAsync("/fixture/workspace"));
            Assert.NotNull(error.Diagnostic);
            Assert.True(error.Diagnostic!.Trusted);
            Assert.Equal("config_invalid", error.Diagnostic.Code);
            Assert.Equal("host_recovery", error.Diagnostic.AllowedFix?.Target);

            // P1-2: Fresh setup error MUST NOT authorize restart_service
            Environment.SetEnvironmentVariable("MIMI_TEST_ERR", null);
            Environment.SetEnvironmentVariable("MIMI_TEST_RESTART_ERR", "1");
            var restartErr = await Assert.ThrowsAsync<OnboardingCliException>(() => client.SetupAsync("/fixture/workspace"));
            Assert.NotNull(restartErr.Diagnostic);
            Assert.False(restartErr.Diagnostic!.Trusted);
            Assert.Null(restartErr.Diagnostic.AllowedFix);

            // P1-1: Unrecognized stderr MUST NOT leak secrets/paths into user-facing error message
            Environment.SetEnvironmentVariable("MIMI_TEST_RESTART_ERR", null);
            Environment.SetEnvironmentVariable(
                "MIMI_TEST_RAW_STDERR",
                @"fatal: Bearer topSecret123 mimiremote://pair?pair_sig=abc C:\Users\alice\config.json UnmarkedCred9876543210ABCDEF");
            var rawErr = await Assert.ThrowsAsync<OnboardingCliException>(() => client.SetupAsync("/fixture/workspace"));
            Assert.Contains("退出码 2", rawErr.Message, StringComparison.Ordinal);
            Assert.DoesNotContain("topSecret123", rawErr.Message, StringComparison.Ordinal);
            Assert.DoesNotContain("mimiremote://", rawErr.Message, StringComparison.Ordinal);
            Assert.DoesNotContain(@"C:\Users\alice", rawErr.Message, StringComparison.Ordinal);
            Assert.DoesNotContain("UnmarkedCred9876543210ABCDEF", rawErr.Message, StringComparison.Ordinal);
            Assert.NotNull(rawErr.Diagnostic?.SanitizedDiagnostic);
            Assert.DoesNotContain("topSecret123", rawErr.Diagnostic!.SanitizedDiagnostic!, StringComparison.Ordinal);
            Assert.DoesNotContain("mimiremote://", rawErr.Diagnostic.SanitizedDiagnostic!, StringComparison.Ordinal);
            Assert.DoesNotContain(@"C:\Users\alice", rawErr.Diagnostic.SanitizedDiagnostic!, StringComparison.Ordinal);
            Assert.DoesNotContain("UnmarkedCred9876543210ABCDEF", rawErr.Diagnostic.SanitizedDiagnostic!, StringComparison.Ordinal);

            // The diagnostics page runs doctor with allowFailure and displays the returned string.
            var doctor = await client.RunAsync(["doctor"], allowFailure: true);
            Assert.Contains("退出码 1", doctor, StringComparison.Ordinal);
            Assert.DoesNotContain("samplepassword", doctor, StringComparison.Ordinal);

            Environment.SetEnvironmentVariable("MIMI_TEST_BAD_RECEIPT", "1");
            var invalid = await Assert.ThrowsAsync<InvalidDataException>(() => client.SetupAsync("/fixture/workspace"));
            Assert.DoesNotContain("mimiremote://", invalid.Message, StringComparison.Ordinal);
        }
        finally
        {
            Environment.SetEnvironmentVariable("MIMI_TEST_NDJSON", null);
            Environment.SetEnvironmentVariable("MIMI_TEST_REPORT", null);
            Environment.SetEnvironmentVariable("MIMI_TEST_SETUP", null);
            Environment.SetEnvironmentVariable("MIMI_TEST_ERR", null);
            Environment.SetEnvironmentVariable("MIMI_TEST_BAD_PROGRESS", null);
            Environment.SetEnvironmentVariable("MIMI_TEST_RAW_STDERR", null);
            Environment.SetEnvironmentVariable("MIMI_TEST_RESTART_ERR", null);
            Environment.SetEnvironmentVariable("MIMI_TEST_BAD_RECEIPT", null);
            Environment.SetEnvironmentVariable("MIMI_TEST_LONG_STDOUT", null);
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
