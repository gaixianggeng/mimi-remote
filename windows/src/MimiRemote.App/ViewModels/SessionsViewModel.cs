using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Xaml;
using MimiRemote.Core;

namespace MimiRemote.App.ViewModels;

public sealed class SessionsViewModel : ClientPageViewModel
{
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(15) };
    private SessionsStore? store;
    private LocalSessionSource? source;
    private int port;
    private string query = "";
    private SessionRuntimeFilter? runtime;
    private SessionProject? project;
    private bool updating;
    public ObservableCollection<SessionGroup> Groups { get; } = [];
    public ObservableCollection<SessionRuntimeFilter> Runtimes { get; } = [new("all", "全部渠道")];
    public ObservableCollection<SessionProject> Projects { get; } = [new("所有项目", "")];
    public string Query { get => query; set { if (SetProperty(ref query, value)) { ApplyRows(); } } }
    public SessionRuntimeFilter? Runtime { get => runtime; set { if (SetProperty(ref runtime, value)) { ApplyRows(); } } }
    public SessionProject? Project
    {
        get => project;
        set
        {
            if (SetProperty(ref project, value) && !updating && Active && store is not null)
            { _ = store.SetScopeAsync(string.IsNullOrEmpty(value?.Cwd) ? null : value.Cwd, Lifetime.Token); }
        }
    }
    private string summary = "";
    private string empty = "正在连接电脑服务…";
    private bool hasMore;
    private bool loading;
    public string Summary { get => summary; private set => SetProperty(ref summary, value); }
    public string Empty { get => empty; private set => SetProperty(ref empty, value); }
    public bool HasMore { get => hasMore; private set => SetProperty(ref hasMore, value); }
    public bool Loading { get => loading; private set => SetProperty(ref loading, value); }
    public IAsyncRelayCommand MoreCommand { get; }
    public SessionsViewModel(ClientContext context) : base(context)
    {
        runtime = Runtimes[0];
        project = Projects[0];
        MoreCommand = new AsyncRelayCommand(() => RunAsync(async () =>
        { if (store is not null) { await store.RefreshAsync(more: true, token: Lifetime.Token); } }));
        timer.Tick += async (_, _) =>
        {
            if (Active && store is not null && !store.Loading) { await store.RefreshAsync(token: Lifetime.Token, firstPage: true); }
        };
#if DEBUG
        if (context.Preview) { Attach(new PreviewSessionSource()); }
#endif
    }
    protected override void OnActiveChanged()
    {
        if (Active) { timer.Start(); }
        else { timer.Stop(); store?.Suspend(); }
    }
    protected override async Task RefreshAsync(bool force)
    {
        if (!Active) { return; }
        if (!Context.Preview)
        {
            var host = await Context.ReadStatusAsync(force: force, token: Lifetime.Token);
            if (!Active) { return; }
            if (!host.ServiceOk) { Report("电脑服务尚未就绪，请在概览中启动服务。已有记录可能过期。", true); return; }
            var currentPort = LocalSessionSource.Port(host.Endpoint);
            if (source is null || currentPort != port)
            {
                store?.Dispose();
                source?.Dispose();
                port = currentPort;
                source = new LocalSessionSource(port);
                Attach(source);
            }
        }
        if (store is null || !force && store.LastUpdated is { } time && DateTimeOffset.Now - time < TimeSpan.FromSeconds(15)) { return; }
        await store.RefreshAsync(token: Lifetime.Token, firstPage: !force && store.Loaded);
    }
    private void Attach(IDesktopSessionSource directory)
    {
        store = new SessionsStore(directory);
        store.Changed += (_, _) => ApplyState();
    }
    private void ApplyState()
    {
        if (store is null) { return; }
        Loading = store.Loading;
        HasMore = store.HasMore;
        if (store.Notices.Count > 0) { Report(string.Join("\n", store.Notices), true); }
        var selectedRuntime = Runtime?.Id ?? "all";
        var selectedProject = Project?.Cwd ?? "";
        updating = true;
        var filters = new[] { new SessionRuntimeFilter("all", "全部渠道") }
            .Concat((store.Catalog?.Runtimes ?? []).Select(id => new SessionRuntimeFilter(id, SessionsStore.Title(id)))).ToArray();
        Reconcile(Runtimes, filters, item => item.Id);
        Runtime = Runtimes.FirstOrDefault(item => item.Id == selectedRuntime) ?? Runtimes[0];
        var projects = new[] { new SessionProject("所有项目", "") }.Concat(store.Catalog?.Projects ?? [])
            .Concat(store.Sessions.Where(row => row.Cwd.Length > 0).Select(row => new SessionProject(row.ProjectName, row.Cwd)))
            .Concat(Project is { Cwd.Length: > 0 } chosen ? [chosen] : []).DistinctBy(item => item.Cwd).ToArray();
        Reconcile(Projects, projects, item => item.Cwd);
        Project = Projects.FirstOrDefault(item => item.Cwd == selectedProject) ?? Projects[0];
        updating = false;
        ApplyRows();
    }
    public void ApplyRows()
    {
        if (store is null) { return; }
        var now = DateTimeOffset.Now;
        var rows = store.Sessions.Where(row => (Runtime?.Id is null or "all" || row.Runtime == Runtime.Id) && row.Matches(Query)).ToArray();
        var sections = DesktopSessionParsing.Sections(rows, now).ToArray();
        foreach (var group in Groups.Where(group => !sections.Any(section => section.Title == group.Title)).ToArray()) { Groups.Remove(group); }
        for (var index = 0; index < sections.Length; index++)
        {
            var section = sections[index];
            var group = Groups.FirstOrDefault(item => item.Title == section.Title);
            if (group is null) { group = new SessionGroup(section.Title); Groups.Insert(index, group); }
            else if (Groups.IndexOf(group) != index) { Groups.Move(Groups.IndexOf(group), index); }
            Reconcile(group, section.Sessions.Select(row => new SessionRow(row, now)), row => row.Session.Key);
        }
        Empty = rows.Length > 0 ? "" : store.Loading ? "正在读取会话…"
            : !store.Loaded ? "正在连接电脑服务…" : store.Catalog?.Runtimes.Count == 0 ? "尚未启用 AI 助手，请在“AI 助手”中设置。"
            : Query.Length > 0 || Runtime?.Id != "all" ? "没有匹配的已加载会话。" : "还没有会话。在手机或电脑上开始对话后，会显示在这里。";
        Summary = $"{rows.Length} 条已加载会话" + (store.HasMore ? " · 还有更早记录" : "")
            + (Query.Length > 0 ? " · 搜索仅限已加载记录" : "")
            + (store.LastUpdated is { } updated ? $" · 更新于 {updated:HH:mm:ss}" : "");
    }
    private static void Reconcile<T>(ObservableCollection<T> items, IEnumerable<T> target, Func<T, string> key)
    {
        var values = target.ToArray();
        for (var index = 0; index < values.Length; index++)
        {
            var value = values[index];
            var found = items.Select((item, position) => (item, position)).FirstOrDefault(pair => key(pair.item) == key(value), (default!, -1)).position;
            if (found < 0) { items.Insert(index, value); }
            else { if (found != index) { items.Move(found, index); } if (!Equals(items[index], value)) { items[index] = value; } }
        }
        while (items.Count > values.Length) { items.RemoveAt(items.Count - 1); }
    }
    public override void Dispose() { timer.Stop(); store?.Dispose(); source?.Dispose(); base.Dispose(); }
}
public sealed record SessionRuntimeFilter(string Id, string Title);
public sealed class SessionGroup(string title) : ObservableCollection<SessionRow>
{
    public string Title { get; } = title;
    public override string ToString() => Title;
}
public sealed record SessionRow(DesktopSession Session, DateTimeOffset Now)
{
    public string Title => Session.Title;
    public string Subtitle => $"{Session.RuntimeTitle} · {Session.ProjectName} · {DesktopSessionParsing.TimeText(Session.UpdatedAt, Now)}";
    public string Status => Session.Status;
    public string Holder => Session.Holder ?? "";
    public string AccessibleName => $"{Title}，{Subtitle}，{Status}" + (Holder.Length > 0 ? $"，{Holder}" : "");
    public string RuntimeGlyph => Session.Runtime switch { "codex" => "\uE943", "claude" => "\uE734", _ => "\uE774" };
    public string StatusGlyph => Session.Activity switch
    {
        SessionActivity.Running => "\uE916",
        SessionActivity.WaitingForApproval or SessionActivity.WaitingForInput => "\uE7BA",
        SessionActivity.Failed => "\uEA39",
        SessionActivity.Idle => "\uEA3A",
        _ => "\uE9CE"
    };
    public string StatusKind => Session.Activity switch
    {
        SessionActivity.Running => "Success",
        SessionActivity.WaitingForApproval or SessionActivity.WaitingForInput => "Caution",
        SessionActivity.Failed => "Critical",
        _ => "Neutral"
    };
    public override string ToString() => AccessibleName;
}
