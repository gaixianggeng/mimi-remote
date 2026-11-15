using System.ComponentModel;
using MimiRemote.App;
using MimiRemote.App.ViewModels;
using Xunit;

namespace MimiRemote.Core.Tests;

public sealed class ConnectionViewModelTests
{
    [Fact]
    public async Task 退出时取消正在进行的轮询不会逸出或覆盖提示()
    {
        var context = new ClientContext();
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        context.Agent.ReadTailcat = async token =>
        {
            started.SetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, token);
            return new TailcatStatus();
        };
        var model = new ConnectionViewModel(context);
        await model.SetActiveAsync(true);
        model.Report("中转配置已保存");
        var polling = model.PollAsync();
        await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        model.Dispose();
        await polling.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal("中转配置已保存", model.Notice);
        Assert.False(model.Failed);
    }

    [Fact]
    public async Task 进程启动失败显示提示且下一轮仍可恢复()
    {
        var context = new ClientContext();
        context.Agent.ReadTailcat = _ => throw new Win32Exception("找不到 agentd");
        using var model = new ConnectionViewModel(context);
        await model.SetActiveAsync(true);
        await model.PollAsync();
        Assert.True(model.Failed);
        Assert.Contains("找不到 agentd", model.Notice);
        context.Agent.ReadTailcat = _ => Task.FromResult(new TailcatStatus { Enabled = true, Running = true });
        await model.PollAsync();
        Assert.Equal("内置连接运行中", model.ConnectionState);
        Assert.True(model.IsIdle);
    }

    [Fact]
    public async Task 页面退出后迟到的失败不会写入新提示()
    {
        var context = new ClientContext();
        var response = new TaskCompletionSource<TailcatStatus>(TaskCreationOptions.RunContinuationsAsynchronously);
        context.Agent.ReadTailcat = _ => response.Task;
        var model = new ConnectionViewModel(context);
        await model.SetActiveAsync(true);
        model.Report("原有提示");
        var polling = model.PollAsync();
        model.Dispose();
        response.SetException(new UnauthorizedAccessException("无法读取服务"));
        await polling.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal("原有提示", model.Notice);
        Assert.False(model.Failed);
    }

    [Fact]
    public async Task 轮询进行时不会并发读取也不会设置整页忙碌()
    {
        var context = new ClientContext();
        var response = new TaskCompletionSource<TailcatStatus>(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        context.Agent.ReadTailcat = _ => { calls++; return response.Task; };
        using var model = new ConnectionViewModel(context);
        await model.SetActiveAsync(true);
        var polling = model.PollAsync();
        await model.PollAsync();
        Assert.Equal(1, calls);
        Assert.True(model.IsIdle);
        response.SetResult(new TailcatStatus());
        await polling;
    }
}
