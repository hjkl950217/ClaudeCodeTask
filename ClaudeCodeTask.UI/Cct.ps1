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
        $Tasks = @(Invoke-WithSpinner -Text '正在扫描会话历史' -ScriptBlock { Get-CctTasks -Root $ProjectsRoot -MinUserMsgs $cfg.minUserMessages -ExcludePatterns $cfg.excludePathPatterns -IncludeFolderFind ($cfg.includeFolderFind -eq 1) })
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

# 用户命令入口：子命令路由（命令式）与交互式并存（第十七轮：显式 ui 方案）。
# 规则：'-' 开头 → 全局选项（-h/--help/-v/--version）；help/version 等价；
#       命中注册表子命令（list/find/run/ui）→ 命令式；子命令含 -h → 该命令帮助；
#       未注册词 → 报错「未知子命令」（关键词只能经 cct ui <词> 进交互式）；
#       无 TTY（stdin 重定向）→ 降级为 list，避免进交互选择器卡死。
function cct {
    # 收参必须用无 param 块的简单函数 + $args：一旦带 [CmdletBinding()] 或参数
    # [Parameter(...)] attribute（触发高级函数语义），公共参数缩写就会把 `-v` 解析成
    # `-Verbose` 吞掉（实测），导致 cct -v 输不出版本。简单函数下所有 token 原样进 $args。
    $tokens = [string[]]$args
    $hasTty = -not [Console]::IsInputRedirected
    $inv = Resolve-CctInvocation -Tokens @($tokens) -HasTty $hasTty
    switch ($inv.Mode) {
        'Interactive' { Invoke-CctMain -Keyword $inv.Keyword; return }
        'List'        { Invoke-CctList -Tokens @($inv.Tokens); return }
        'Help'        { foreach ($l in Get-CctHelpText) { Write-Host $l }; return }
        'CommandHelp' { foreach ($l in Get-CctHelpText -Command $inv.Command) { Write-Host $l }; return }
        'Version'     { foreach ($l in Get-CctVersion) { Write-Host $l }; return }
        'Command'     { Invoke-CctCommand $inv.Name $inv.Tokens; return }
        'Error'       { Write-Error $inv.Message; return }
    }
}
