using MimiRemote.Core;
using Xunit;

namespace MimiRemote.Core.Tests;

public sealed class SessionsStoreTests
{
    [Fact]
    public async Task 定时只读首屏且不丢旧页也不扩大加载更多预算()
    {
        var source = new Source(["codex"], (runtime, _, budget, _) => Task.FromResult(
            new DesktopSessionPage(budget == 1 ? [Row(runtime, "new")] : [Row(runtime, "new"), Row(runtime, "old")], true)));
        using var store = new SessionsStore(source);
        await store.RefreshAsync();
        await store.RefreshAsync(more: true);
        Assert.Equal(8, source.LastBudget);
        await store.RefreshAsync(firstPage: true);
        Assert.Equal(1, source.LastBudget);
        Assert.Equal(2, store.Sessions.Count);
        await store.RefreshAsync();
        Assert.Equal(8, source.LastBudget);
        await store.RefreshAsync(more: true);
        Assert.Equal(12, source.LastBudget);
    }
    [Fact]
    public async Task 同ID跨渠道保留且单渠道失败不清空原列表()
    {
        var fail = false;
        var source = new Source(["codex", "claude"], (runtime, _, _, _) =>
            fail && runtime == "claude" ? throw new IOException("暂时离线")
                : Task.FromResult(new DesktopSessionPage([Row(runtime, "same")], false)));
        using var store = new SessionsStore(source);
        await store.RefreshAsync();
        Assert.Equal(2, store.Sessions.Count);
        fail = true;
        await store.RefreshAsync();
        Assert.Equal(2, store.Sessions.Count);
        Assert.Equal("暂时离线", store.RuntimeFailures["claude"]);
        Assert.Single(store.RuntimeFailures);
        Assert.NotNull(store.LastUpdated);
    }

    [Fact]
    public async Task 有后续页不能删除未扫描到的记录完整遍历后才替换()
    {
        var round = 0;
        var source = new Source(["codex"], (runtime, _, _, _) => Task.FromResult(round switch
        {
            0 => new DesktopSessionPage([Row(runtime, "new"), Row(runtime, "old")], false),
            1 => new DesktopSessionPage([Row(runtime, "new")], true),
            _ => new DesktopSessionPage([Row(runtime, "new")], false),
        }));
        using var store = new SessionsStore(source);
        await store.RefreshAsync();
        round = 1;
        await store.RefreshAsync();
        Assert.Equal(2, store.Sessions.Count);
        Assert.True(store.HasMore);
        round = 2;
        await store.RefreshAsync(more: true);
        Assert.Single(store.Sessions);
        Assert.Equal(8, source.LastBudget);
        Assert.False(store.HasMore);
    }

    [Fact]
    public async Task 切换项目后旧响应不覆盖新范围且同范围刷新合并()
    {
        var old = new TaskCompletionSource<DesktopSessionPage>(TaskCreationOptions.RunContinuationsAsynchronously);
        var source = new Source(["codex"], (runtime, cwd, _, _) => cwd == "old"
            ? old.Task : Task.FromResult(new DesktopSessionPage([Row(runtime, cwd ?? "global")], false)));
        using var store = new SessionsStore(source);
        var first = store.SetScopeAsync("old");
        var coalesced = store.RefreshAsync();
        Assert.Same(first, coalesced);
        await store.SetScopeAsync("new");
        old.SetResult(new DesktopSessionPage([Row("codex", "old")], false));
        await first;
        Assert.Equal("new", Assert.Single(store.Sessions).ThreadId);
        Assert.Equal("new", store.Cwd);
        Assert.False(store.Loading);
    }

