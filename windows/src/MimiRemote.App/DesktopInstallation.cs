using System.Runtime.InteropServices;
using Microsoft.Win32;
using MimiRemote.Core;

namespace MimiRemote.App;

internal sealed class DesktopInstallation(string directory, string executable)
{
    internal const string TrayMutexName = @"Local\MimiRemoteTray-7D413E71-19C5-4F02-8AFC-437E1B8019FD";
    internal const string LegacyTrayName = "mimi-remote-tray.exe";
    private const string DesktopKey = @"Software\Mimi Remote";
    private const string StartupDisabledValue = "DesktopStartupDisabled";
    private static string StartupLink => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "Mimi Remote.lnk");

    internal string DirectoryPath => directory;
    internal bool LegacyTrayExists => File.Exists(Path.Combine(directory, LegacyTrayName));
    internal static bool LoginEnabled => File.Exists(StartupLink);

    internal static DesktopInstallation? Find()
    {
        var directory = AgentClient.FindInstallDirectory();
        if (directory is null || Environment.ProcessPath is not { } executable) { return null; }
        return string.Equals(executable, Path.Combine(directory, "app", "MimiRemote.exe"), StringComparison.OrdinalIgnoreCase)
            ? new DesktopInstallation(directory, executable) : null;
    }

    internal void SetLoginEnabled(bool enabled)
    {
        if (enabled) { WriteStartupLink(); }
        else { File.Delete(StartupLink); }
        using var key = Registry.CurrentUser.CreateSubKey(DesktopKey);
        if (enabled) { key.DeleteValue(StartupDisabledValue, throwOnMissingValue: false); }
        else { key.SetValue(StartupDisabledValue, 1, RegistryValueKind.DWord); }
    }

    private void WriteStartupLink()
    {
        var shellType = Type.GetTypeFromProgID("WScript.Shell", throwOnError: true)!;
        dynamic shell = Activator.CreateInstance(shellType)!;
        try
        {
            dynamic shortcut = shell.CreateShortcut(StartupLink);
            try
            {
                shortcut.TargetPath = executable;
                shortcut.Arguments = "--background";
                shortcut.WorkingDirectory = Path.GetDirectoryName(executable);
                shortcut.IconLocation = Path.Combine(directory, "mimi-remote.ico") + ",0";
                shortcut.Save();
            }
            finally { Marshal.FinalReleaseComObject(shortcut); }
        }
        finally { Marshal.FinalReleaseComObject(shell); }
    }
}
