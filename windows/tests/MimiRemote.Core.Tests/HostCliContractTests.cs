using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using MimiRemote.App;
using MimiRemote.App.ViewModels;
using MimiRemote.Core;
using Xunit;

namespace MimiRemote.Core.Tests;

public sealed class HostCliContractTests
{
    [Fact]
    public void 中转选择遵循共享确认与校验契约()
    {
        using var document = JsonDocument.Parse(ReadFixture("relay-cases.json"));
        foreach (var test in document.RootElement.EnumerateArray())
        {
            var choice = test.GetProperty("choice").GetString()!;
            var url = test.GetProperty("url").GetString()!;
            var current = test.GetProperty("current").Deserialize<TailcatStatus>(AgentClient.JsonOptions)!;
            Assert.Equal(test.GetProperty("needs_confirmation").GetBoolean(), RelayPolicy.NeedsConfirmation(choice, url, current));
            if (test.GetProperty("valid").GetBoolean())
            {
                Assert.Equal(["tailcat", "relay", "set", "--choice", choice, "--derp-map-url", url, "--json"], RelayPolicy.Arguments(choice, url));
            }
            else
            {
                Assert.Throws<ArgumentException>(() => RelayPolicy.Arguments(choice, url));
            }
        }
    }

    [Fact]
    public void 状态保留服务端版本并容忍未来字段()
    {
        var status = JsonSerializer.Deserialize<HostStatus>(ReadFixture("status-ready.json"), AgentClient.JsonOptions)!;
        Assert.True(status.ServiceOk);
        Assert.Equal("fixture-server", status.ServerVersion);
        Assert.Equal(3, status.Projects);
        Assert.Equal("codex", Assert.Single(status.RuntimeStatus!.Runtimes).Id);
    }

    [Fact]
    public void 引导文案目录与共享注册表集合完全一致()
    {
        using var manifest = JsonDocument.Parse(ReadFixture("onboarding-codes-v1.json"));
        var root = manifest.RootElement;
        Assert.Equal(OnboardingSchema.CodesV1, root.GetProperty("schema").GetString());

        var checks = root.GetProperty("checks").EnumerateArray().ToArray();
        Assert.NotEmpty(checks);
        Assert.Equal(checks.Length, OnboardingCopyCatalog.Checks.Count);
        for (var i = 0; i < checks.Length; i++)
        {
            var want = checks[i];
            var got = OnboardingCopyCatalog.Checks[i];
            Assert.Equal(want.GetProperty("id").GetString(), got.Id);
            Assert.Equal(want.GetProperty("group").GetString(), got.Group);
            var wantPlatforms = want.GetProperty("platforms").EnumerateArray().Select(p => p.GetString()!).ToArray();
            Assert.Equal(wantPlatforms, got.Platforms);
        }

        var wantWire = root.GetProperty("wire_codes").EnumerateArray().Select(c => c.GetProperty("code").GetString()!).ToHashSet(StringComparer.Ordinal);
        var wantLocal = root.GetProperty("ui_local_codes").EnumerateArray().Select(c => c.GetProperty("code").GetString()!).ToHashSet(StringComparer.Ordinal);
        Assert.NotEmpty(wantWire);
        Assert.NotEmpty(wantLocal);
        Assert.True(OnboardingCopyCatalog.WireCodes.SetEquals(wantWire));
        Assert.True(OnboardingCopyCatalog.UiLocalCodes.SetEquals(wantLocal));
        foreach (var entry in OnboardingCopyCatalog.Entries)
        {
            Assert.Contains(entry.MessageZh, ch => ch >= '\u4E00' && ch <= '\u9FFF');
        }

        var urls = root.GetProperty("urls").EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetString()!, StringComparer.Ordinal);
        Assert.Equal(urls.Count, OnboardingCopyCatalog.AllowedUrls.Count);
        foreach (var (key, value) in urls)
        {
            Assert.Equal(value, OnboardingCopyCatalog.AllowedUrls[key]);
        }

        var settingsTargets = root.GetProperty("settings_targets").EnumerateArray().Select(x => x.GetString()!).ToArray();
        Assert.Equal(settingsTargets, OnboardingCopyCatalog.SettingsTargets);

        var pathTargets = root.GetProperty("path_targets").EnumerateArray().Select(x => x.GetString()!).ToArray();
        Assert.Equal(pathTargets, OnboardingCopyCatalog.PathTargets);

