param(
    [switch]$SkipTask
)

$ErrorActionPreference = "Stop"
$HERE = $PSScriptRoot
if (-not $HERE) { $HERE = (Get-Location).Path }

Write-Host "==== TRAE 自动签到系统 安装向导 ===="
Write-Host "安装目录：$HERE"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "需要 PowerShell 5.1 或更高版本，请先升级 PowerShell"
    exit 1
}
Write-Host "[1/4] PowerShell 版本 $($PSVersionTable.PSVersion) 满足要求"

$py = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $py) {
    Write-Host "[2/4] 未检测到 Python，请先到 Python 官网下载安装包（安装时勾选 Add python.exe to PATH）"
    exit 1
}
Write-Host "[2/4] Python 已就绪：$($py.Source)"

Write-Host "[3/4] 安装 cryptography 依赖"
& $py.Source -m pip install cryptography
if ($LASTEXITCODE -ne 0) {
    Write-Host "cryptography 安装失败，仍可继续：TRAE 部分可改用 refresh_token 方式（见部署说明.md），但 storage.json 自动解密不可用"
}

Write-Host "[4/4] 生成配置文件"
$cfg = Join-Path $HERE "config.json"
if (Test-Path $cfg) {
    Write-Host "config.json 已存在，跳过复制"
} else {
    Copy-Item -Path (Join-Path $HERE "config.example.json") -Destination $cfg
    Write-Host "已生成 config.json，请用记事本编辑填写凭据（见部署说明.md 第三章）"
}

if (-not $SkipTask) {
    $taskName = "TraeAutoCheckinDaily"
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Write-Host "计划任务 $taskName 已存在，跳过注册"
    } else {
        $pyPath = $py.Source
        $traeAction = New-ScheduledTaskAction -Execute $pyPath -Argument "`"$HERE\trae_checkin.py`"" -WorkingDirectory $HERE
        $psPath = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
        $lobsterArg = "-NoProfile -ExecutionPolicy Bypass -File `"$HERE\lobster_checkin.ps1`""
        $lobsterAction = New-ScheduledTaskAction -Execute $psPath -Argument $lobsterArg -WorkingDirectory $HERE
        $trigger = New-ScheduledTaskTrigger -Daily -At 09:05
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
        Register-ScheduledTask -TaskName $taskName -Action $traeAction, $lobsterAction -Trigger $trigger -Principal $principal -Settings $settings -Description "TRAE 与有道龙虾每日自动签到" -Force | Out-Null
        Write-Host "已注册计划任务 $taskName（每天 09:05 自动签到 TRAE 与有道龙虾）"
        Write-Host "修改时间：开始菜单搜索 任务计划程序 -> 任务计划程序库 -> $taskName"
    }
}

Write-Host
Write-Host "==== 安装完成 ===="
Write-Host "下一步："
Write-Host "1. 编辑 $cfg 填写 TRAE 凭据与龙虾客户端路径"
Write-Host "2. 手动试跑：python `"$HERE\trae_checkin.py`""
Write-Host "3. 手动试跑：powershell -ExecutionPolicy Bypass -File `"$HERE\lobster_checkin.ps1`""
Write-Host "4. 确认输出正常后，计划任务每天会自动执行"
