using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MimiRemote.Core;

namespace MimiRemote.App;

public sealed partial class SessionsPage : UserControl, IDisposable
{
    private readonly bool preview;
    private readonly ObservableCollection<SessionListItem> items = [];
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(15) };
    private readonly CancellationTokenSource lifetime = new();
    private SessionsStore? store;
    private LocalSessionSource? source;
    private int port;
    private bool active;
    private bool disposed;
    private bool updatingProjects;
    private string runtime = "all";

    public SessionsPage() : this(false) { }

    internal SessionsPage(bool preview)
    {
        this.preview = preview;
        InitializeComponent();
        SessionList.ItemsSource = items;
        RuntimeFilter.SelectedItem = RuntimeFilter.Items[0];
        ProjectFilter.Items.Add(new SessionProject("所有项目", ""));
        ProjectFilter.SelectedIndex = 0;
        timer.Tick += async (_, _) =>
        {
            if (active && store is not null) { await store.RefreshAsync(token: lifetime.Token); }
        };
        if (preview) { Attach(new PreviewSessionSource()); }
    }

    public void SetActive(bool value)
    {
        if (disposed) { return; }
        var resumed = value && !active;
        active = value;
        if (active)
        {
            timer.Start();
            if (resumed && store is not null) { _ = store.RefreshAsync(token: lifetime.Token); }
        }
        else { timer.Stop(); store?.Suspend(); }
    }

    public async Task RefreshAsync(HostStatus? host)
    {
        if (disposed || !active) { return; }
        if (!preview)
        {
            if (host?.ServiceOk != true)
            {
                store?.Suspend();
                DirectoryNotice.Title = "电脑服务尚未就绪";
                DirectoryNotice.Message = "请在概览中启动服务后刷新。已有记录的状态可能过期。";
                DirectoryNotice.IsOpen = true;
                EmptyMessage.Text = items.Count == 0 ? "启动电脑服务后，会话会显示在这里。" : "";
                return;
            }
            var configuredPort = LocalSessionSource.Port(host.Endpoint);
            if (source is null || port != configuredPort)
            {
                store?.Dispose();
                source?.Dispose();
                port = configuredPort;
                source = new LocalSessionSource(port);
                Attach(source);
            }
        }
        if (store is not null) { await store.RefreshAsync(token: lifetime.Token); }
    }

    public void Dispose()
    {
        if (disposed) { return; }
        disposed = true;
        timer.Stop();
        lifetime.Cancel();
        store?.Dispose();
        source?.Dispose();
        lifetime.Dispose();
    }

    private void Attach(IDesktopSessionSource directory)
    {
        store = new SessionsStore(directory);
        store.Changed += (sender, _) => DispatcherQueue.TryEnqueue(() =>
        {
            if (!disposed && ReferenceEquals(sender, store)) { ApplyState(); }
        });
        items.Clear();
    }

    private void ApplyState()
    {
        if (store is null) { return; }
        LoadingBar.Visibility = store.Loading ? Visibility.Visible : Visibility.Collapsed;
        More.IsEnabled = !store.Loading;
        More.Visibility = store.HasMore ? Visibility.Visible : Visibility.Collapsed;
        DirectoryNotice.IsOpen = store.Notices.Count > 0;
        DirectoryNotice.Title = "会话目录需要处理";
        DirectoryNotice.Message = string.Join("\n", store.Notices);
        var chosen = ProjectFilter.SelectedItem as SessionProject;
        var selected = chosen?.Cwd ?? "";
        var projects = new[] { new SessionProject("所有项目", "") }
            .Concat(store.Catalog?.Projects ?? [])
            .Concat(store.Sessions.Where(row => row.Cwd.Length > 0).Select(row => new SessionProject(row.ProjectName, row.Cwd)))
            .Concat(chosen is { Cwd.Length: > 0 } ? [chosen] : [])
            .DistinctBy(project => project.Cwd).ToArray();
        if (!ProjectFilter.Items.OfType<SessionProject>().SequenceEqual(projects))
        {
            updatingProjects = true;
            ProjectFilter.Items.Clear();
            foreach (var project in projects) { ProjectFilter.Items.Add(project); }
            ProjectFilter.SelectedItem = projects.FirstOrDefault(project => project.Cwd == selected) ?? projects[0];
            updatingProjects = false;
        }
        var rows = store.Sessions.Where(row => (runtime == "all" || row.Runtime == runtime) && row.Matches(Search.Text));
        var now = DateTimeOffset.Now;
        var target = DesktopSessionParsing.Sections(rows, now).SelectMany(section =>
            new[] { SessionListItem.Header(section.Title) }.Concat(section.Sessions.Select(row => SessionListItem.Row(row, now)))).ToArray();
        // Reconcile by stable identity instead of clearing ItemsSource; preserve realized rows and scroll position.
        for (var index = 0; index < target.Length; index++)
        {
            if (index < items.Count && items[index].Key == target[index].Key)
            {
                if (items[index] != target[index]) { items[index] = target[index]; }
                continue;
            }
            var existing = -1;
            for (var candidate = index + 1; candidate < items.Count; candidate++)
            {
                if (items[candidate].Key == target[index].Key) { existing = candidate; break; }
            }
            if (existing >= 0) { items.Move(existing, index); items[index] = target[index]; }
            else { items.Insert(index, target[index]); }
        }
        while (items.Count > target.Length) { items.RemoveAt(items.Count - 1); }
        var count = target.Count(item => item.Session is not null);
        EmptyMessage.Text = count > 0 ? "" : store.Loading ? "正在读取会话…"
            : store.Notices.Count > 0 ? "暂时读不到会话，请查看上方说明并刷新。"
            : !store.Loaded ? "正在连接电脑服务…"
            : store.Catalog?.Runtimes.Count == 0 ? "尚未启用 AI 助手，请在“AI 助手”中设置。"
            : Search.Text.Length > 0 || runtime != "all" ? "没有匹配的已加载会话。换个关键词或渠道试试。"
            : "还没有会话。在手机或电脑上开始对话后，会显示在这里。";
        Summary.Text = $"{count} 条已加载会话" + (store.HasMore ? " · 还有更早记录" : "")
            + (Search.Text.Length > 0 ? " · 搜索仅限已加载记录" : "")
            + (store.LastUpdated is { } updated ? $" · 更新于 {updated:HH:mm:ss}" : "");
    }

    private void SearchChanged(object sender, TextChangedEventArgs args) { if (store is not null) { ApplyState(); } }

    private void RuntimeChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        runtime = RuntimeFilter.SelectedItem?.Tag as string ?? "all";
        if (store is not null) { ApplyState(); }
    }

    private async void ProjectChanged(object sender, SelectionChangedEventArgs args)
    {
        if (updatingProjects || !active || store is null) { return; }
        var cwd = (ProjectFilter.SelectedItem as SessionProject)?.Cwd;
        await store.SetScopeAsync(string.IsNullOrEmpty(cwd) ? null : cwd, lifetime.Token);
    }

    private async void LoadMoreClicked(object sender, RoutedEventArgs args)
    {
        if (store is not null) { await store.RefreshAsync(more: true, token: lifetime.Token); }
    }

    private void FiltersResized(object sender, SizeChangedEventArgs args)
    {
        var narrow = args.NewSize.Width < 540;
        Grid.SetRow(ProjectFilter, narrow ? 1 : 0);
        Grid.SetColumn(ProjectFilter, narrow ? 0 : 1);
        Grid.SetColumnSpan(ProjectFilter, narrow ? 2 : 1);
        Grid.SetColumnSpan(RuntimeFilter, narrow ? 2 : 1);
    }
}

