# 一键把仓库里测试好的 cct 源码同步覆盖到本机已安装的 ClaudeCodeTask 模块副本。
#
# 背景：Claude Code 会话运行期间，由 Claude 直接覆盖安装副本会因文件被占用而失败，
# 所以改码测试通过后，先退出 claude，再到仓库根目录手动运行本脚本完成覆盖。
#
# 用法（在仓库根目录 E:\个人\ClaudeCodeTask 下）：
#   pwsh -NoProfile -File .\sync-to-installed.ps1            # 备份旧文件后覆盖
#   pwsh -NoProfile -File .\sync-to-installed.ps1 -ListOnly  # 只预览，不改动
#
# 源   = .\ClaudeCodeTask.UI\（11 个 ps1/psd1/psm1 + lib\ClaudeCodeTask.Core.dll）
# 目标 = $HOME\Documents\PowerShell\Modules\ClaudeCodeTask\<仓库 psd1 版本号>\（可用 -Target 覆盖）
# 备份 = %TEMP%\cct-sync-backup-<yyyyMMdd-HHmmss>\（先备份再覆盖）
#
# 环境与冲突检测（2026-09-07 加固）：
#   1. pwsh 版本：模块要求 PowerShell 7+，5.1 下给中文提示退出
#   2. 备份先行：备份目标含子路径（lib\）自动创建父目录；任一备份失败即中止，不覆盖任何文件
#   3. 逐文件容错覆盖：单个文件被占用（其他终端/杀软）不中断其余文件，最后汇总报错退出，
#      并提示「覆盖不完整、副本可能新旧混杂、修复前勿用」
#   4. 覆盖后子进程烟测：新开独立 pwsh 导入安装副本并跑一遍扫描链路，验证「装上即可用」；
#      失败时给出备份目录位置便于还原
#   5. 热加载冲突检测：.NET 程序集无法在进程内卸载或同名替换。当前终端此前加载过旧内核
#      dll 时，Add-Type 会报 "Assembly with same name is already loaded"，模块表面加载
#      成功、内核类型实际缺失（扫描时报 Unable to find type）。此时跳过热加载、保留旧模块，
#      提示新开终端用新版本
#   6. 多版本目录提示：安装目录下存在其他版本号目录时给信息性说明（PowerShell 只加载最高版本）
#   7. 目标被独占锁定：其他进程 FileShare.None 锁住目标文件时 hash 比对也读不了——容错按
#      「需更新」继续，由备份/覆盖阶段报出贴合场景的错误，不在比对阶段整体崩掉
#   8. 集中元数据盖章：同步前自动把 build-metadata.json（版本号/域名/发版说明的唯一编辑点）
#      盖章进 psd1，失败降级用 psd1 现值继续，不阻塞同步

[CmdletBinding()]
param(
    [string]$Target,     # 目标模块目录；省略时按仓库 ClaudeCodeTask.psd1 的 ModuleVersion 自动定位
    [switch]$ListOnly    # 只打印待同步文件与目标路径，不做备份与覆盖
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$srcDir   = Join-Path $repoRoot 'ClaudeCodeTask.UI'

# 检测 1：pwsh 版本（模块 psd1 声明 PowerShellVersion 7.6；5.1 下导入报晦涩英文错误，这里提前说人话）
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host '需要 PowerShell 7+（pwsh）运行本脚本与 cct 模块；当前是 Windows PowerShell 5.1。' -ForegroundColor Red
    Write-Host '请改用：pwsh -NoProfile -File .\sync-to-installed.ps1'
    exit 1
}

# 模块发布内容（与安装副本逐文件对应）
$topFiles = @(
    'Cct.ps1', 'ClaudeCodeTask.psd1', 'ClaudeCodeTask.psm1', 'Command.ps1',
    'Config.ps1', 'Data.ps1', 'Display.ps1', 'Launcher.ps1', 'Selector.ps1', 'Spinner.ps1', 'Clear.ps1'
)

