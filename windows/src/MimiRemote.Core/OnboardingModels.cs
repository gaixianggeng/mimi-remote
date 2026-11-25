using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace MimiRemote.Core;

public static class OnboardingSchema
{
    public const string PreflightV1 = "mimi.onboarding.preflight/v1";
    public const string CodesV1 = "mimi.onboarding.codes/v1";
    public const string MediaTypeV1 = "application/vnd.mimi.onboarding.v1+json";
    public const string DoctorFixCapability = "identity_preserving_doctor_fix";
}

public static class OnboardingTimeouts
{
    public static TimeSpan Preflight { get; } = TimeSpan.FromSeconds(35);
    public static TimeSpan Setup { get; } = TimeSpan.FromSeconds(60);
    public static TimeSpan Pair { get; } = TimeSpan.FromSeconds(45);
    public static TimeSpan Runtime { get; } = TimeSpan.FromSeconds(45);
    public static TimeSpan Network { get; } = TimeSpan.FromSeconds(45);
    public static TimeSpan Workspace { get; } = TimeSpan.FromSeconds(45);
    public static TimeSpan DoctorFix { get; } = TimeSpan.FromSeconds(45);
    public static TimeSpan ServiceWait { get; } = TimeSpan.FromSeconds(120);

    public static TimeSpan ForCommand(string command) => command switch
    {
        "preflight" => Preflight,
        "setup" => Setup,
        "pair" or "tailcat pair" => Pair,
        "runtime" => Runtime,
        "network" => Network,
        "workspace" => Workspace,
        "doctor --fix" => DoctorFix,
        "up" or "start" or "restart" => ServiceWait,
        _ => ServiceWait,
    };

    public static TimeSpan ForArguments(IReadOnlyList<string> arguments)
    {
        if (arguments.Count == 0)
        {
            return ServiceWait;
        }
        var first = arguments[0];
        if (string.Equals(first, "tailcat", StringComparison.Ordinal) && arguments.Count > 1)
        {
            var sub = arguments[1];
            if (string.Equals(sub, "pair", StringComparison.Ordinal))
            {
                return Pair;
            }
            if (string.Equals(sub, "enable", StringComparison.Ordinal)
                || string.Equals(sub, "disable", StringComparison.Ordinal)
                || string.Equals(sub, "relay", StringComparison.Ordinal)
                || string.Equals(sub, "configure", StringComparison.Ordinal))
            {
                return TimeSpan.FromSeconds(55);
            }
        }
        if (string.Equals(first, "doctor", StringComparison.Ordinal))
        {
            for (var i = 1; i < arguments.Count; i++)
            {
                if (string.Equals(arguments[i], "--fix", StringComparison.Ordinal))
                {
                    return DoctorFix;
                }
            }
        }
        return ForCommand(first);
    }
}

[JsonConverter(typeof(OnboardingFixJsonConverter))]
public sealed record OnboardingFix
{
    public required string Kind { get; init; }
    public string? Url { get; init; }
    public string? Target { get; init; }
    public string? Action { get; init; }

    public static OnboardingFix Retry { get; } = new() { Kind = "retry" };
    public static OnboardingFix Skip { get; } = new() { Kind = "skip" };
    public static OnboardingFix OpenUrl(string url) => new() { Kind = "open_url", Url = url };
    public static OnboardingFix OpenSettings(string target) => new() { Kind = "open_settings", Target = target };
    public static OnboardingFix ChoosePath(string target) => new() { Kind = "choose_path", Target = target };
    public static OnboardingFix RunFix(string action) => new() { Kind = "run_fix", Action = action };
}

public sealed class OnboardingFixJsonConverter : JsonConverter<OnboardingFix>
{
    public override OnboardingFix Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var document = JsonDocument.ParseValue(ref reader);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new JsonException("fix must be a JSON object.");
        }

        string? kind = null;
        string? url = null;
        string? target = null;
        string? action = null;
        var propertyCount = 0;

        foreach (var prop in root.EnumerateObject())
        {
            propertyCount++;
            if (prop.Value.ValueKind != JsonValueKind.String)
            {
                throw new JsonException($"fix property '{prop.Name}' must be a string.");
            }
            var value = prop.Value.GetString();
            switch (prop.Name)
            {
                case "kind":
                    kind = value;
                    break;
                case "url":
                    url = value;
                    break;
                case "target":
                    target = value;
                    break;
                case "action":
                    action = value;
                    break;
                default:
                    throw new JsonException($"unexpected fix property '{prop.Name}'.");
            }
        }

        return kind switch
        {
            "retry" when propertyCount == 1 => OnboardingFix.Retry,
            "skip" when propertyCount == 1 => OnboardingFix.Skip,
            "open_url" when propertyCount == 2 && url is not null && OnboardingCopyCatalog.IsAllowedUrl(url) =>
                OnboardingFix.OpenUrl(url),
            "open_settings" when propertyCount == 2 && target is not null && OnboardingCopyCatalog.IsAllowedSettingsTarget(target) =>
                OnboardingFix.OpenSettings(target),
            "choose_path" when propertyCount == 2 && target is not null && OnboardingCopyCatalog.IsAllowedPathTarget(target) =>
                OnboardingFix.ChoosePath(target),
            "run_fix" when propertyCount == 2 && action is not null && OnboardingCopyCatalog.IsAllowedRunFixAction(action) =>
                OnboardingFix.RunFix(action),
            _ => throw new JsonException("fix object does not match the closed v1 allow-list."),
        };
    }

    public override void Write(Utf8JsonWriter writer, OnboardingFix value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("kind", value.Kind);
        if (value.Url is not null)
        {
            writer.WriteString("url", value.Url);
        }
        if (value.Target is not null)
        {
            writer.WriteString("target", value.Target);
        }
        if (value.Action is not null)
        {
            writer.WriteString("action", value.Action);
        }
        writer.WriteEndObject();
    }
}