    [Fact]
    public async Task 关闭渠道移除旧行而目录请求失败保留上次数据()
    {
        var source = new Source(["codex", "claude"], (runtime, _, _, _) =>
            Task.FromResult(new DesktopSessionPage([Row(runtime, "same")], false)));
        using var store = new SessionsStore(source);
        await store.RefreshAsync();
        source.Runtimes = ["claude"];
        await store.RefreshAsync();
        Assert.Equal("claude", Assert.Single(store.Sessions).Runtime);
        source.CatalogFailure = true;
        await store.RefreshAsync();
        Assert.Single(store.Sessions);
        Assert.Equal("目录请求失败", store.CatalogFailure);
    }

    [Fact]
    public async Task 挂起取消在途读取且不发布取消前的结果()
    {
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var source = new Source(["codex"], async (_, _, _, token) =>
        {
            started.SetResult();
            await Task.Delay(Timeout.Infinite, token);
            return new DesktopSessionPage([], false);
        });
        using var store = new SessionsStore(source);
        var loading = store.RefreshAsync();
        await started.Task;
        store.Suspend();
        await loading;
        Assert.False(store.Loading);
        Assert.Empty(store.Sessions);
        Assert.Empty(store.RuntimeFailures);
        Assert.Null(store.CatalogFailure);
    }

    [Fact]
    public async Task 首屏刷新保留已覆盖的页且渠道失败不会继承其他渠道的续页()
    {
        var incremental = false;
        var source = new Source(["codex", "claude"], (runtime, _, _, _) =>
        {
            if (incremental && runtime == "claude") { throw new IOException("暂时离线"); }
            return Task.FromResult(new DesktopSessionPage(incremental ? [Row(runtime, "new")] : [Row(runtime, "new"), Row(runtime, "old")], incremental || runtime == "claude"));
        });
        using var store = new SessionsStore(source);
        await store.RefreshAsync();
        Assert.True(store.HasMore);
        Assert.False(store.HasMoreFor("codex"));

        incremental = true;
        await store.RefreshAsync(firstPage: true);
        Assert.False(store.HasMoreFor("codex"));
        Assert.True(store.HasMoreFor("claude"));
        Assert.Single(store.RuntimeFailures);
        Assert.Equal(4, store.Sessions.Count);

        source.Runtimes = ["codex"];
        await store.RefreshAsync(firstPage: true);
        Assert.False(store.HasMore);
        Assert.Empty(store.RuntimeFailures);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task 首屏没有保持排序位置的旧行时可以继续加载填补间隔(bool movedEarlierRow)
    {
        var original = Row("codex", "old");
        var updated = original with { ThreadId = movedEarlierRow ? "old" : "new", UpdatedAt = DateTimeOffset.UnixEpoch.AddMinutes(1) };
        var source = new Source(["codex"], (_, _, budget, _) => Task.FromResult(budget == 1
            ? new DesktopSessionPage([updated], true) : new DesktopSessionPage([original], false)));
        using var store = new SessionsStore(source);
        await store.RefreshAsync();
        Assert.False(store.HasMore);
        await store.RefreshAsync(firstPage: true);
        Assert.True(store.HasMoreFor("codex"));
        Assert.Equal(movedEarlierRow ? 1 : 2, store.Sessions.Count);
    }

    private static DesktopSession Row(string runtime, string id) =>
        new(runtime, id, id, "repo", @"C:\repo", DateTimeOffset.UnixEpoch, SessionActivity.Idle);

    private sealed class Source(string[] runtimes,
        Func<string, string?, int, CancellationToken, Task<DesktopSessionPage>> read) : IDesktopSessionSource
    {
        public string[] Runtimes { get; set; } = runtimes;
        public bool CatalogFailure { get; set; }
        public int LastBudget { get; private set; }
        public Task<SessionCatalog> CatalogAsync(CancellationToken token) => CatalogFailure
            ? throw new IOException("目录请求失败") : Task.FromResult(new SessionCatalog(Runtimes, []));
        public Task<DesktopSessionPage> ListAsync(string runtime, string? cwd, int pageBudget, CancellationToken token)
        {
            LastBudget = pageBudget;
            return read(runtime, cwd, pageBudget, token);
        }
    }
}