# 集中元数据盖章（无论是否 -Target 都执行）：build-metadata.json → psd1 版本相关字段。
# 版本号/域名/发版说明只编辑元数据文件，psd1 派生，避免两处漂移（各处提示的版本自动跟随）。
$stampPath = Join-Path $repoRoot 'StampMetadata.ps1'
if (Test-Path -LiteralPath $stampPath) {
    . $stampPath
    try {
        $stamp = Update-CctPsd1FromMetadata -MetadataPath (Join-Path $repoRoot 'build-metadata.json') -Psd1Path (Join-Path $srcDir 'ClaudeCodeTask.psd1')
        if ($stamp.Changed) { Write-Host "已从集中元数据盖章 psd1：$($stamp.Updated -join ', ') → v$($stamp.Version)" }
    } catch {
        Write-Host "集中元数据盖章失败（$($_.Exception.Message)），继续用 psd1 现值。" -ForegroundColor Yellow
    }
}

# 定位目标目录
if (-not $Target) {
    $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $srcDir 'ClaudeCodeTask.psd1')
    $version  = [string]$manifest.ModuleVersion
    $docsDir  = [Environment]::GetFolderPath('MyDocuments')
    $Target   = Join-Path $docsDir (Join-Path 'PowerShell\Modules\ClaudeCodeTask' $version)
}

Write-Host "同步源目录 : $srcDir"
Write-Host "目标模块目录: $Target"
Write-Host ''

# 预检
if (-not (Test-Path -LiteralPath $srcDir)) { throw "仓库源码目录不存在：$srcDir（脚本须放在仓库根目录运行）" }
if (-not (Test-Path -LiteralPath $Target)) { throw "目标安装目录不存在：$Target`n请先 Install-Module -Name ClaudeCodeTask 安装后再同步，或用 -Target 指定已有模块目录。" }

# 检测 6：同目录下其他版本号目录（信息性提示，不阻塞）
$otherVers = @(Get-ChildItem -LiteralPath (Split-Path -Parent $Target) -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne (Split-Path -Leaf $Target) } | ForEach-Object { $_.Name })
if ($otherVers.Count -gt 0) {
    Write-Host "提示：模块目录下还有其他版本（$($otherVers -join ', ')）。PowerShell 只加载版本号最高的目录；确认不再回退后可手动删除旧版本目录。" -ForegroundColor DarkGray
}

# 组成 源→目标 文件对（顶层文件 + 内嵌 lib dll），逐对判定是否需要更新
$files = [System.Collections.Generic.List[object]]::new()
foreach ($n in $topFiles) {
    $src = Join-Path $srcDir $n
    if (-not (Test-Path -LiteralPath $src)) { throw "仓库源文件缺失：$src" }
    $files.Add([pscustomobject]@{ Name = $n; Src = $src; Dst = Join-Path $Target $n; Changed = $false })
}
$srcLib = Join-Path $srcDir 'lib\ClaudeCodeTask.Core.dll'
if (-not (Test-Path -LiteralPath $srcLib)) { throw "仓库源文件缺失：$srcLib" }
$files.Add([pscustomobject]@{ Name = 'lib\ClaudeCodeTask.Core.dll'; Src = $srcLib; Dst = Join-Path $Target 'lib\ClaudeCodeTask.Core.dll'; Changed = $false })

foreach ($f in $files) {
    if (Test-Path -LiteralPath $f.Dst) {
        try {
            # 目标被独占锁定（其他进程 FileShare.None）时连读都失败——按「需更新」继续，
            # 让流程走到覆盖阶段报出贴合场景的错误（被占用），不在这里整体崩掉
            $srcHash = (Get-FileHash -LiteralPath $f.Src -Algorithm SHA256 -ErrorAction Stop).Hash
            $dstHash = (Get-FileHash -LiteralPath $f.Dst -Algorithm SHA256 -ErrorAction Stop).Hash
            if ($srcHash -eq $dstHash) { continue }   # 已一致，不更新
        } catch { }
    }
    $f.Changed = $true
}

$toChange = @($files | Where-Object Changed)

