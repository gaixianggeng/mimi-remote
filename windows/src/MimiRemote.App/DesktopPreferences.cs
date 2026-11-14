using System.Text.Json;
using Microsoft.Win32;

namespace MimiRemote.App;

internal sealed class DesktopPreferences
{
    private static string FilePath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Mimi Remote", "desktop-preferences.json");
    internal static string ConfigPath => Environment.GetEnvironmentVariable("AGENTD_CONFIG") is { Length: > 0 } custom ? custom
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "mimi-remote", "config.json");
    public bool SetupCompleted { get; set; }
    public bool NotificationsEnabled { get; set; } = true;

    internal static DesktopPreferences Load()
    {
        try { return JsonSerializer.Deserialize<DesktopPreferences>(File.ReadAllText(FilePath)) ?? new(); }
        catch (Exception error) when (error is IOException or JsonException) { return new(); }
    }

    internal void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        var temporary = FilePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(this));
            File.Move(temporary, FilePath, overwrite: true);
        }
        finally { if (File.Exists(temporary)) { File.Delete(temporary); } }
    }

    internal static bool LoginEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
            return key?.GetValue("MimiRemoteNative") as string == StartupCommand;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
            if (value) { key.SetValue("MimiRemoteNative", StartupCommand); }
            else { key.DeleteValue("MimiRemoteNative", throwOnMissingValue: false); }
        }
    }

    private static string StartupCommand => $"\"{Environment.ProcessPath}\" --background";
}
