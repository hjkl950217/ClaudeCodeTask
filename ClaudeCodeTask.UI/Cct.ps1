# cct 主入口（spec 2：数据层 → 界面层 → 执行层）

function Invoke-CctMain {
    [CmdletBinding()]
    param(
        [string]$Keyword = '',
        [string]$ConfigPath = (Join-Path $env:USERPROFILE '.cct\config.json'),
        [string]$ProjectsRoot = (Join-Path $env:USERPROFILE '.claude\projects'),
        [pscustomobject[]]$Tasks = $null,      # 测试注入（$null = 未注入，走扫描）
        [switch]$DryRun,
        [pscustomobject]$SelectedTask = $null  # 测试注入（$null = 走 Show-CctSelector 交互；非 null 直接用它）
    )
    $cfg = Get-CctConfig -Path $ConfigPath

    # 选择前记录原路径：启动失败（没进 claude 会话）时回退
    $origPath = (Get-Location).Path

    if ($null -eq $Tasks) {
        $Tasks = @(Invoke-WithSpinner -Text '正在扫描会话历史' -ScriptBlock { Get-CctTasks -Root $ProjectsRoot -MinUserMsgs $cfg.minUserMessages -ExcludePatterns $cfg.excludePathPatterns })
    }
    if (@($Tasks).Count -eq 0) {
        Write-Host '没有可显示的任务（没有会话历史或目录都已失效）'
        return
    }
    if ($DryRun) { return "共 $($Tasks.Count) 项" }

    $selected = $SelectedTask
    if ($null -eq $selected) { $selected = Show-CctSelector -Tasks $Tasks -InitialQuery $Keyword }
    if ($null -eq $selected) { return }   # Esc 取消，静默退出

    $result = Invoke-CctTask -Item $selected -Config $cfg
    if (-not $result.Started) { Set-Location -LiteralPath $origPath }
}

# 用户命令入口
function cct {
    param([string]$Keyword = '')
    Invoke-CctMain -Keyword $Keyword
}