# ── 热加载辅助（检测 5）：定义在分支之前，两条分支共用 ──────────────────────────
# 判定当前进程能否安全热加载。仓库惯例：内核签名变更即换类名（V4→V5），所以
# 「当前进程驻留的 ClaudeCodeTask.Core 程序集不含新 Data.ps1 守卫类型名」== 旧内核 ==
# 热加载必撞同名程序集冲突 → 必须跳过。
function Test-CctCanHotReload {
    param([string]$DataPsPath)
    # 从新 Data.ps1 读内核守卫类型名（if (-not ('CctScannerV5' -as [type]))），与换名惯例联动、不硬编码
    $guardName = $null
    try {
        $m = Select-String -LiteralPath $DataPsPath -Pattern "'(CctScannerV\d+)' -as \[type\]" | Select-Object -First 1
        if ($m) { $guardName = $m.Matches[0].Groups[1].Value }
    } catch { }
    if (-not $guardName) { return $true }   # 解析不出守卫名时按可热加载处理（烟测已兜底）
    $asm = @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'ClaudeCodeTask.Core' })
    if ($asm.Count -eq 0) { return $true }   # 本进程没加载过内核 → 全新加载无冲突
    foreach ($a in $asm) {
        if ($a.GetType($guardName)) { return $true }   # 驻留内核已含新类型 → 守卫会跳过 Add-Type，无冲突
    }
    return $false
}

function Invoke-CctHotReload {
    # 先测后撤：检测不过不动 Remove-Module，保证当前终端旧模块原样保留（不把终端弄成无模块/半损坏态）
    if (-not (Test-CctCanHotReload -DataPsPath (Join-Path $Target 'Data.ps1'))) { return $false }
    try {
        # 目录名是版本号、不等于模块名（ClaudeCodeTask），传目录路径导入会报「no valid module file」，
        # 所以显式导目标目录下的 psm1 文件（路径直导，绕开 PowerShell 的模块名/目录名匹配规则）。
        Remove-Module ClaudeCodeTask -Force -ErrorAction SilentlyContinue
        Import-Module -Force -ErrorAction Stop -Name (Join-Path $Target 'ClaudeCodeTask.psm1')
    } catch {
        Write-Host "热加载失败：$($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
    $newManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $Target 'ClaudeCodeTask.psd1')
    Write-Host "当前终端已直接加载 cct v$($newManifest.ModuleVersion)，输入 cct 即用新代码（无需重开终端）"
    return $true
}

function Write-HotReloadBlocked {
    param([string]$Version, [switch]$NoChange)
    if ($NoChange) {
        Write-Host "文件无需更新（仓库与本机安装副本一致，已是 v$Version）。"
    } else {
        Write-Host "同步完成（v$Version 已写入安装副本，新开终端即可用）。" -ForegroundColor Green
    }
    Write-Host '当前终端不热切换，原因与处理：' -ForegroundColor Yellow
    Write-Host '  本终端此前加载过旧版内核 dll。.NET 程序集无法在进程内卸载，同名替换会被'
    Write-Host '  拒绝（"Assembly with same name is already loaded"），强行热加载会让本终端'
    Write-Host '  的 cct 变成「函数在、内核缺」的损坏状态（扫描时报 Unable to find type）。'
    Write-Host '  → 新开一个终端运行 cct 即用新版本。'
    Write-Host '  → 本终端未受影响的继续用旧版；若已处于上述异常状态（上次同步热加载失败遗留），关闭重开即恢复。'
}

if ($ListOnly) {
    if ($toChange.Count -eq 0) {
        Write-Host '无需更新：仓库源码与本机安装副本完全一致。'
    } else {
        Write-Host '以下文件将更新（-ListOnly 预览，未做任何改动）：'
        $toChange | ForEach-Object { Write-Host "  $($_.Name)" }
    }
    exit 0
}

if ($toChange.Count -eq 0) {
    Write-Host '无需更新：仓库源码与本机安装副本完全一致。'
    # 即使无变化，也把当前进程切到仓库当前版本（满足「同步完即可用」）；不可热加载时给出指引
    if (-not (Invoke-CctHotReload)) {
        $newManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $Target 'ClaudeCodeTask.psd1')
        Write-Host ''
        Write-HotReloadBlocked -Version ([string]$newManifest.ModuleVersion) -NoChange
    }
    exit 0
}

# 目标 lib\ 子目录可能不存在（新建空版本目录时），先确保它存在再拷 dll
$libDir = Join-Path $Target 'lib'
if (-not (Test-Path -LiteralPath $libDir)) { New-Item -ItemType Directory -Path $libDir -Force | Out-Null }

