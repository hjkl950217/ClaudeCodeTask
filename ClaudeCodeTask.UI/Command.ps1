# 命令式模式（子命令路由）：与交互式共享数据层/执行层，只换「中间环节」。
# 路由语义（第十七轮定稿，显式 ui 方案）：
#   - 首 token 以 '-' 开头 → 全局选项（-h/--help/-v/--version，其余报错「未知选项」）
#   - 'help' / 'version' 子命令与 -h / -v 等价
#   - 首 token 命中注册表子命令（list/find/run/ui）→ 命令式；子命令剩余 tokens 含
#     -h / --help → 改出「该子命令帮助」（-h 按位置分级）
#   - 未注册词 → 报错「未知子命令」（不再回退交互式；关键词只能经 cct ui <词> 进入）
#   - ui 在无 TTY（stdin 重定向）下降级为 list，避免进全屏 TUI 卡死
# 注意：参数名不能用 $Args（与自动变量 $args 大小写不敏感冲突，位置绑定失效）。

# 子命令注册表（新增子命令在此登记；help/version 由 Resolve 直接处理，不入表）
$script:CctCommands = @{
    'list' = 'Invoke-CctList'
    'find' = 'Invoke-CctFind'
    'run'  = 'Invoke-CctRun'
    'ui'   = 'Invoke-CctUi'
}

# 空格规范化：PowerShell 只按半角空格切分参数，全角空格（U+3000）会黏在 token 内。
# 统一按「连续空白（含全角）」重切，消除多空格 / 半角全角差异。
function Normalize-CctTokens {
    param([string[]]$Tokens)
    $joined = @($Tokens | ForEach-Object { if ($null -eq $_) { '' } else { [string]$_ } }) -join ' '
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($joined, '\S+')) { $out.Add($m.Value) }
    return @($out)
}

# 子命令剩余参数解析：'-' 开头为选项，其余为位置参数（过滤词等）。
#   bool 选项：--json / --dry-run。
#   -i 带值选项：-i <会话 ID>（run 的会话 ID 直达），'--id' 为长格式别名。
# 调用方保证 -h/--help 已在 Resolve 层截走，此处遇到其他未知选项抛错。
function Split-CctCommandArgs {
    param([string[]]$Tokens)
    $opts = @{}
    $positional = [System.Collections.Generic.List[string]]::new()
    $i = 0
    $list = @($Tokens)
    while ($i -lt $list.Count) {
        $t = $list[$i]
        if ($t.StartsWith('-')) {
            switch ($t.ToLowerInvariant()) {
                '--json'    { $opts['Json'] = $true; $i++; break }
                '--dry-run' { $opts['DryRun'] = $true; $i++; break }
                '-i'        {
                    if ($i + 1 -ge $list.Count) { throw 'cct run -i 需要一个会话 ID 值（用 cct run -h 查看帮助）' }
                    $opts['Id'] = $list[$i + 1]; $i += 2; break
                }
                '--id'      {
                    if ($i + 1 -ge $list.Count) { throw 'cct run -i 需要一个会话 ID 值（用 cct run -h 查看帮助）' }
                    $opts['Id'] = $list[$i + 1]; $i += 2; break
                }
                default     { throw "未知选项: $t（用 cct <命令> -h 查看帮助）" }
            }
        } else {
            $positional.Add($t); $i++
        }
    }
    return [pscustomobject]@{ Options = $opts; Arguments = @($positional) }
}

# 判断 token 是否命中子命令名（纯函数；大小写不敏感）
function Test-CctCommandName {
    param([string]$Name)
    return (-not [string]::IsNullOrEmpty($Name)) -and $script:CctCommands.ContainsKey($Name.ToLowerInvariant())
}

