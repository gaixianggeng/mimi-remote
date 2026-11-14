using System.Text.Json;
using MimiRemote.Core;
using Xunit;

namespace MimiRemote.Core.Tests;

public sealed class DesktopSessionsTests
{
    [Fact]
    public void 列表按结构过滤子任务保留普通分叉并读取时间和持有方()
    {
        using var document = JsonDocument.Parse("""
            {"data":[
              {"id":"same","name":"目录加载","cwd":"C:\\work\\repo","updatedAt":1800000000,"status":{"type":"active","activeFlags":["waitingOnApproval"]},"mimiRemote":{"projectName":"项目标签"},"claudeOwner":{"entrypoint":"claude-desktop-3p"}},
              {"id":"child","parentThreadId":"same"},
              {"id":"source-child","source":{"subAgent":{}}},
              {"id":"fork","source":"fork","preview":"第一行\n第二行","updatedAt":"1800000000000","status":"notLoaded"},
              {"id":"same","name":"重复的旧条目"}],"nextCursor":"next"}
            """);
        var page = DesktopSessionParsing.ThreadPage(document.RootElement, "claude");
        Assert.True(page.HasMore);
        Assert.Equal(2, page.Sessions.Count);
        var first = page.Sessions[0];
        Assert.Equal("项目标签", first.ProjectName);
        Assert.Equal(SessionActivity.WaitingForApproval, first.Activity);
        Assert.Equal("Claude 桌面版已打开", first.Holder);
        Assert.Equal(first.UpdatedAt, page.Sessions[1].UpdatedAt);
        Assert.Equal("第一行", page.Sessions[1].Title);
        Assert.True(first.Matches("目录"));
        Assert.True(first.Matches("项目"));
        Assert.False(first.Matches("不存在"));
    }

    [Theory]
    [InlineData("null")]
    [InlineData("{}")]
    [InlineData("{\"data\":[{}]}")]
    public void 畸形目录不冒充空列表(string json)
    {
        using var document = JsonDocument.Parse(json);
        Assert.Throws<InvalidDataException>(() => DesktopSessionParsing.ThreadPage(document.RootElement, "codex"));
    }

    [Fact]
    public void 缺失状态保持未知而不编造空闲()
    {
        using var document = JsonDocument.Parse("""{"data":[{"id":"a","cwd":"C:\\work\\repo"}]}""");
        var row = Assert.Single(DesktopSessionParsing.ThreadPage(document.RootElement, "codex").Sessions);
        Assert.Equal(SessionActivity.Unknown, row.Activity);
        Assert.Null(row.UpdatedAt);
        Assert.Equal("repo", row.ProjectName);
    }

    [Fact]
    public void 日期分组与相对时间遵守本地日界()
    {
        var now = new DateTimeOffset(DateTime.Today.AddHours(12));
        var rows = new[]
        {
            Row("old", now.AddDays(-12)), Row("today", now.AddMinutes(-2)),
            Row("yesterday", now.AddDays(-1)), Row("week", now.AddDays(-4)),
        };
        Assert.Equal(["今天", "昨天", "最近 7 天", "更早"], DesktopSessionParsing.Sections(rows, now).Select(section => section.Title));
        Assert.Equal("2 分钟前", DesktopSessionParsing.TimeText(now.AddMinutes(-2), now));
        Assert.StartsWith("昨天 ", DesktopSessionParsing.TimeText(now.AddDays(-1), now), StringComparison.Ordinal);
    }

    [Fact]
    public void Harness使用冻结原生夹具而不是appServer字段()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "fixtures", "harness-session-list.json")));
        var result = fixture.RootElement.GetProperty("observations").EnumerateArray()
            .First(item => item.GetProperty("label").GetString() == "result-populated").GetProperty("value");
        var page = DesktopSessionParsing.HarnessPage(result);
        Assert.False(page.HasMore);
        Assert.NotEmpty(page.Sessions);
        Assert.All(page.Sessions, row => Assert.Equal("deepseek", row.Runtime));
        Assert.Contains(page.Sessions, row => row.Title == "H00 回环会话");
        Assert.Equal(page.Sessions.Count, page.Sessions.Select(row => row.Key).Distinct().Count());
    }

    private static DesktopSession Row(string id, DateTimeOffset updated) =>
        new("codex", id, id, "repo", "", updated, SessionActivity.Idle);
}
