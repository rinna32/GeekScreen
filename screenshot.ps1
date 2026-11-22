#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$configDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'GeekScreen'
$configPath = Join-Path $configDir 'config.json'
$captureExe = Join-Path $PSScriptRoot 'capture.exe'

function Test-WritableFolder([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:\\' -or -not [IO.Directory]::Exists($Path)) {
        return $false
    }

    try {
        $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Path))
        if ($drive.DriveType -eq [IO.DriveType]::Network) { return $false }
        return [GeekScreenNative]::CanWriteDirectory($Path)
    }
    catch { return $false }
}

function Remove-StaleProbeFiles([string]$Folder) {
    try {
        foreach ($file in [IO.Directory]::EnumerateFiles($Folder, '.geekscreen-*')) {
            if ([IO.Path]::GetFileName($file) -match '^\.geekscreen-[0-9a-fA-F]{32}$') {
                try { [IO.File]::Delete($file) } catch { }
            }
        }
    }
    catch { }
}

function Confirm-Folder([string]$Path) {
    $answer = [Windows.Forms.MessageBox]::Show(
        "Сохранять скриншоты в эту папку?`n`n$Path`n`n«Да» — подтвердить, «Нет» — выбрать другую.",
        'GeekScreen',
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Question)
    return $answer -eq [Windows.Forms.DialogResult]::Yes
}

function Read-ScreenshotFolder {
    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = 'Выберите папку для скриншотов GeekScreen.'
    $dialog.ShowNewFolderButton = $true
    try {
        while ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
            $selected = $dialog.SelectedPath
            if (-not (Test-WritableFolder $selected)) {
                [void][Windows.Forms.MessageBox]::Show(
                    'Выберите локальную папку, в которую можно записывать файлы.',
                    'GeekScreen',
                    [Windows.Forms.MessageBoxButtons]::OK,
                    [Windows.Forms.MessageBoxIcon]::Warning)
                continue
            }
            if (-not (Confirm-Folder $selected)) { continue }

            $temp = Join-Path $configDir ([guid]::NewGuid().ToString('N') + '.tmp')
            try {
                @{ folder = $selected } | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding UTF8
                if ([IO.File]::Exists($configPath)) {
                    try {
                        [IO.File]::Replace($temp, $configPath, [System.Management.Automation.Language.NullString]::Value)
                    }
                    catch {
                        [IO.File]::Delete($configPath)
                        [IO.File]::Move($temp, $configPath)
                    }
                }
                else { [IO.File]::Move($temp, $configPath) }
            }
            finally { [IO.File]::Delete($temp) }
            Remove-StaleProbeFiles $selected
            return $selected
        }
    }
    finally { $dialog.Dispose() }
}