public sealed record OnboardingCandidate
{
    public required string Path { get; init; }
    public required string Outcome { get; init; }
    public string? Version { get; init; }
}

public sealed record OnboardingCheck
{
    public required string Id { get; init; }
    public required string Group { get; init; }
    public required string State { get; init; }
    public required string Title { get; init; }
    public required string Detail { get; init; }
    public bool Blocking { get; init; }
    public string? Code { get; init; }
    public OnboardingFix? Fix { get; init; }
    public string? ConfigPath { get; init; }
    public string? RecoveryPath { get; init; }
    public bool? Enabled { get; init; }
    public bool? Available { get; init; }
    public IReadOnlyList<OnboardingCandidate>? Candidates { get; init; }
    public string? Source { get; init; }
    public string? DetectedVersion { get; init; }
    public string? MinVersion { get; init; }

    internal bool HasAvailableKey { get; init; }
    internal bool HasCandidatesKey { get; init; }
    internal bool HasCodeKey { get; init; }
    internal bool HasFixKey { get; init; }
    internal bool HasConfigPathKey { get; init; }
    internal bool HasRecoveryPathKey { get; init; }

    public string? SelectedOrDetectedVersion
    {
        get
        {
            if (!string.IsNullOrWhiteSpace(DetectedVersion))
            {
                return DetectedVersion;
            }
            if (Candidates is not null)
            {
                foreach (var candidate in Candidates)
                {
                    if (string.Equals(candidate.Outcome, "selected", StringComparison.Ordinal)
                        && !string.IsNullOrWhiteSpace(candidate.Version))
                    {
                        return candidate.Version;
                    }
                }
            }
            return null;
        }
    }
}

public sealed record OnboardingPreflightReport
{
    public required string Schema { get; init; }
    public bool Ok { get; init; }
    public required string Stage { get; init; }
    public bool Configured { get; init; }
    public bool WorkspaceConfirmed { get; init; }
    public required string ConfigPath { get; init; }
    public required string ScanRoot { get; init; }
    public required string BrowseRoot { get; init; }
    public bool ScanRootExists { get; init; }
    public required string RecommendedNext { get; init; }
    public string? RecommendedTransport { get; init; }
    public required IReadOnlyList<OnboardingCheck> Checks { get; init; }
}

public sealed record SetupReceipt
{
    public bool Ok { get; init; }
    public bool Configured { get; init; }
    public bool Created { get; init; }
    public string ConfigPath { get; init; } = "";
    public string ScanRoot { get; init; } = "";
    public string BrowseRoot { get; init; } = "";
    public bool? PairingDeferred { get; init; }
    public string? Endpoint { get; init; }
    public string? PairUrl { get; init; }
    public string? PairExpiresAt { get; init; }
    public string? Network { get; init; }
    public string? TailscaleDnsName { get; init; }
    public string? TailscaleDeviceName { get; init; }
    public IReadOnlyList<string> Warnings { get; init; } = [];
    public bool IsLegacy { get; init; }
    public bool HasTicket => !string.IsNullOrWhiteSpace(PairUrl);

    public PairingInfo ToPairingInfo() => new()
    {
        Ok = Ok,
        Endpoint = Endpoint ?? "",
        Network = Network,
        PairUrl = PairUrl,
        PairExpiresAt = PairExpiresAt ?? "",
        TailscaleDnsName = TailscaleDnsName,
        TailscaleDeviceName = TailscaleDeviceName,
        Warnings = [.. Warnings],
    };
}

public sealed record UpReadinessReceipt
{
    public bool Ok { get; init; }
    public bool ServiceOk { get; init; }
    public required string Version { get; init; }
    public IReadOnlyList<string> Warnings { get; init; } = [];
}

public sealed record PairingTicketReceipt
{
    public bool Ok { get; init; }
    public required string Endpoint { get; init; }
    public required string PairUrl { get; init; }
    public required string PairExpiresAt { get; init; }
    public string? Network { get; init; }
    public string? TailscaleDnsName { get; init; }
    public string? TailscaleDeviceName { get; init; }
    public IReadOnlyList<string> Warnings { get; init; } = [];