public sealed record SessionListItem(string Key, string Heading, DesktopSession? Session, string Subtitle)
{
    public override string ToString() => Session is null ? Heading : $"{Title}，{Subtitle}，{Status}" + (Holder.Length > 0 ? $"，{Holder}" : "");
    public string Title => Session?.Title ?? "";
    public string Holder => Session?.Holder ?? "";
    public string Status => Session?.Status ?? "";
    public Visibility HeaderVisibility => Session is null ? Visibility.Visible : Visibility.Collapsed;
    public Visibility RowVisibility => Session is null ? Visibility.Collapsed : Visibility.Visible;
    public Visibility HolderVisibility => Holder.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public string RuntimeGlyph => Session?.Runtime switch { "codex" => "\uE943", "claude" => "\uE734", _ => "\uE774" };
    public string StatusGlyph => Session?.Activity switch
    {
        SessionActivity.Running => "\uE916",
        SessionActivity.WaitingForApproval or SessionActivity.WaitingForInput => "\uE7BA",
        SessionActivity.Failed => "\uEA39",
        SessionActivity.Idle => "\uEA3A",
        _ => "\uE9CE",
    };
    public static SessionListItem Header(string title) => new("header:" + title, title, null, "");
    public static SessionListItem Row(DesktopSession row, DateTimeOffset now) =>
        new(row.Key, "", row, $"{row.RuntimeTitle} · {row.ProjectName} · {DesktopSessionParsing.TimeText(row.UpdatedAt, now)}");
}

internal sealed class PreviewSessionSource : IDesktopSessionSource
{
    public Task<SessionCatalog> CatalogAsync(CancellationToken token) => Task.FromResult(new SessionCatalog(
        ["codex", "claude", "deepseek"], [new("mimi-remote", @"C:\Preview\mimi-remote"), new("desktop-client", @"C:\Preview\desktop-client")]));
    public Task<DesktopSessionPage> ListAsync(string runtime, string? cwd, int pageBudget, CancellationToken token)
    {
        var now = DateTimeOffset.Now;
        var title = runtime switch { "codex" => "优化工作区会话加载", "claude" => "检查 Windows 安装流程", _ => "整理接口错误提示" };
        var project = runtime == "claude" ? "desktop-client" : "mimi-remote";
        var directory = @"C:\Preview\" + project;
        var entries = new[]
        {
            new DesktopSession(runtime, "preview-1", title, project, directory, now.AddMinutes(runtime == "codex" ? -2 : -8),
                runtime == "codex" ? SessionActivity.Running : runtime == "claude" ? SessionActivity.WaitingForApproval : SessionActivity.Idle),
            new DesktopSession(runtime, "preview-2", "补充服务诊断说明", project, directory, now.AddDays(-1),
                runtime == "claude" ? SessionActivity.Failed : SessionActivity.Idle),
        };
        return Task.FromResult(new DesktopSessionPage(entries.Where(row => cwd is null || row.Cwd == cwd).ToArray(), false));
    }
}