# 路由决策（纯函数，TTY 由调用方注入以便测试）。返回值 Mode：
#   Interactive / List / Help / CommandHelp / Version / Command / Error
function Resolve-CctInvocation {
    param([string[]]$Tokens, [bool]$HasTty)
    $tokens = @(Normalize-CctTokens $Tokens)
    if ($tokens.Count -eq 0) {
        if ($HasTty) { return [pscustomobject]@{ Mode = 'Interactive'; Keyword = '' } }
        return [pscustomobject]@{ Mode = 'List'; Tokens = @() }
    }
    $arg0 = [string]$tokens[0]
    # 全局选项（- 开头，永不进关键词/子命令分支）
    if ($arg0.StartsWith('-')) {
        switch ($arg0.ToLowerInvariant()) {
            '-h'        { return [pscustomobject]@{ Mode = 'Help'; Command = $null } }
            '--help'    { return [pscustomobject]@{ Mode = 'Help'; Command = $null } }
            '-v'        { return [pscustomobject]@{ Mode = 'Version' } }
            '--version' { return [pscustomobject]@{ Mode = 'Version' } }
            default     { return [pscustomobject]@{ Mode = 'Error'; Message = "未知选项: $arg0（用 cct -h 查看帮助）" } }
        }
    }
    # help / version 子命令（与 -h / -v 等价）
    if ($arg0 -ieq 'help')    { return [pscustomobject]@{ Mode = 'Help'; Command = $null } }
    if ($arg0 -ieq 'version') { return [pscustomobject]@{ Mode = 'Version' } }
    # 命中注册子命令 → Command；子命令级 -h/--help → CommandHelp；ui 无 TTY 降级 List
    if (Test-CctCommandName $arg0) {
        $rest = @($tokens | Select-Object -Skip 1)
        if ($rest -contains '-h' -or $rest -contains '--help') {
            return [pscustomobject]@{ Mode = 'CommandHelp'; Command = $arg0.ToLowerInvariant() }
        }
        $name = $arg0.ToLowerInvariant()
        if ($name -eq 'ui' -and -not $HasTty) {
            return [pscustomobject]@{ Mode = 'List'; Tokens = @($rest) }
        }
        return [pscustomobject]@{ Mode = 'Command'; Name = $name; Tokens = @($rest) }
    }
    # 未注册词：不再回退交互式，直接报错（显式 ui 方案，零歧义）
    return [pscustomobject]@{ Mode = 'Error'; Message = "未知子命令: $arg0（用 cct -h 查看帮助）" }
}

# 子命令分派：按注册表函数名转发剩余参数（统一命名参数，避免位置绑定歧义）。
# Root/ConfigPath/ExcludePatterns/HasTty 仅调用方显式传入时才转发（测试注入用）。
function Invoke-CctCommand {
    param([string]$Name, [string[]]$Tokens, [bool]$HasTty = $true, [string]$Root, [string]$ConfigPath, [string[]]$ExcludePatterns)
    $fn = $script:CctCommands[$Name.ToLowerInvariant()]
    if (-not $fn) { throw "未知子命令: $Name" }
    $forward = @{ Tokens = @($Tokens) }
    foreach ($k in @('HasTty', 'Root', 'ConfigPath', 'ExcludePatterns')) {
        if ($PSBoundParameters.ContainsKey($k)) { $forward[$k] = $PSBoundParameters[$k] }
    }
    return & $fn @forward
}

# cct list [过滤词...] [--json]：列出任务（Folder/Session），过滤词 join 空格作子串查询
# Root/ConfigPath/ExcludePatterns 供测试注入；经 Invoke-CctCommand 分派时只传 Tokens
function Invoke-CctList {
    param(
        [string[]]$Tokens = @(),
        [bool]$HasTty = $true,
        [string]$Root = (Join-Path $env:USERPROFILE '.claude\projects'),
        [string]$ConfigPath = (Join-Path $env:USERPROFILE '.cct\config.json'),
        [string[]]$ExcludePatterns = $null
    )
    $parsed = Split-CctCommandArgs -Tokens @($Tokens)
    $filter = $parsed.Arguments -join ' '
    $cfg = Get-CctConfig -Path $ConfigPath
    if ($null -eq $ExcludePatterns) { $ExcludePatterns = $cfg.excludePathPatterns }
    $tasks = @(Get-CctTasks -Root $Root -MinUserMsgs $cfg.minUserMessages -ExcludePatterns $ExcludePatterns -IncludeFolderFind ($cfg.includeFolderFind -eq 1))
    if ($filter) { $tasks = @(Filter-CctTasks -Tasks $tasks -Query $filter) }
    if ($parsed.Options['Json']) { return $tasks | ConvertTo-Json -Depth 4 }
    return $tasks
}

# cct find <过滤词> [--json]：查找会话（过滤词必填，其余复用 list 逻辑）
function Invoke-CctFind {
    param(
        [string[]]$Tokens = @(),
        [bool]$HasTty = $true,
        [string]$Root = (Join-Path $env:USERPROFILE '.claude\projects'),
        [string]$ConfigPath = (Join-Path $env:USERPROFILE '.cct\config.json'),
        [string[]]$ExcludePatterns = $null
    )
    $parsed = Split-CctCommandArgs -Tokens @($Tokens)
    if ($parsed.Arguments.Count -eq 0) { throw 'cct find 需要一个过滤词（用 cct find -h 查看帮助）' }
    return Invoke-CctList -Tokens @($Tokens) -Root $Root -ConfigPath $ConfigPath -ExcludePatterns $ExcludePatterns
}