function Save-Screenshot([string]$Folder) {
    $window = [GeekScreenNative]::GetForegroundWindow()
    $screen = [Windows.Forms.Screen]::PrimaryScreen
    if ($window -ne [IntPtr]::Zero) {
        $screen = [Windows.Forms.Screen]::FromHandle($window)
    }

    $name = '{0}_{1}' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString('N')
    $temp = Join-Path $Folder "$name.tmp"
    $target = Join-Path $Folder "$name.png"
    try {
        $captured = $false
        if ([IO.File]::Exists($captureExe)) {
            & $captureExe $screen.DeviceName $temp | Write-Host
            $captured = $LASTEXITCODE -eq 0 -and [IO.File]::Exists($temp)
        }

        if (-not $captured) {
            [IO.File]::Delete($temp)
            $bounds = $screen.Bounds
            $bitmap = [Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
            try {
                $graphics = [Drawing.Graphics]::FromImage($bitmap)
                try { $graphics.CopyFromScreen($bounds.Location, [Drawing.Point]::Empty, $bounds.Size) }
                finally { $graphics.Dispose() }
                $bitmap.Save($temp, [Drawing.Imaging.ImageFormat]::Png)
            }
            finally { $bitmap.Dispose() }
        }

        [IO.File]::Move($temp, $target)
        return $target
    }
    finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function Show-Menu([string]$Folder) {
    while ($true) {
        Write-Host ''
        Write-Host '=========================================='
        Write-Host ' GeekScreen - скриншоты в играх по F11'
        Write-Host '=========================================='
        if ($Folder) { Write-Host " Папка: $Folder" }
        else { Write-Host ' Папка для скриншотов не выбрана.' }
        Write-Host ''

        if ($Folder) {
            Write-Host ' 1 - Запустить GeekScreen'
            Write-Host ' 2 - Изменить папку'
            Write-Host ' 3 - Выход'
        }
        else {
            Write-Host ' 1 - Выбрать папку для сохранения'
            Write-Host ' 2 - Выход'
        }
        Write-Host ''

        $choice = (Read-Host ' Выберите пункт').Trim()
        if (-not $choice) { $choice = '1' }

        if ($Folder) {
            switch ($choice) {
                '1' { return $Folder }
                '2' {
                    $selected = Read-ScreenshotFolder
                    if ($selected) { $Folder = $selected }
                }
                '3' { return $null }
                default { Write-Host ' Введите 1, 2 или 3.' -ForegroundColor Yellow }
            }
        }
        else {
            switch ($choice) {
                '1' {
                    $selected = Read-ScreenshotFolder
                    if ($selected) { $Folder = $selected }
                }
                '2' { return $null }
                default { Write-Host ' Введите 1 или 2.' -ForegroundColor Yellow }
            }
        }
    }
}

function Start-GeekScreen([string]$Folder) {
    if (-not [IO.File]::Exists($captureExe)) {
        Write-Warning 'capture.exe не найден. Захват полноэкранных игр может не работать.'
    }

    $mutex = $null
    $ownsMutex = $false
    try {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $mutex = [Threading.Mutex]::new($false, "Global\GeekScreen-$sid")
        try { $ownsMutex = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) {
            throw 'GeekScreen уже запущен. Закройте его предыдущее окно.'
        }

        Write-Host ''
        Write-Host "Готово. F11 - скриншот, Ctrl+C - остановить."
        Write-Host "Папка: $Folder"

        $wasPressed = $true
        while ($true) {
            $pressed = ([GeekScreenNative]::GetAsyncKeyState(0x7A) -band 0x8000) -ne 0
            if ($pressed -and -not $wasPressed) {
                try {
                    $saved = Save-Screenshot $Folder
                    Write-Host "Сохранено: $saved"
                }
                catch {
                    Write-Warning "Не удалось сделать скриншот: $($_.Exception.Message)"
                    if (-not (Test-WritableFolder $Folder)) {
                        $selected = Read-ScreenshotFolder
                        if ($selected) {
                            $Folder = $selected
                            Write-Host "Папка: $Folder. Нажмите F11 для нового скриншота."
                        }
                    }
                }
            }
            $wasPressed = $pressed
            Start-Sleep -Milliseconds 15
        }
    }
    finally {
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}

try {
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

    [DllImport("user32.dll")]
    public static extern System.IntPtr GetForegroundWindow();

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern System.IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess,
        uint dwShareMode, System.IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, System.IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(System.IntPtr hObject);

    public static bool CanWriteDirectory(string path)
    {
        const uint FILE_ADD_FILE = 0x0002;
        const uint FILE_SHARE_READ = 0x00000001;
        const uint FILE_SHARE_WRITE = 0x00000002;
        const uint FILE_SHARE_DELETE = 0x00000004;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;

        System.IntPtr handle = CreateFileW(path, FILE_ADD_FILE,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            System.IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, System.IntPtr.Zero);
        if (handle.ToInt64() == -1) { return false; }
        CloseHandle(handle);
        return true;
    }
}
'@
    [void][GeekScreenNative]::SetProcessDPIAware()
    [void][IO.Directory]::CreateDirectory($configDir)

    $folder = $null
    if ([IO.File]::Exists($configPath)) {
        try {
            $rawConfig = Get-Content -LiteralPath $configPath -Raw
            $folder = ($rawConfig | ConvertFrom-Json).folder
        }
        catch {
            Write-Warning 'Файл настроек повреждён. Выберите папку заново.'
        }
    }
    if ($folder -isnot [string] -or -not (Test-WritableFolder $folder)) { $folder = $null }
    if ($folder) { Remove-StaleProbeFiles $folder }

    while ($true) {
        $folder = Show-Menu $folder
        if (-not $folder) { exit 0 }
        Start-GeekScreen $folder
    }
}
catch {
    Write-Host "GeekScreen: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