# 先备份将被覆盖的旧文件（检测 2）。备份目标含子路径（lib\）时须先建父目录——
# Copy-Item 不会自动创建多级目标目录；任一备份失败即中止，不覆盖任何文件。
$backupDir = Join-Path ([System.IO.Path]::GetTempPath()) ('cct-sync-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$backupFails = [System.Collections.Generic.List[string]]::new()
foreach ($f in $toChange) {
    if (Test-Path -LiteralPath $f.Dst) {
        $bakPath = Join-Path $backupDir $f.Name
        $bakDir  = Split-Path -Parent $bakPath
        try {
            if (-not (Test-Path -LiteralPath $bakDir)) { New-Item -ItemType Directory -Path $bakDir -Force | Out-Null }
            Copy-Item -LiteralPath $f.Dst -Destination $bakPath
        } catch {
            $backupFails.Add("$($f.Name): $($_.Exception.Message)")
        }
    }
}
if ($backupFails.Count -gt 0) {
    Write-Host '备份失败，已中止（未覆盖任何文件，安装副本保持原状）：' -ForegroundColor Red
    $backupFails | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host "已备份将被覆盖的旧文件到: $backupDir"
Write-Host ''

# 逐文件覆盖，单个失败不中断（检测 3）
$failed = [System.Collections.Generic.List[string]]::new()
foreach ($f in $toChange) {
    try {
        Copy-Item -LiteralPath $f.Src -Destination $f.Dst -Force
        Write-Host "  已覆盖 $($f.Name)"
    } catch {
        $failed.Add($f.Name)
        Write-Host "  失败 $($f.Name): $($_.Exception.Message)"
    }
}

if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host "有 $($failed.Count) 个文件覆盖失败——多半是仍有程序占用目标文件（其他终端的 cct / 杀软实时扫描）：$($failed -join ', ')" -ForegroundColor Yellow
    Write-Host '请关闭所有运行 cct 的终端（或先 Remove-Module ClaudeCodeTask）后重新运行本脚本。'
    Write-Host '注意：本次覆盖不完整，安装副本可能处于新旧混杂状态，修复前请勿在新终端运行 cct。' -ForegroundColor Yellow
    Write-Host "已覆盖部分的旧文件备份仍在：$backupDir"
    exit 1
}

# 检测 4：覆盖后烟测——新开独立 pwsh 子进程验证安装副本（与当前进程隔离，不受
# 本进程已加载旧程序集影响；验证的正是「全新终端装上能不能用」）
$psm1Path = Join-Path $Target 'ClaudeCodeTask.psm1'
$pwshExe = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }
$smokeScript = @'
$ErrorActionPreference = 'Stop'
Import-Module -Name '__PSM1__' -ErrorAction Stop
if (-not (Get-Command cct -ErrorAction SilentlyContinue)) { throw 'cct 命令未导出' }
$null = Get-CctTasks -Root '__SENTINEL__'
'@
$smokeScript = $smokeScript.Replace('__PSM1__', $psm1Path).Replace('__SENTINEL__', (Join-Path ([System.IO.Path]::GetTempPath()) ('cct-smoke-root-' + [guid]::NewGuid().ToString('N'))))
& $pwshExe -NoProfile -Command $smokeScript
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '烟测失败：全新 pwsh 导入安装副本报错（详见上方输出），安装副本可能不完整或损坏。' -ForegroundColor Red
    Write-Host "覆盖前的旧文件备份在：$backupDir —— 可将备份文件拷回安装副本还原，或修复源码后重新同步。"
    exit 1
}
Write-Host '烟测通过：安装副本在全新终端可正常加载并扫描。'
Write-Host ''

# 检测 5：热加载当前终端（可能因旧内核驻留被跳过，详见文件头）
if (Invoke-CctHotReload) {
    Write-Host ''
    Write-Host '同步完成。'
} else {
    Write-Host ''
    $newManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $Target 'ClaudeCodeTask.psd1')
    Write-HotReloadBlocked -Version ([string]$newManifest.ModuleVersion)
}