# cct run (-i <会话id> | <过滤词>) [--dry-run]：定位并启动会话。
# 优先走 -i 会话 ID 直达（精确匹配，任意词不冲突）；无 -i 时按过滤词定位。
# 动词过滤唯一性判定（第十七轮细化）：只以「命中的 Session 项」判唯一（Filter 带出的父文件夹是上下文，
# 非启动目标）；Session 0 个时回退「命中的 Folder 项」判唯一；0/多走对应分支，不自动选、不交互。
function Invoke-CctRun {
    param(
        [string[]]$Tokens = @(),
        [bool]$HasTty = $true,
        [string]$Root = (Join-Path $env:USERPROFILE '.claude\projects'),
        [string]$ConfigPath = (Join-Path $env:USERPROFILE '.cct\config.json'),
        [string[]]$ExcludePatterns = $null
    )
    $parsed = Split-CctCommandArgs -Tokens @($Tokens)
    $dryRun = [bool]$parsed.Options['DryRun']

    $cfg = Get-CctConfig -Path $ConfigPath
    $tasks = @(Get-CctTasks -Root $Root -MinUserMsgs $cfg.minUserMessages -ExcludePatterns $ExcludePatterns -IncludeFolderFind ($cfg.includeFolderFind -eq 1))

    # ── 分支 A：-i 会话 ID 直达（第十八轮新增的精准进入方式，绕过过滤子串）──
    if ($parsed.Options.ContainsKey('Id')) {
        $id = [string]$parsed.Options['Id']
        $hit = @($tasks | Where-Object { $_.Kind -eq 'Session' -and $_.SessionId -eq $id })
        if ($hit.Count -eq 0) { throw "未找到会话 ID 为「$id」的会话（用 cct find -h / cct list --json 查看 ID）" }
        if ($hit.Count -gt 1) { throw "会话 ID「$id」命中了多个会话（数据异常，请联系排查）" }
        return Invoke-CctTask -Item $hit[0] -Config $cfg -DryRun:$dryRun
    }

    # ── 分支 B：过滤词定位（无 -i）──
    $filterArgs = @($parsed.Arguments)
    if ($filterArgs.Count -eq 0) { throw 'cct run 需要一个过滤词（用 cct run -h 查看帮助）' }

    $matches = @(Invoke-CctList -Tokens $filterArgs -Root $Root -ConfigPath $ConfigPath -ExcludePatterns $ExcludePatterns)
    $sessions = @($matches | Where-Object Kind -eq 'Session')
    $folders = @($matches | Where-Object Kind -eq 'Folder')

    $target = $null
    if ($sessions.Count -eq 1) {
        $target = $sessions[0]
    } elseif ($sessions.Count -gt 1) {
        Write-Host "匹配到 $($sessions.Count) 个会话，请收窄关键词或用 cct ui 选择："
        for ($i = 0; $i -lt $sessions.Count; $i++) {
            Write-Host ("  {0}. {1}" -f ($i + 1), $sessions[$i].Name)
        }
        return
    } elseif ($folders.Count -eq 1) {
        $target = $folders[0]
    } elseif ($folders.Count -gt 1) {
        Write-Host "匹配到 $($folders.Count) 个文件夹，请收窄关键词或用 cct ui 选择："
        for ($i = 0; $i -lt $folders.Count; $i++) {
            Write-Host ("  {0}. {1}" -f ($i + 1), $folders[$i].Name)
        }
        return
    } else {
        throw "未找到匹配「$($filterArgs -join ' ')」的会话"
    }

    return Invoke-CctTask -Item $target -Config $cfg -DryRun:$dryRun
}

# cct ui [过滤词]：显式进入交互式选择器（非 TTY 降级已由 Resolve 处理为 List）
function Invoke-CctUi {
    param(
        [string[]]$Tokens = @(),
        [bool]$HasTty = $true,
        [string]$Root = (Join-Path $env:USERPROFILE '.claude\projects'),
        [string]$ConfigPath = (Join-Path $env:USERPROFILE '.cct\config.json'),
        [string[]]$ExcludePatterns = $null
    )
    $keyword = @($Tokens) -join ' '
    return Invoke-CctMain -Keyword $keyword -ConfigPath $ConfigPath -ProjectsRoot $Root
}

