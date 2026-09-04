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
# 备份 = %TEMP%\cct-sync-backup\<yyyyMMdd-HHmmss>\（先备份再覆盖）

[CmdletBinding()]
param(
    [string]$Target,     # 目标模块目录；省略时按仓库 ClaudeCodeTask.psd1 的 ModuleVersion 自动定位
    [switch]$ListOnly    # 只打印待同步文件与目标路径，不做备份与覆盖
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$srcDir   = Join-Path $repoRoot 'ClaudeCodeTask.UI'

# 模块发布内容（与安装副本逐文件对应）
$topFiles = @(
    'Cct.ps1', 'ClaudeCodeTask.psd1', 'ClaudeCodeTask.psm1', 'Command.ps1',
    'Config.ps1', 'Data.ps1', 'Display.ps1', 'Launcher.ps1', 'Selector.ps1', 'Spinner.ps1', 'Clear.ps1'
)

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
        $srcHash = (Get-FileHash -LiteralPath $f.Src -Algorithm SHA256).Hash
        $dstHash = (Get-FileHash -LiteralPath $f.Dst -Algorithm SHA256).Hash
        if ($srcHash -eq $dstHash) { continue }   # 已一致，不更新
    }
    $f.Changed = $true
}

$toChange = @($files | Where-Object Changed)

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
    # 即使无变化，也把当前进程切到仓库当前版本（满足「同步完即可用」）：
    $newManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $Target 'ClaudeCodeTask.psd1')
    $newVersion  = [string]$newManifest.ModuleVersion
    Remove-Module ClaudeCodeTask -Force -ErrorAction SilentlyContinue
    Import-Module -Force -ErrorAction Stop -Name (Join-Path $Target 'ClaudeCodeTask.psm1')
    Write-Host ''
    Write-Host "当前终端已直接加载 cct v$newVersion，输入 cct 即用（无需重开终端）"
    exit 0
}

# 目标 lib\ 子目录可能不存在（新建空版本目录时），先确保它存在再拷 dll
$libDir = Join-Path $Target 'lib'
if (-not (Test-Path -LiteralPath $libDir)) { New-Item -ItemType Directory -Path $libDir -Force | Out-Null }

# 先备份将被覆盖的旧文件，再逐个覆盖
$backupDir = Join-Path ([System.IO.Path]::GetTempPath()) ('cct-sync-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
foreach ($f in $toChange) {
    if (Test-Path -LiteralPath $f.Dst) { Copy-Item -LiteralPath $f.Dst -Destination (Join-Path $backupDir $f.Name) }
}
Write-Host "已备份将被覆盖的旧文件到: $backupDir"
Write-Host ''

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
    Write-Host "有 $($failed.Count) 个文件覆盖失败——多半是仍有 PowerShell 终端加载着 cct：$($failed -join ', ')"
    Write-Host '请关闭所有运行 cct 的终端（或先 Remove-Module ClaudeCodeTask）后重新运行本脚本。'
    exit 1
}

# 同步完成：当前进程直接卸载旧缓存、强制导入刚同步的版本，无需重开终端即可用新代码
# 注：目录名是版本号、不等于模块名（ClaudeCodeTask），传目录路径导入会报「no valid module file」，
# 所以显式导目标目录下的 psm1 文件（路径直导，绕开 PowerShell 的模块名/目录名匹配规则）。
$newManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $Target 'ClaudeCodeTask.psd1')
$newVersion  = [string]$newManifest.ModuleVersion
Remove-Module ClaudeCodeTask -Force -ErrorAction SilentlyContinue
Import-Module -Force -ErrorAction Stop -Name (Join-Path $Target 'ClaudeCodeTask.psm1')

Write-Host ''
Write-Host "同步完成。当前终端已直接加载 cct v$newVersion，输入 cct 即用新代码（无需重开终端）"