        var runFix = root.GetProperty("run_fix").EnumerateObject().ToDictionary(p => p.Name, p => p.Value, StringComparer.Ordinal);
        Assert.Equal(runFix.Count, OnboardingCopyCatalog.RunFixSpecs.Count);
        foreach (var (action, specElement) in runFix)
        {
            var got = OnboardingCopyCatalog.RunFixSpecs[action];
            Assert.Equal(specElement.GetProperty("requires_config").GetBoolean(), got.RequiresConfig);
            var wantCap = specElement.TryGetProperty("requires_capability", out var capProp) ? capProp.GetString() : null;
            Assert.Equal(wantCap, got.RequiresCapability);
        }

        foreach (var entry in root.GetProperty("timeouts_seconds").EnumerateArray())
        {
            var minSeconds = entry.GetProperty("client_min").GetInt32();
            var winSeconds = entry.TryGetProperty("windows_client", out var winProp) ? winProp.GetInt32() : minSeconds;
            foreach (var command in entry.GetProperty("commands").EnumerateArray().Select(c => c.GetString()!))
            {
                var actual = OnboardingTimeouts.ForCommand(command);
                Assert.True(actual >= TimeSpan.FromSeconds(minSeconds), $"{command} timeout {actual} < {minSeconds}s");
                Assert.True(actual >= TimeSpan.FromSeconds(winSeconds), $"{command} windows timeout {actual} < {winSeconds}s");
            }
        }

