param(
    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Stop"
$script:LogPath = ""

function Write-Log {
    param([string]$Msg)
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$stamp] $Msg"
    if ($script:LogPath) {
        try { Add-Content -Path $script:LogPath -Value $line -Encoding UTF8 } catch { }
    }
    Write-Host $line
}

function Read-Config {
    param([string]$Path)
    if (-not $Path) {
        $Path = Join-Path $PSScriptRoot "config.json"
    }
    if (-not (Test-Path $Path)) {
        Write-Log "未找到 config.json，请先复制 config.example.json 为 config.json 并填写"
        exit 1
    }
    try {
        return Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log "读取 config.json 失败：$($_.Exception.Message)"
        exit 1
    }
}

function Get-Screenshot {
    param([string]$SavePath)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bmp.Save($SavePath, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bmp.Dispose()
}

function Click-Point {
    param([int]$X, [int]$Y)
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class NativeClick {
    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint cButtons, UIntPtr dwExtraInfo);
}
"@
    [NativeClick]::mouse_event(0x0002, [uint32]$X, [uint32]$Y, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [NativeClick]::mouse_event(0x0004, [uint32]$X, [uint32]$Y, 0, [UIntPtr]::Zero)
}

function Find-UiaButton {
    param([System.Windows.Automation.AutomationElement]$RootEl)
    $stack = New-Object System.Collections.Stack
    $stack.Push($RootEl)
    while ($stack.Count -gt 0) {
        $el = $stack.Pop()
        if ($null -eq $el) { continue }
        try {
            $name = $el.Current.Name
            if ($name -like "*每日积分礼*") {
                return $el
            }
            $children = $el.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
            foreach ($c in $children) {
                $stack.Push($c)
            }
        } catch { }
    }
    return $null
}

function Invoke-UiaElement {
    param([System.Windows.Automation.AutomationElement]$El)
    try {
        $pattern = $El.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $pattern.Invoke()
        return $true
    } catch {
        try {
            $pattern = $El.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern)
            $pattern.DoDefaultAction()
            return $true
        } catch {
            return $false
        }
    }
}

function Test-OcrEngine {
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
        $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
        $null = [Windows.Storage.StorageFile, Windows.Foundation, ContentType = WindowsRuntime]
        $null = [Windows.Storage.Streams.RandomAccessStream, Windows.Foundation, ContentType = WindowsRuntime]
        return $true
    } catch {
        return $false
    }
}

function Await-Task {
    param($WinRtTask, [Type]$ResultType)
    $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq "AsTask" -and $_.IsGenericMethod
    })[0].MakeGenericMethod($ResultType)
    $netTask = $asTask.Invoke($null, @($WinRtTask))
    $netTask.Wait() | Out-Null
    return $netTask.Result
}

function Find-OcrButton {
    param([string]$ShotPath)
    $shotAbs = [System.IO.Path]::GetFullPath($ShotPath)
    $file = Await-Task ([Windows.Storage.StorageFile]::GetFileFromPathAsync($shotAbs)) ([Windows.Storage.StorageFile])
    $stream = Await-Task ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await-Task ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bitmap = Await-Task ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $lang = New-Object Windows.Globalization.Language "zh-CN"
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
    if ($null -eq $engine) {
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    }
    if ($null -eq $engine) { return $null }
    $result = Await-Task ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
    foreach ($line in $result.Lines) {
        foreach ($word in $line.Words) {
            if ($word.Text -like "*每日积分礼*") {
                $rect = $word.BoundingRect
                $x = [int]($rect.X + $rect.Width / 2)
                $y = [int]($rect.Y + $rect.Height / 2)
                return @($x, $y)
            }
        }
    }
    return $null
}

function Invoke-LobsterCheckin {
    param($Lobster)
    $appPath = $Lobster.app_path
    $title = $Lobster.window_title
    if (-not $title) { $title = "LobsterAI" }
    $shotDir = $Lobster.screenshot_dir
    if (-not $shotDir) { $shotDir = Join-Path $PSScriptRoot "screenshots" }
    if (-not (Test-Path $shotDir)) { New-Item -ItemType Directory -Path $shotDir -Force | Out-Null }

    $started = $false
    $proc = Get-Process -Name $title -ErrorAction SilentlyContinue
    if ($null -eq $proc) {
        if (-not $appPath) {
            Write-Log "龙虾客户端未在运行且 config.json 未填写 app_path，无法自动启动"
            return 2
        }
        Write-Log "以无障碍模式启动龙虾客户端：$appPath --force-renderer-accessibility"
        Start-Process -FilePath $appPath -ArgumentList "--force-renderer-accessibility"
        $started = $true
        Start-Sleep -Seconds 12
    }

    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $win = $null
    $winCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $title)
    $win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $winCond)
    if ($null -eq $win) {
        $winCondAny = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, "*Lobster*")
        $win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $winCondAny)
    }
    if ($null -eq $win) {
        Write-Log "未找到龙虾客户端窗口（标题：$title），请确认客户端已打开"
        return 2
    }
    Write-Log "找到客户端窗口：$($win.Current.Name)"

    $btn = Find-UiaButton -RootEl $win
    if ($null -ne $btn) {
        Write-Log "找到每日积分礼按钮，开始点击"
        $ok = Invoke-UiaElement -El $btn
        if ($ok) {
            Start-Sleep -Seconds 3
            $shot = Join-Path $shotDir ("checkin_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".png")
            Get-Screenshot -SavePath $shot
            Write-Log "点击成功，截图已保存：$shot"
            return 0
        }
        Write-Log "按钮存在但点击失败，尝试 OCR 兜底"
    } else {
        Write-Log "未在界面中找到每日积分礼按钮，判定今日已签到"
        return 0
    }

    if (Test-OcrEngine) {
        $shot = Join-Path $shotDir ("ocr_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".png")
        Get-Screenshot -SavePath $shot
        try {
            $pos = Find-OcrButton -ShotPath $shot
            if ($null -ne $pos) {
                Write-Log "OCR 识别到每日积分礼，点击坐标 ($($pos[0]), $($pos[1]))"
                Click-Point -X $pos[0] -Y $pos[1]
                Start-Sleep -Seconds 3
                $shot2 = Join-Path $shotDir ("checkin_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".png")
                Get-Screenshot -SavePath $shot2
                Write-Log "OCR 点击完成，截图已保存：$shot2"
                return 0
            }
        } catch {
            Write-Log "OCR 兜底执行失败：$($_.Exception.Message)"
        }
    } else {
        Write-Log "系统 OCR 不可用（需要 Win10/11 且启用中文识别），无法兜底"
    }
    Write-Log "UIA 与 OCR 均未完成点击，请手动点击每日积分礼"
    return 2
}

function Main {
    $cfg = Read-Config -Path $ConfigPath
    $common = $cfg.common
    if ($common.log_dir) {
        $script:LogPath = Join-Path $common.log_dir "lobster_checkin.log"
    } else {
        $logDir = Join-Path $PSScriptRoot "logs"
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $script:LogPath = Join-Path $logDir "lobster_checkin.log"
    }
    Write-Log "开始执行有道龙虾签到"
    $code = Invoke-LobsterCheckin -Lobster $cfg.lobster
    if ($code -eq 0) {
        Write-Log "任务结束：签到完成"
    } else {
        Write-Log "任务结束：签到未完成（代码 $code）"
    }
    exit $code
}

Main