    public PairingInfo ToPairingInfo() => new()
    {
        Ok = Ok,
        Endpoint = Endpoint,
        Network = Network,
        PairUrl = PairUrl,
        PairExpiresAt = PairExpiresAt,
        TailscaleDnsName = TailscaleDnsName,
        TailscaleDeviceName = TailscaleDeviceName,
        Warnings = [.. Warnings],
    };
}

public sealed record OnboardingPreflightOptions
{
    public string Stage { get; init; } = "setup";
    public string? ConfigPath { get; init; }
    public string? ScanRoot { get; init; }
    public string? BrowseRoot { get; init; }
    public bool ProgressJson { get; init; } = true;
    public IReadOnlyList<(string Id, string Value)> RuntimePaths { get; init; } = [];
    public IReadOnlyList<(string Id, string Value)> Assistants { get; init; } = [];
}

public sealed record OnboardingSetupOptions
{
    public string? BrowseRoot { get; init; }
    public bool NoPair { get; init; } = true;
    public IReadOnlyList<(string Id, string Value)> RuntimePaths { get; init; } = [];
    public IReadOnlyList<(string Id, string Value)> Assistants { get; init; } = [];
}

public sealed record OnboardingValidationContext
{
    public required string Surface { get; init; }
    public string Platform { get; init; } = "windows";
    public string Stage { get; init; } = "pair";
    public bool? Configured { get; init; } = true;
    public bool HasRecommendedTransport { get; init; }
    public string? RecommendedTransport { get; init; }
    public string? VerifiedCapability { get; init; }
    public bool? ExplicitlyEnabled { get; init; }
}

public sealed record OnboardingResolvedDiagnostic
{
    public string? Code { get; init; }
    public string? Step { get; init; }
    public required string Message { get; init; }
    public OnboardingFix? AllowedFix { get; init; }
    public OnboardingFix? SecondaryFix { get; init; }
    public string? SecondaryLabel { get; init; }
    public string? ConfigPath { get; init; }
    public string? RecoveryPath { get; init; }
    public bool Trusted { get; init; }
    public bool LegacyHost { get; init; }
}

public sealed class OnboardingCliException : InvalidOperationException
{
    public OnboardingResolvedDiagnostic? Diagnostic { get; }

    public OnboardingCliException()
    {
    }

    public OnboardingCliException(string message)
        : base(message)
    {
    }

    public OnboardingCliException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public OnboardingCliException(OnboardingResolvedDiagnostic diagnostic)
        : base(diagnostic.Message)
    {
        Diagnostic = diagnostic;
    }
}

public sealed class OnboardingProgressAccumulator
{
    private readonly object gate = new();
    private readonly List<string> order = [];
    private readonly Dictionary<string, OnboardingCheck> byId = new(StringComparer.Ordinal);
    private OnboardingPreflightReport? finalReport;
    private bool terminal;
    private ulong generation;

    public OnboardingProgressAccumulator(ulong generation = 1)
    {
        this.generation = generation;
    }

    public bool ApplyLine(ulong runGeneration, string line)
    {
        if (string.IsNullOrWhiteSpace(line))
        {
            return false;
        }
        if (!OnboardingCopyCatalog.TryDecodeCheck(line, out var check, out _))
        {
            return false;
        }
        return ApplyCheck(runGeneration, check);
    }

    public bool ApplyCheck(ulong runGeneration, OnboardingCheck check)
    {
        if (!OnboardingCopyCatalog.IsKnownCheckId(check.Id) || !OnboardingCopyCatalog.IsValidCheckState(check.State))
        {
            return false;
        }
        lock (gate)
        {
            if (terminal || runGeneration != generation)
            {
                return false;
            }
            if (!byId.ContainsKey(check.Id))
            {
                order.Add(check.Id);
            }
            byId[check.Id] = check;
            return true;
        }
    }

    public bool Complete(ulong runGeneration, OnboardingPreflightReport report)
    {
        lock (gate)
        {
            if (terminal || runGeneration != generation)
            {
                return false;
            }
            finalReport = report;
            order.Clear();
            byId.Clear();
            foreach (var check in report.Checks)
            {
                order.Add(check.Id);
                byId[check.Id] = check;
            }
            terminal = true;
            return true;
        }
    }

    public void Cancel(ulong runGeneration)
    {
        lock (gate)
        {
            if (terminal || runGeneration != generation)
            {
                return;
            }
            generation++;
        }
    }

    public (IReadOnlyList<OnboardingCheck> Checks, OnboardingPreflightReport? Report) Snapshot()
    {
        lock (gate)
        {
            var list = new List<OnboardingCheck>(order.Count);
            foreach (var id in order)
            {
                list.Add(byId[id]);
            }
            return (list, finalReport);
        }
    }

    internal static bool IsValidUtcRfc3339(string value) =>
        DateTimeOffset.TryParse(
            value,
            CultureInfo.InvariantCulture,
            DateTimeStyles.RoundtripKind,
            out _);
}
