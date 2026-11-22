#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$configDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GeekScreen'
$configPath = Join-Path $configDir 'config.json'

function Test-WritableFolder([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:\\' -or -not [IO.Directory]::Exists($Path)) {
        return $false
    }

    try {
        $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Path))
        if ($drive.DriveType -eq [IO.DriveType]::Network) { return $false }

        $probe = Join-Path $Path ('.geekscreen-' + [guid]::NewGuid().ToString('N'))
        $stream = [IO.FileStream]::new($probe, 'CreateNew', 'Write', 'None', 4096, 'DeleteOnClose')
        try { $stream.WriteByte(0) }
        finally { $stream.Dispose() }
        return $true
    }
    catch { return $false }
}

function Select-ScreenshotFolder {
    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = 'Choose a writable local folder for GeekScreen screenshots.'
    $dialog.ShowNewFolderButton = $true
    try {
        while ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
            $selected = $dialog.SelectedPath
            if (Test-WritableFolder $selected) {
                $temp = Join-Path $configDir ([guid]::NewGuid().ToString('N') + '.tmp')
                try {
                    @{ folder = $selected } | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding UTF8
                    if ([IO.File]::Exists($configPath)) {
                        [IO.File]::Replace($temp, $configPath, $null)
                    }
                    else { [IO.File]::Move($temp, $configPath) }
                }
                finally { [IO.File]::Delete($temp) }
                return $selected
            }
            [void][Windows.Forms.MessageBox]::Show('Choose a local folder you can write to.', 'GeekScreen')
        }
    }
    finally { $dialog.Dispose() }
}

function Save-Screenshot([string]$Folder) {
    $bounds = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = [Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try { $graphics.CopyFromScreen($bounds.Location, [Drawing.Point]::Empty, $bounds.Size) }
        finally { $graphics.Dispose() }

        $name = '{0}_{1}' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString('N')
        $temp = Join-Path $Folder "$name.tmp"
        $target = Join-Path $Folder "$name.png"
        try {
            $bitmap.Save($temp, [Drawing.Imaging.ImageFormat]::Png)
            [IO.File]::Move($temp, $target)
        }
        finally {
            if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        }
        return $target
    }
    finally { $bitmap.Dispose() }
}

$mutex = $null
$ownsMutex = $false
try {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex = [Threading.Mutex]::new($false, "Global\GeekScreen-$sid")
    try { $ownsMutex = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) {
        throw 'GeekScreen is already running for this Windows user.'
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type @'
using System.Runtime.InteropServices;

public static class GeekScreenNative
{
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int key);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
'@
    [void][GeekScreenNative]::SetProcessDPIAware()
    [void][IO.Directory]::CreateDirectory($configDir)

    $folder = $null
    if ([IO.File]::Exists($configPath)) {
        $rawConfig = Get-Content -LiteralPath $configPath -Raw
        try { $folder = ($rawConfig | ConvertFrom-Json).folder }
        catch { Write-Warning 'config.json is invalid. Choose the screenshot folder again.' }
    }
    if ($folder -isnot [string] -or -not (Test-WritableFolder $folder)) {
        $folder = Select-ScreenshotFolder
    }
    if (-not $folder) { exit 0 }

    Write-Host "GeekScreen | F12: screenshot | Ctrl+C: stop"
    Write-Host "Folder: $folder"
    $wasPressed = $true
    while ($true) {
        $pressed = ([GeekScreenNative]::GetAsyncKeyState(0x7B) -band 0x8000) -ne 0
        if ($pressed -and -not $wasPressed) {
            try {
                $saved = Save-Screenshot $folder
                Write-Host "Saved: $saved"
            }
            catch {
                Write-Warning "Screenshot failed: $($_.Exception.Message)"
                if (-not (Test-WritableFolder $folder)) {
                    $replacement = Select-ScreenshotFolder
                    if ($replacement) {
                        $folder = $replacement
                        Write-Host "Folder: $folder. Press F12 for a new screenshot."
                    }
                }
            }
        }
        $wasPressed = $pressed
        Start-Sleep -Milliseconds 15
    }
}
catch {
    Write-Host "GeekScreen: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
