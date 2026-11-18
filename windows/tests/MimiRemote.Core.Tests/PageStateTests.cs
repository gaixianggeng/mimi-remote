using MimiRemote.Core;
using Xunit;

namespace MimiRemote.Core.Tests;

public sealed class PageStateTests
{
    [Fact]
    public async Task 页面忙碌不阻塞其他页面且刷新保留操作提示()
    {
        var first = new PageState();
        var second = new PageState();
        var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var loading = first.RunAsync(() => finish.Task);
        Assert.True(first.IsBusy);
        await second.RunAsync(() => { second.Report("中转配置已保存"); return Task.CompletedTask; });
        await second.RunAsync(() => Task.CompletedTask);
        Assert.True(first.IsBusy);
        Assert.True(second.NoticeOpen);
        Assert.Equal("中转配置已保存", second.Notice);
        finish.SetResult();
        await loading;
        await first.WhenIdle;
        Assert.True(first.IsIdle);
    }

    [Fact]
    public async Task 空闲通知触发后续操作时前一次完成不能释放新的等待者()
    {
        var state = new PageState();
        var first = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var second = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Task? next = null;
        state.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(PageState.IsBusy) && !state.IsBusy && next is null)
            { next = state.RunAsync(() => second.Task); }
        };
        var running = state.RunAsync(() => first.Task);
        first.SetResult();
        await running;
        Assert.True(state.IsBusy);
        Assert.False(state.WhenIdle.IsCompleted);
        second.SetResult();
        await next!;
        Assert.True(state.WhenIdle.IsCompleted);
    }

    [Fact]
    public async Task 操作失败显示错误并释放忙碌状态()
    {
        var state = new PageState();
        await state.RunAsync(() => throw new IOException("连接暂时不可用"));
        Assert.True(state.Failed);
        Assert.True(state.NoticeOpen);
        Assert.True(state.IsIdle);
    }

    [Theory]
    [InlineData("1.2.3", true)]
    [InlineData("0.0.0-preview", false)]
    [InlineData("1.0.0+snapshot", false)]
    [InlineData("1.2.3.4", false)]
    [InlineData("", false)]
    public void 预览构建不能触发正式版更新(string version, bool expected) =>
        Assert.Equal(expected, ClientBuild.Parse(version).CanCheckUpdates);

    [Theory]
    [InlineData(true, true, false)]
    [InlineData(true, false, true)]
    [InlineData(false, true, true)]
    public void 后台启动不在旧托盘旁弹出窗口(bool background, bool legacy, bool expected) =>
        Assert.Equal(expected, ClientStartup.ShouldLaunch(background, legacy));
}