        // Tailcat mode/relay reconfigurations allow 50s in cmd/agentd/tailcat.go plus 25s rollback.
        Assert.True(OnboardingTimeouts.TailcatReconfigure >= TimeSpan.FromSeconds(85));
        foreach (var command in new[] { "tailcat configure", "tailcat enter-managed", "tailcat exit-managed", "tailcat relay set", "tailcat relay-set" })
        {
            var byCommand = OnboardingTimeouts.ForCommand(command);
            var byArgs = OnboardingTimeouts.ForArguments(command.Split(' '));
            Assert.True(byCommand >= TimeSpan.FromSeconds(85), $"{command} timeout {byCommand} < 85s");
            Assert.True(byArgs >= TimeSpan.FromSeconds(85), $"{command} args timeout {byArgs} < 85s");
        }
        foreach (var sub in new[] { "enable", "disable", "pair" })
        {
            var actual = OnboardingTimeouts.ForArguments(["tailcat", sub, "--json"]);
            Assert.True(actual >= TimeSpan.FromSeconds(45), $"tailcat {sub} timeout {actual} < 45s");
        }
    }

    [Fact]
    public void 共享诊断矩阵全部正向与负向用例通过且拒绝越权动作()
    {
        using var document = JsonDocument.Parse(ReadFixture("onboarding-error-cases.json"));
        var cases = document.RootElement.EnumerateArray().ToArray();
        Assert.NotEmpty(cases);

        var executed = 0;
        foreach (var item in cases)
        {
            executed++;
            var id = item.GetProperty("id").GetString()!;
            var valid = item.GetProperty("valid").GetBoolean();
            var rawCtx = item.GetProperty("context");
            var surface = rawCtx.GetProperty("surface").GetString()!;
            var platform = rawCtx.GetProperty("platform").GetString()!;
            var verifiedCap = rawCtx.TryGetProperty("verified_capability", out var capProp) ? capProp.GetString() : null;

            if (string.Equals(surface, "report", StringComparison.Ordinal))
            {
                var patched = ApplyReportPatch(item.GetProperty("fixture").GetString()!, item.GetProperty("patch"));
                var ok = OnboardingCopyCatalog.TryDecodeAndValidateReport(patched, platform, nativeOverlay: false, verifiedCap, out _, out var err);
                if (ok != valid)
                {
                    Assert.Fail($"report case {id}: expected valid={valid}, err={err}");
                }
                continue;
            }

            var hasRecTransport = rawCtx.TryGetProperty("recommended_transport", out var recProp);
            var recTransport = hasRecTransport && recProp.ValueKind == JsonValueKind.String
                ? recProp.GetString()
                : null;
            var ctx = new OnboardingValidationContext
            {
                Surface = surface,
                Platform = platform,
                Stage = rawCtx.TryGetProperty("stage", out var stageProp) ? stageProp.GetString()! : "pair",
                Configured = rawCtx.TryGetProperty("configured", out var cfgProp) ? cfgProp.GetBoolean() : null,
                HasRecommendedTransport = hasRecTransport,
                RecommendedTransport = recTransport,
                VerifiedCapability = verifiedCap,
                ExplicitlyEnabled = rawCtx.TryGetProperty("explicitly_enabled", out var expProp) ? expProp.GetBoolean() : null,
            };
            var payload = item.GetProperty("payload").GetRawText();

            if (string.Equals(surface, "check", StringComparison.Ordinal)
                || string.Equals(surface, "native", StringComparison.Ordinal))
            {
                OnboardingResolvedDiagnostic? resolved = null;
                var ok = false;
                if (OnboardingCopyCatalog.TryDecodeCheck(payload, out var check, out var err))
                {
                    ok = OnboardingCopyCatalog.TryValidateCheck(check, ctx, out var validated, out err);
                    resolved = validated;
                }
                if (ok != valid)
                {
                    Assert.Fail($"check case {id}: expected valid={valid}, err={err}");
                }
                if (!valid && resolved is not null)
                {
                    Assert.Null(resolved.AllowedFix);
                }
            }
            else
            {
                var ok = OnboardingCopyCatalog.TryDecodeErrorEnvelope(payload, ctx, out var resolved, out var err);
                if (ok != valid)
                {
                    Assert.Fail($"envelope case {id}: expected valid={valid}, err={err}");
                }
                if (valid)
                {
                    Assert.True(resolved.Trusted, id);
                    Assert.NotNull(resolved.AllowedFix);
                }
                else
                {
                    Assert.Null(resolved.AllowedFix);
                    if (string.Equals(surface, "cli", StringComparison.Ordinal))
                    {
                        var cli = OnboardingCopyCatalog.ResolveCliError(payload, "", ctx);
                        Assert.NotNull(cli);
                        Assert.False(cli.Trusted);
                        Assert.Null(cli.AllowedFix);
                    }
                }
            }
        }
        Assert.Equal(cases.Length, executed);
    }

    [Fact]
    public void 共享预检报告和成功回执与无票设置全部正确解码()
    {
        (string File, string Platform, bool NativeOverlay)[] reports =
        [
            ("preflight-all-green.json", "macos", false),
            ("preflight-claude-only-no-network.json", "linux", false),
            ("preflight-codex-chatgpt-app.json", "macos", false),
            ("preflight-permission-needed.json", "macos", true),
            ("preflight-deepseek-only.json", "linux", false),
            ("preflight-windows-public.json", "windows", false),
        ];

        foreach (var (file, platform, nativeOverlay) in reports)
        {
            var ok = OnboardingCopyCatalog.TryDecodeAndValidateReport(
                ReadFixture(file),
                platform,
                nativeOverlay,
                verifiedCapability: null,
                out var report,
                out var error);
            Assert.True(ok, $"{file}: {error}");
            if (string.Equals(file, "preflight-codex-chatgpt-app.json", StringComparison.Ordinal))
            {
                var byId = report!.Checks.ToDictionary(c => c.Id, StringComparer.Ordinal);
                Assert.True(report.Ok);
                Assert.Equal("ok", byId["assistant_codex"].State);
                Assert.Equal("claude_signed_out", byId["assistant_claude"].Code);
                Assert.Equal("action_needed", byId["assistant_claude"].State);
                Assert.Equal("assistant_disabled", byId["assistant_agy"].Code);
                Assert.Equal("optional", byId["assistant_agy"].State);
            }
        }

        // No-QR setup receipts & optional PairingInfo.PairUrl
        Assert.True(OnboardingCopyCatalog.TryDecodeSetupReceipt(ReadFixture("setup-ok-no-assistant.json"), out var noAssist, out _));
        Assert.False(noAssist!.HasTicket);
        Assert.Null(noAssist.PairUrl);
        Assert.False(noAssist.ToPairingInfo().HasTicket);

        Assert.True(OnboardingCopyCatalog.TryDecodeSetupReceipt(ReadFixture("setup-ok-pairing-deferred.json"), out var deferred, out _));
        Assert.True(deferred!.PairingDeferred);
        Assert.False(deferred.HasTicket);

        var pairingFromNoTicket = JsonSerializer.Deserialize<PairingInfo>(ReadFixture("setup-ok-pairing-deferred.json"), AgentClient.JsonOptions)!;
        Assert.Null(pairingFromNoTicket.PairUrl);
        Assert.False(pairingFromNoTicket.HasTicket);

        // Old-host legacy setup ticket compatibility
        const string legacySetup = """{"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=legacy","pair_expires_at":"2030-01-01T00:05:00Z"}""";
        Assert.True(OnboardingCopyCatalog.TryDecodeSetupReceipt(legacySetup, out var legacy, out _));
        Assert.True(legacy!.IsLegacy);
        Assert.True(legacy.HasTicket);

        // P2-1: Legacy setup output with explicit ok:false MUST be rejected
        const string legacySetupOkFalse = """{"ok":false,"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=legacy","pair_expires_at":"2030-01-01T00:05:00Z"}""";
        Assert.False(OnboardingCopyCatalog.TryDecodeSetupReceipt(legacySetupOkFalse, out _, out _));

        // Up readiness vs submitted
        Assert.True(OnboardingCopyCatalog.TryDecodeUpReadinessReceipt(ReadFixture("up-ok-ready.json"), out var ready, out _));
        Assert.Equal("1.0.0", ready!.Version);
        Assert.False(OnboardingCopyCatalog.TryDecodeUpReadinessReceipt("""{"ok":true,"start_submitted":true}""", out _, out _));

        // Pair tickets + P2-2 strict RFC3339 / UTC expiry validation
        Assert.True(OnboardingCopyCatalog.TryDecodePairingTicketReceipt(ReadFixture("pair-ok-direct.json"), requireNetwork: true, out var direct, out _));
        Assert.Equal("tailscale", direct!.Network);
        Assert.True(OnboardingCopyCatalog.TryDecodePairingTicketReceipt(ReadFixture("pair-ok-tailcat.json"), requireNetwork: true, out var tailcat, out _));
        Assert.Equal("tailcat", tailcat!.Network);
        Assert.True(OnboardingCopyCatalog.TryDecodePairingTicketReceipt(
            """{"ok":true,"endpoint":"http://100.64.0.1:8787","pair_url":"mimiremote://pair?pair_sig=ok","pair_expires_at":"2030-01-01T00:05:00.123456789Z","network":"tailscale"}""",
            requireNetwork: true,
            out _,
            out _));
        // Non-UTC offset rejected on v1 ticket (ok:true), non-RFC3339 & impossible dates always rejected
        Assert.False(OnboardingCopyCatalog.TryDecodePairingTicketReceipt(
            """{"ok":true,"endpoint":"http://100.64.0.1:8787","pair_url":"mimiremote://pair?pair_sig=x","pair_expires_at":"2030-01-01T08:05:00+08:00","network":"tailscale"}""",
            requireNetwork: false,
            out _,
            out _));
        Assert.False(OnboardingCopyCatalog.TryDecodePairingTicketReceipt(
            """{"ok":true,"endpoint":"http://100.64.0.1:8787","pair_url":"mimiremote://pair?pair_sig=x","pair_expires_at":"2030-01-01","network":"tailscale"}""",
            requireNetwork: false,
            out _,
            out _));
        Assert.False(OnboardingCopyCatalog.TryDecodePairingTicketReceipt(
            """{"endpoint":"http://100.64.0.1:8787","pair_url":"mimiremote://pair?pair_sig=x","pair_expires_at":"2030-02-30T00:05:00Z"}""",
            requireNetwork: false,
            out _,
            out _));
        Assert.False(OnboardingCopyCatalog.TryDecodeSetupReceipt(
            """{"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=x","pair_expires_at":"tomorrow"}""",
            out _,
            out _));
        Assert.False(OnboardingCopyCatalog.TryDecodeSetupReceipt(
            """{"ok":true,"configured":true,"created":true,"config_path":"/c","scan_root":"/s","browse_root":"/s","endpoint":"http://100.64.0.1:8787","pair_url":"mimiremote://pair?pair_sig=x","pair_expires_at":"2030-01-01T08:05:00+08:00"}""",
            out _,
            out _));
        // Legacy ticket without ok still accepts valid RFC3339 offset
        Assert.True(OnboardingCopyCatalog.TryDecodePairingTicketReceipt(
            """{"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=legacy","pair_expires_at":"2030-01-01T08:05:00+08:00"}""",
            requireNetwork: false,
            out _,
            out _));
        Assert.True(OnboardingCopyCatalog.TryParseRfc3339Timestamp("2030-01-01T00:05:00.123456789Z", requireUtc: true, out _));
    }

    [Fact]
    public void 不兼容的输出不得授权动作或签发票据()
    {
        var row = JsonNode.Parse(ReadFixture("preflight-progress-slow-assistant.ndjson")
            .Split('\n', StringSplitOptions.RemoveEmptyEntries)[^1])!.AsObject();
        var context = new OnboardingValidationContext { Surface = "check", Platform = "macos", Stage = "pair" };
        var acc = new OnboardingProgressAccumulator(1, context);
        Assert.True(acc.ApplyLine(1, row.ToJsonString()));
        foreach (var schema in new[] { "mimi.onboarding.preflight/v2", "other/v2", "mimi.onboarding.preflight/v2/v1" })
        {
            row["schema"] = schema;
            Assert.False(acc.ApplyLine(1, row.ToJsonString()));
        }
        var unsupported = """{"schema":"mimi.onboarding.preflight/v2"}""";
        var legacy = OnboardingCopyCatalog.ResolveCliError(unsupported, "unknown command preflight", context with { Surface = "cli" }, ["preflight"]);
        Assert.Null(legacy?.AllowedFix);

        var ticket = JsonNode.Parse(ReadFixture("pair-ok-direct.json"))!.AsObject();
        ticket.Remove("network");
        Assert.False(OnboardingCopyCatalog.TryDecodePairingTicketReceipt(ticket.ToJsonString(), false, out _, out _));
        ticket.Remove("ok");
        Assert.True(OnboardingCopyCatalog.TryDecodePairingTicketReceipt(ticket.ToJsonString(), false, out _, out _));
        ticket["schema"] = "mimi.onboarding.ticket/v2";
        Assert.False(OnboardingCopyCatalog.TryDecodePairingTicketReceipt(ticket.ToJsonString(), false, out _, out _));
        Assert.False(OnboardingCopyCatalog.TryDecodeSetupReceipt(ticket.ToJsonString(), out _, out _));
    }

    [Fact]
    public void 仅匹配当前命令的首行旧版诊断()
    {
        const string oldPreflight = "错误：未知命令 \"preflight\"，可用命令：up、setup、start";
        const string oldFlag = "flag provided but not defined: -no-pair\nUsage of setup:";
        var context = new OnboardingValidationContext { Surface = "cli" };
        Assert.True(OnboardingCopyCatalog.ResolveCliError("", oldPreflight, context, ["preflight"])?.LegacyHost);
        Assert.True(OnboardingCopyCatalog.ResolveCliError("", oldFlag, context, ["setup", "--no-pair"])?.LegacyHost);
        Assert.Null(OnboardingCopyCatalog.ResolveCliError("", oldPreflight, context, ["pair"]));
        Assert.Null(OnboardingCopyCatalog.ResolveCliError("", oldFlag, context, ["setup", "--qr-only"]));
        Assert.Null(OnboardingCopyCatalog.ResolveCliError("", "failed\n" + oldPreflight, context, ["preflight"]));
    }

    [Fact]
    public void 回退诊断和票据警告不返回任意命令文本()
    {
        const string raw = "Authorization: Bearer samplepassword";
        var diagnostic = OnboardingCopyCatalog.UnknownCommandFallback(1, raw);
        Assert.DoesNotContain("samplepassword", diagnostic.SanitizedDiagnostic!, StringComparison.Ordinal);
        var ticket = JsonNode.Parse(ReadFixture("pair-ok-direct.json"))!.AsObject();
        ticket["warnings"] = new JsonArray(raw);
        Assert.True(OnboardingCopyCatalog.TryDecodePairingTicketReceipt(ticket.ToJsonString(), false, out var receipt, out _));
        Assert.DoesNotContain("samplepassword", Assert.Single(receipt!.Warnings), StringComparison.Ordinal);

        var envelope = JsonNode.Parse(ReadFixture("setup-error-config-invalid.json"))!.AsObject();
        var fields = envelope["error"]!.AsObject();
        fields["config_path"] = @"C:\private\example\config.json";
        fields["recovery_path"] = "/private/example/samplepassword";
        var context = new OnboardingValidationContext { Surface = "cli" };
        Assert.True(OnboardingCopyCatalog.TryDecodeErrorEnvelope(envelope.ToJsonString(), context, out var error, out _));
        Assert.Equal("…/config.json", error.ConfigPath);
        Assert.Equal("恢复文件", error.RecoveryPath);
    }

    [Fact]
    public void 慢助手流式进度先显示已完成项且取消不覆盖终态()
    {
        var lines = ReadFixture("preflight-progress-slow-assistant.ndjson")
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        Assert.Equal(36, lines.Length);

        var macPairCtx = new OnboardingValidationContext
        {
            Surface = "check",
            Platform = "macos",
            Stage = "pair",
            Configured = false,
        };
        var acc = new OnboardingProgressAccumulator(1, macPairCtx);
        Assert.False(acc.ApplyLine(1, "malformed non-json stderr noise"));
        // Invalid code/action progress rows MUST be rejected before publishing
        Assert.False(acc.ApplyLine(1, """{"id":"assistant_claude","group":"assistant","state":"action_needed","title":"Claude","detail":"请登录","blocking":false,"enabled":true,"available":false,"candidates":[{"path":"/fixture/bin/claude","outcome":"selected"}],"code":"claude_signed_out","fix":{"kind":"open_url","url":"https://learn.chatgpt.com/docs/codex/cli"}}"""));
        Assert.False(acc.ApplyLine(1, """{"id":"service_daemon","group":"service","state":"action_needed","title":"后台服务","detail":"未运行","blocking":true,"code":"service_not_running","fix":{"kind":"run_fix","action":"restart_service"}}"""));
        for (var i = 0; i < 26; i++)
        {
            Assert.True(acc.ApplyLine(1, lines[i]));
        }

        var (midRows, midReport) = acc.Snapshot();
        Assert.Null(midReport);
        var byId = midRows.ToDictionary(r => r.Id, StringComparer.Ordinal);
        Assert.Equal("ok", byId["assistant_codex"].State);
        Assert.Equal("ok", byId["assistant_any"].State);
        Assert.Equal("checking", byId["assistant_claude"].State);

        for (var i = 26; i < lines.Length; i++)
        {
            Assert.True(acc.ApplyLine(1, lines[i]));
        }
        Assert.True(OnboardingCopyCatalog.TryDecodeAndValidateReport(
            ReadFixture("preflight-codex-chatgpt-app.json"),
            "macos",
            expectedStage: "pair",
            nativeOverlay: false,
            verifiedCapability: null,
            out var finalReport,
            out _));
        Assert.NotNull(finalReport);
        Assert.True(acc.Complete(1, finalReport));

        // Late cancel and late line must not overwrite terminal state.
        acc.Cancel(1);
        Assert.False(acc.ApplyLine(1, lines[0]));
        Assert.Equal(finalReport, acc.Snapshot().Report);

        // Cancelled generation rejects subsequent updates and completion.
        var cancelled = new OnboardingProgressAccumulator(2, macPairCtx);
        Assert.True(cancelled.ApplyLine(2, lines[0]));
        cancelled.Cancel(2);
        Assert.False(cancelled.ApplyLine(2, lines[18]));
        Assert.False(cancelled.Complete(2, finalReport));
    }

    [Fact]
    public async Task 阶段校验脱敏诊断和WinUI设置回执门禁生效()
    {
        // P1-2: ResolveStage distinguishes preflight --stage pair from setup
        Assert.Equal("pair", AgentClient.ResolveStage(["preflight", "--json", "--stage", "pair"]));
        Assert.Equal("pair", AgentClient.ResolveStage(["preflight", "--json", "--stage=pair"]));
        Assert.Equal("setup", AgentClient.ResolveStage(["preflight", "--json", "--stage", "setup"]));
        Assert.Equal("setup", AgentClient.ResolveStage(["preflight", "--json"]));
        Assert.Equal("setup", AgentClient.ResolveStage(["setup", "--no-pair", "--json"]));

        // P1-3: A valid ok:true setup report MUST NOT satisfy a pair preflight request
        Assert.False(OnboardingCopyCatalog.TryDecodeAndValidateReport(
            ReadFixture("preflight-claude-only-no-network.json"),
            "linux",
            expectedStage: "pair",
            nativeOverlay: false,
            verifiedCapability: null,
            out _,
            out var stageError));
        Assert.Contains("stage", stageError, StringComparison.Ordinal);

        // P1-1: Diagnostic sanitizer strips bearer, pair_url, private paths, JWT, unmarked credentials and bounds length
        var raw = @"fatal: Bearer secretBearer999 mimiremote://pair?pair_sig=leak123 C:\Users\alice\secret.json /Users/alice/key eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc123def456 UnmarkedCred9876543210ABCDEF " + new string('z', 300);
        var sanitized = OnboardingCopyCatalog.SanitizeDiagnostic(raw);
        Assert.InRange(sanitized.Length, 1, 180);
        foreach (var secret in ForbiddenLeakTokens)
        {
            Assert.DoesNotContain(secret, sanitized, StringComparison.Ordinal);
        }

        // P1-4: Production SetupViewModel validates SetupReceipt before starting service
        var tempRoot = Path.Combine(Path.GetTempPath(), "mimi-setup-vm-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        var previousConfigPath = DesktopPreferences.ConfigPath;
        try
        {
            DesktopPreferences.ConfigPath = Path.Combine(tempRoot, "missing-config.json");

            // Invalid setup stdout (ok:false) MUST fail and NEVER call up or workspace
            var badContext = new ClientContext
            {
                Confirm = (_, _) => Task.FromResult(true),
            };
            badContext.Agent.RunHandler = (args, _) => Task.FromResult(args[0] == "setup"
                ? """{"ok":false,"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=x","pair_expires_at":"2030-01-01T00:05:00Z"}"""
                : "{}");
            var fresh = JsonNode.Parse(ReadFixture("preflight-claude-only-no-network.json"))!;
            var pairReportJson = ReadFixture("preflight-windows-public.json");
            fresh["checks"]!.AsArray().Add(JsonNode.Parse(pairReportJson)!["checks"]!.AsArray()[^1]!.DeepClone());
            fresh["scan_root"] = tempRoot;
            fresh["browse_root"] = tempRoot;
            var freshJson = fresh.ToJsonString();
            badContext.Agent.PreflightHandler = (options, _, _) => Task.FromResult(AgentClient.DecodePreflightReport(freshJson, "windows", options));
            using var badVm = new SetupViewModel(badContext);
            await badVm.NextFromStep1Command.ExecuteAsync(null);
            await badVm.FinishCommand.ExecuteAsync(null);
            Assert.True(badVm.Failed);
            Assert.Single(badContext.Agent.Calls, call => call[0] == "setup");
            Assert.DoesNotContain(badContext.Agent.Calls, call => call[0] is "up" or "start" or "workspace");

            // Valid no-ticket setup receipt saves once with --no-pair and --browse-root == scan_root, then calls up (no scary dialog, no redundant workspace)
            var confirmCalls = 0;
            var goodContext = new ClientContext
            {
                Confirm = (_, _) => { confirmCalls++; return Task.FromResult(true); },
            };
            var deferredJson = ReadFixture("setup-ok-pairing-deferred.json");
            var upReadyJson = ReadFixture("up-ok-ready.json");
            goodContext.Agent.RunHandler = (args, _) => Task.FromResult(args[0] switch
            {
                "setup" => deferredJson,
                "up" => upReadyJson,
                "preflight" => pairReportJson,
                _ => "{}",
            });
            goodContext.Agent.PreflightHandler = (options, _, _) => Task.FromResult(
                AgentClient.DecodePreflightReport(options.Stage == "setup" ? freshJson : pairReportJson, "windows", options));
            using var goodVm = new SetupViewModel(goodContext);
            await goodVm.NextFromStep1Command.ExecuteAsync(null);
            await goodVm.FinishCommand.ExecuteAsync(null);
            Assert.False(goodVm.Failed);
            Assert.Equal(0, confirmCalls);
            Assert.Equal(OnboardingWizardStep.ServiceAndPermissions, goodVm.Wizard.CurrentStep);
            var setupCall = Assert.Single(goodContext.Agent.Calls, call => call[0] == "setup");
            Assert.Contains("--no-pair", setupCall, StringComparer.Ordinal);
            Assert.Contains("--browse-root", setupCall, StringComparer.Ordinal);
            Assert.Equal(["setup", "up"], goodContext.Agent.Calls.Select(call => call[0]).Where(name => name != "preflight"));
            Assert.DoesNotContain(goodContext.Agent.Calls, call => string.Equals(call[0], "workspace", StringComparison.Ordinal));
        }
        finally
        {
            DesktopPreferences.ConfigPath = previousConfigPath;
            if (Directory.Exists(tempRoot))
            {
                Directory.Delete(tempRoot, recursive: true);
            }
        }
    }

    [Fact]
    public void UnverifiedPermissionRepairLocksWindowsWithoutOfferingAnAction()
    {
        var report = JsonNode.Parse(ReadFixture("preflight-windows-public.json"))!;
        report["recommended_next"] = "config_store";
        var config = report["checks"]!.AsArray()[0]!;
        config["state"] = "error";
        config["blocking"] = true;
        config["code"] = "config_permissions_unsafe";
        config["fix"] = JsonNode.Parse("""{"kind":"run_fix","action":"doctor_fix"}""");
        var options = new OnboardingPreflightOptions { Stage = "pair" };

        var failure = Assert.Throws<OnboardingCliException>(() => AgentClient.DecodePreflightReport(report.ToJsonString(), "windows", options));
        Assert.Equal(OnboardingGateState.RecoveryLocked, OnboardingNavigationGate.Evaluate(null, failure.Diagnostic));
        Assert.Null(failure.Diagnostic!.AllowedFix);
        config["fix"]!["rotates_token"] = true;
        Assert.Throws<InvalidDataException>(() => AgentClient.DecodePreflightReport(report.ToJsonString(), "windows", options));
    }

    private static readonly string[] ForbiddenLeakTokens =
    [
        "secretBearer999",
        "mimiremote://",
        "pair_sig",
        @"C:\Users\alice",
        "/Users/alice",
        "eyJhbGci",
        "UnmarkedCred9876543210ABCDEF",
    ];

    private static string ApplyReportPatch(string fixture, JsonElement patches)
    {
        var root = JsonNode.Parse(ReadFixture(fixture))!.AsObject();
        foreach (var patch in patches.EnumerateArray())
        {
            var op = patch.GetProperty("op").GetString()!;
            var path = patch.GetProperty("path").GetString()!;
            var key = path[1..];
            if (key.StartsWith("checks/", StringComparison.Ordinal))
            {
                var checks = root["checks"]!.AsArray();
                var suffix = key["checks/".Length..];
                if (string.Equals(op, "add", StringComparison.Ordinal) && string.Equals(suffix, "-", StringComparison.Ordinal))
                {
                    checks.Add(JsonNode.Parse(patch.GetProperty("value").GetRawText()));
                }
                else
                {
                    var slash = suffix.IndexOf('/');
                    if (slash < 0)
                    {
                        var idx = int.Parse(suffix, CultureInfo.InvariantCulture);
                        if (string.Equals(op, "replace", StringComparison.Ordinal))
                        {
                            checks[idx] = JsonNode.Parse(patch.GetProperty("value").GetRawText());
                        }
                        else if (string.Equals(op, "remove", StringComparison.Ordinal))
                        {
                            checks.RemoveAt(idx);
                        }
                        else
                        {
                            throw new InvalidOperationException($"unsupported checks patch {op} {path}");
                        }
                    }
                    else
                    {
                        var idx = int.Parse(suffix[..slash], CultureInfo.InvariantCulture);
                        var field = suffix[(slash + 1)..];
                        var rowObj = checks[idx]!.AsObject();
                        if (string.Equals(op, "remove", StringComparison.Ordinal))
                        {
                            rowObj.Remove(field);
                        }
                        else
                        {
                            rowObj[field] = JsonNode.Parse(patch.GetProperty("value").GetRawText());
                        }
                    }
                }
            }
            else if (string.Equals(op, "remove", StringComparison.Ordinal))
            {
                root.Remove(key);
            }
            else
            {
                root[key] = JsonNode.Parse(patch.GetProperty("value").GetRawText());
            }
        }
        return root.ToJsonString();
    }

    private static string ReadFixture(string name)
    {
        var copied = Path.Combine(AppContext.BaseDirectory, "fixtures", name);
        if (File.Exists(copied))
        {
            return File.ReadAllText(copied);
        }
        var relative = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "contracts", "host-cli", name));
        return File.ReadAllText(relative);
    }
}
