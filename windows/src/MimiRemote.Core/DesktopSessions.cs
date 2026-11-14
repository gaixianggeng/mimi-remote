using System.Globalization;
using System.Text.Json;

namespace MimiRemote.Core;

public enum SessionActivity { Unknown, Idle, Running, WaitingForApproval, WaitingForInput, Failed }

public sealed record DesktopSession(
    string Runtime, string ThreadId, string Title, string ProjectName, string Cwd,
    DateTimeOffset? UpdatedAt, SessionActivity Activity, string? Holder = null)
{
    public string Key => Runtime + ":" + ThreadId;
    public string RuntimeTitle => Runtime switch { "codex" => "Codex", "claude" => "Claude", _ => "DeepSeek" };
    public string Status => Activity switch
    {
        SessionActivity.Idle => "空闲",
        SessionActivity.Running => "运行中",
        SessionActivity.WaitingForApproval => "待审批",
        SessionActivity.WaitingForInput => "待输入",
        SessionActivity.Failed => "失败",
        _ => "状态未知",
    };
    public bool Matches(string query) => Title.Contains(query.Trim(), StringComparison.OrdinalIgnoreCase)
        || ProjectName.Contains(query.Trim(), StringComparison.OrdinalIgnoreCase);
}

public sealed record SessionProject(string Name, string Cwd);
public sealed record SessionCatalog(IReadOnlyList<string> Runtimes, IReadOnlyList<SessionProject> Projects);
public sealed record DesktopSessionPage(IReadOnlyList<DesktopSession> Sessions, bool HasMore);
public sealed record SessionSection(string Title, IReadOnlyList<DesktopSession> Sessions);

public static class DesktopSessionParsing
{
    public static DesktopSessionPage ThreadPage(JsonElement result, string runtime)
    {
        if (result.ValueKind != JsonValueKind.Object || !result.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException("会话目录格式不正确。");
        }
        var rows = new List<DesktopSession>();
        foreach (var item in data.EnumerateArray())
        {
            var id = ReadText(item, "id");
            if (id.Length == 0) { throw new InvalidDataException("会话目录缺少身份。"); }
            if (IsSubagent(item)) { continue; }
            var cwd = ReadText(item, "cwd");
            var project = item.TryGetProperty("mimiRemote", out var annotation) ? ReadText(annotation, "projectName") : "";
            var title = ReadText(item, "name");
            if (title.Length == 0)
            {
                title = ReadText(item, "preview").Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim() ?? "";
            }
            var holder = runtime == "codex" && Boolean(item, "writerHeldElsewhere") == true ? "电脑上的 Codex 已打开" : null;
            if (runtime == "claude" && item.TryGetProperty("claudeOwner", out var owner) && owner.ValueKind == JsonValueKind.Object)
            {
                var entrypoint = ReadText(owner, "entrypoint");
                holder = entrypoint.StartsWith("claude-desktop", StringComparison.Ordinal) ? "Claude 桌面版已打开"
                    : entrypoint == "cli" ? "终端里已打开" : "电脑上另一个 Claude 已打开";
            }
            rows.Add(new DesktopSession(runtime, id, title.Length == 0 ? "未命名会话" : title,
                project.Length == 0 ? DirectoryName(cwd) : project, cwd, Timestamp(item, "updatedAt"),
                Activity(item), holder));
        }
        return new DesktopSessionPage(rows.DistinctBy(row => row.Key).ToArray(), ReadText(result, "nextCursor").Length > 0);
    }