# 版本号：读模块 manifest 的 ModuleVersion；第二行输出仓库地址（ProjectUri 在 PrivateData.PSData，单一来源）
function Get-CctVersion {
    $psd1 = Join-Path $PSScriptRoot 'ClaudeCodeTask.psd1'
    $mod = Import-PowerShellDataFile -Path $psd1
    return @("cct v$($mod.ModuleVersion)", "Github地址: $($mod.PrivateData.PSData.ProjectUri)")
}

# 帮助文本（全部中文，含占位符内文字）：无参 = 全局帮助；-Command <名> = 子命令帮助。
# 返回行数组（含空行），供 cct -h 逐行 Write-Host、也便于测试断言。
function Get-CctHelpText {
    param([string]$Command = '')
    if ($Command) {
        switch ($Command.ToLowerInvariant()) {
            'ui' {
                return @('[交互] cct ui —— 打开交互式选择器', '',
                    '用法: cct ui [过滤词]', '',
                    '说明: 打开全屏交互式选择器。不带过滤词与直接运行 cct 等价；',
                    '      带过滤词时选择器预先按该词过滤。', '',
                    '参数:', '  [过滤词]   可选，进入选择器时的初始过滤词', '',
                    '选项:', '  -h, --help   显示本命令帮助')
            }
            'list' {
                return @('[指令] cct list —— 列出任务', '',
                    '用法: cct list [过滤词...]', '',
                    '说明: 列出全部任务（文件夹 + 会话）。多个词用空格分隔，',
                    '      按「词1 词2」整体做子串匹配。', '',
                    '参数:', '  [过滤词...]   可选，过滤词，多个词折叠为单个空格', '',
                    '选项:', '  --json       以 JSON 输出结果', '  -h, --help   显示本命令帮助')
            }
            'find' {
                return @('[指令] cct find —— 查找会话', '',
                    '用法: cct find [选项] <过滤词>', '',
                    '说明: 在全部任务（文件夹 + 会话）中按子串查找，会话命中会带出所属文件夹。', '',
                    '参数:', '  <过滤词>   必填，匹配文件夹名 / 会话标题 / 路径', '',
                    '选项:', '  --json       以 JSON 输出结果', '  -h, --help   显示本命令帮助')
            }
            'run' {
                return @('[指令] cct run —— 定位并启动会话', '',
                    '用法: cct run [选项] (-i <会话id> | <过滤词>)', '',
                    '说明: 两种定位目标二选一，目标内容（最不确定）放在最后输入：',
                    '      带 -i <会话id> 按会话 ID 精准直达（绕过关键词，任意词不冲突）；',
                    '      不带 -i 时按过滤词定位。唯一匹配则立即启动；',
                    '      匹配多个则列出候选，要求收窄关键词或用 cct ui 选择；无匹配则报错。', '',
                    '参数:', '  -i, --id <会话id>   按会话 ID 直达，与 <过滤词> 二选一',
                    '  <过滤词>             定位会话的过滤词（不带 -i 时），放在最后输入', '',
                    '选项:', '  --dry-run    演练运行，显示将启动的命令但不真正启动', '  -h, --help   显示本命令帮助')
            }
            default {
                return @("未知命令: $Command，无法显示帮助", '', '用 cct -h 查看全局帮助。')
            }
        }
    }
    return @(
        'cct —— Claude Code 任务选择器', '',
        '用法: cct <命令> [选项]', '',
        '命令（[交互] 打开全屏选择器操作；[指令] 直接输出/执行）：',
        '  [交互] ui      打开交互式选择器    cct ui [过滤词]',
        '  [指令] list    列出任务          cct list [过滤词...]',
        '  [指令] find    查找会话          cct find <过滤词>',
        '  [指令] run     定位并启动会话      cct run [选项] (-i <会话id> | <过滤词>)',
        '  [指令] help    显示帮助          cct help',
        '  [指令] version 显示版本          cct version', '',
        '选项:',
        '  -h, --help     显示帮助',
        '  -v, --version  显示版本',
        '  --json         以 JSON 输出结果（list / find）',
        '  --dry-run      演练运行，不真正启动（run）',
        '  -i, --id <会话id>  按会话 ID 精准直达（run）', '',
        '示例:',
        '  cct               打开交互式选择器',
        '  cct ui 调优        打开选择器并预过滤「调优」',
        '  cct list          列出全部任务',
        '  cct find 部署      查找含「部署」的会话',
        '  cct run 调优       启动唯一匹配的「调优」会话',
        '  cct run -i 7df5c8c5-46f8-4a84-bd5c-799534ee99b6   按会话 ID 启动',
        '  cct find -h       查看 find 命令帮助'
    )
}
