using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
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
            Assert.True(entry.MessageZh.Any(ch => ch >= '\u4E00' && ch <= '\u9FFF'));
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
                Assert.True(ok == valid, $"report case {id}: expected valid={valid}, err={err}");
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
                var ok = OnboardingCopyCatalog.TryDecodeCheck(payload, out var check, out var err)
                    && OnboardingCopyCatalog.TryValidateCheck(check, ctx, out resolved, out err);
                Assert.True(ok == valid, $"check case {id}: expected valid={valid}, err={err}");
                if (!valid && resolved is not null)
                {
                    Assert.Null(resolved.AllowedFix);
                }
            }
            else
            {
                var ok = OnboardingCopyCatalog.TryDecodeErrorEnvelope(payload, ctx, out var resolved, out var err);
                Assert.True(ok == valid, $"envelope case {id}: expected valid={valid}, err={err}");
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
        Assert.Equal(true, deferred!.PairingDeferred);
        Assert.False(deferred.HasTicket);

        var pairingFromNoTicket = JsonSerializer.Deserialize<PairingInfo>(ReadFixture("setup-ok-pairing-deferred.json"), AgentClient.JsonOptions)!;
        Assert.Null(pairingFromNoTicket.PairUrl);
        Assert.False(pairingFromNoTicket.HasTicket);

        // Old-host legacy setup ticket compatibility
        const string legacySetup = """{"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=legacy","pair_expires_at":"2030-01-01T00:05:00Z"}""";
        Assert.True(OnboardingCopyCatalog.TryDecodeSetupReceipt(legacySetup, out var legacy, out _));
        Assert.True(legacy!.IsLegacy);
        Assert.True(legacy.HasTicket);

        // Up readiness vs submitted
        Assert.True(OnboardingCopyCatalog.TryDecodeUpReadinessReceipt(ReadFixture("up-ok-ready.json"), out var ready, out _));
        Assert.Equal("1.0.0", ready!.Version);
        Assert.False(OnboardingCopyCatalog.TryDecodeUpReadinessReceipt("""{"ok":true,"start_submitted":true}""", out _, out _));

        // Pair tickets
        Assert.True(OnboardingCopyCatalog.TryDecodePairingTicketReceipt(ReadFixture("pair-ok-direct.json"), requireNetwork: true, out var direct, out _));
        Assert.Equal("tailscale", direct!.Network);
        Assert.True(OnboardingCopyCatalog.TryDecodePairingTicketReceipt(ReadFixture("pair-ok-tailcat.json"), requireNetwork: true, out var tailcat, out _));
        Assert.Equal("tailcat", tailcat!.Network);
    }

    [Fact]
    public void 慢助手流式进度先显示已完成项且取消不覆盖终态()
    {
        var lines = ReadFixture("preflight-progress-slow-assistant.ndjson")
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        Assert.Equal(36, lines.Length);

        var acc = new OnboardingProgressAccumulator(1);
        Assert.False(acc.ApplyLine(1, "malformed non-json stderr noise"));
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
            nativeOverlay: false,
            verifiedCapability: null,
            out var finalReport,
            out _));
        Assert.True(acc.Complete(1, finalReport!));

        // Late cancel and late line must not overwrite terminal state.
        acc.Cancel(1);
        Assert.False(acc.ApplyLine(1, lines[0]));
        Assert.Equal(finalReport, acc.Snapshot().Report);

        // Cancelled generation rejects subsequent updates and completion.
        var cancelled = new OnboardingProgressAccumulator(2);
        Assert.True(cancelled.ApplyLine(2, lines[0]));
        cancelled.Cancel(2);
        Assert.False(cancelled.ApplyLine(2, lines[18]));
        Assert.False(cancelled.Complete(2, finalReport));
    }

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
                else if (string.Equals(op, "remove", StringComparison.Ordinal))
                {
                    checks.RemoveAt(int.Parse(suffix, CultureInfo.InvariantCulture));
                }
                else
                {
                    throw new InvalidOperationException($"unsupported checks patch {op} {path}");
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