    public static DesktopSessionPage HarnessPage(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object || !value.TryGetProperty("items", out var data) || data.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException("DeepSeek 会话目录格式不正确。");
        }
        var rows = new List<DesktopSession>();
        foreach (var item in data.EnumerateArray())
        {
            var id = ReadText(item, "sessionId");
            if (id.Length == 0) { throw new InvalidDataException("DeepSeek 会话目录缺少身份。"); }
            if (Boolean(item, "blank") == true || ReadText(item, "parentSessionId").Length > 0
                || ReadText(item, "origin") == "subagent") { continue; }
            var cwd = ReadText(item, "cwd");
            var title = item.TryGetProperty("projections", out var projections)
                && projections.TryGetProperty("values", out var values) ? ReadText(values, "title") : "";
            var activity = Boolean(item, "running") switch { true => SessionActivity.Running, false => SessionActivity.Idle, _ => SessionActivity.Unknown };
            rows.Add(new DesktopSession("deepseek", id, title.Length == 0 ? "未命名会话" : title,
                DirectoryName(cwd), cwd, Timestamp(item, "updatedAt", milliseconds: true), activity));
        }
        return new DesktopSessionPage(rows.DistinctBy(row => row.Key).ToArray(), false);
    }

    public static IReadOnlyList<SessionSection> Sections(IEnumerable<DesktopSession> sessions, DateTimeOffset now)
    {
        var today = now.LocalDateTime.Date;
        var names = new[] { "今天", "昨天", "最近 7 天", "更早" };
        var sorted = sessions.OrderByDescending(row => row.UpdatedAt).ThenBy(row => row.Key, StringComparer.Ordinal);
        var grouped = sorted.GroupBy(row =>
        {
            var date = row.UpdatedAt?.LocalDateTime.Date;
            return date >= today ? 0 : date >= today.AddDays(-1) ? 1 : date >= today.AddDays(-6) ? 2 : 3;
        }).ToDictionary(group => group.Key, group => (IReadOnlyList<DesktopSession>)group.ToArray());
        return Enumerable.Range(0, names.Length).Where(grouped.ContainsKey).Select(index => new SessionSection(names[index], grouped[index])).ToArray();
    }

    public static string TimeText(DateTimeOffset? time, DateTimeOffset now)
    {
        if (time is not { } date) { return "时间未知"; }
        var elapsed = now - date;
        if (date.LocalDateTime.Date == now.LocalDateTime.Date && elapsed >= TimeSpan.Zero)
        {
            return elapsed.TotalMinutes < 1 ? "刚刚" : elapsed.TotalHours < 1
                ? $"{(int)elapsed.TotalMinutes} 分钟前" : $"{(int)elapsed.TotalHours} 小时前";
        }
        return date.LocalDateTime.Date == now.LocalDateTime.Date.AddDays(-1)
            ? "昨天 " + date.ToLocalTime().ToString("HH:mm", CultureInfo.InvariantCulture)
            : date.ToLocalTime().ToString("MM-dd HH:mm", CultureInfo.InvariantCulture);
    }

    public static string ReadText(JsonElement element, string property) => element.ValueKind == JsonValueKind.Object
        && element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString()?.Trim() ?? "" : "";

    private static bool? Boolean(JsonElement element, string property) => element.ValueKind == JsonValueKind.Object
        && element.TryGetProperty(property, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False ? value.GetBoolean() : null;

    private static string DirectoryName(string cwd) => cwd.TrimEnd('/', '\\').Split(['/', '\\']).LastOrDefault() ?? "";

    private static bool IsSubagent(JsonElement item)
    {
        if (ReadText(item, "parentThreadId").Length > 0 || ReadText(item, "threadSource").StartsWith("subagent", StringComparison.OrdinalIgnoreCase)) { return true; }
        if (!item.TryGetProperty("source", out var source)) { return false; }
        return source.ValueKind == JsonValueKind.String ? source.GetString()!.StartsWith("subagent", StringComparison.OrdinalIgnoreCase)
            : source.ValueKind == JsonValueKind.Object && source.EnumerateObject().Any(property => property.Name.Equals("subAgent", StringComparison.OrdinalIgnoreCase));
    }

    private static SessionActivity Activity(JsonElement item)
    {
        if (!item.TryGetProperty("status", out var status)) { return SessionActivity.Unknown; }
        var type = status.ValueKind == JsonValueKind.String ? status.GetString() : ReadText(status, "type");
        if (type == "active")
        {
            var flags = status.ValueKind == JsonValueKind.Object && status.TryGetProperty("activeFlags", out var value)
                && value.ValueKind == JsonValueKind.Array ? value.EnumerateArray().Select(flag => flag.GetString()).ToArray() : [];
            return flags.Contains("waitingOnApproval") ? SessionActivity.WaitingForApproval
                : flags.Contains("waitingOnUserInput") ? SessionActivity.WaitingForInput : SessionActivity.Running;
        }
        return type switch { "idle" or "notLoaded" => SessionActivity.Idle, "systemError" => SessionActivity.Failed, _ => SessionActivity.Unknown };
    }

    private static DateTimeOffset? Timestamp(JsonElement item, string name, bool milliseconds = false)
    {
        if (!item.TryGetProperty(name, out var value)) { return null; }
        double number;
        if (value.ValueKind == JsonValueKind.Number) { if (!value.TryGetDouble(out number)) { return null; } }
        else if (value.ValueKind != JsonValueKind.String || !double.TryParse(value.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out number)) { return null; }
        if (!double.IsFinite(number) || number <= 0) { return null; }
        try { return DateTimeOffset.UnixEpoch.AddMilliseconds(milliseconds || number > 10_000_000_000 ? number : number * 1000); }
        catch (ArgumentOutOfRangeException) { return null; }
    }
}
