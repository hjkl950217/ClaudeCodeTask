# 命令式模式框架测试（第十七轮：显式 ui 方案）
# 覆盖：空格规范化、子命令路由全态（含 -h 分级 / 未知命令 / 未知选项 / ui 非 TTY 降级）、
#       分派、list/find/run 行为、帮助文本中文占位符、版本号。
# fixture：假 projects 目录注入（复用 Cct.Tests 的夹具构造方式）

BeforeAll {
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Config.ps1"
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Data.ps1"
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Launcher.ps1"   # Invoke-CctRun 依赖 Invoke-CctTask
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Command.ps1"

    $script:tmp = Join-Path $env:TEMP ("cct_cmd_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $script:tmp | Out-Null
    $script:cfgPath = Join-Path $script:tmp 'config.json'
    $script:projRoot = Join-Path $script:tmp 'projects'
    New-Item -ItemType Directory -Force "$script:projRoot\E---t---" | Out-Null
    $script:taskA = Join-Path $script:tmp 'taskA'
    $script:taskB = Join-Path $script:tmp 'taskB'
    New-Item -ItemType Directory -Force $script:taskA, $script:taskB | Out-Null
    $script:origLoc = (Get-Location).Path

    function New-TestJsonl([string]$Name, [int]$Msgs, [string]$Ts, [string]$Title, [string]$Cwd) {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add(('{"type":"custom-title","customTitle":"' + $Title + '","sessionId":"' + $Name + '"}'))
        $cwdJson = $Cwd -replace '\\', '\\'
        for ($i = 1; $i -le $Msgs; $i++) {
            $lines.Add(('{"type":"user","cwd":"' + $cwdJson + '","timestamp":"' + $Ts + '","message":{"role":"user","content":"m' + $i + '"},"uuid":"u' + $i + '","parentUuid":null}'))
        }
        [System.IO.File]::WriteAllLines((Join-Path "$script:projRoot\E---t---" "$Name.jsonl"), $lines, [System.Text.UTF8Encoding]::new($false))
    }
    # taskA（2 个手动命名会话）+ taskB（1 个）；taskB 会话最新 → 排序首位
    New-TestJsonl 's1' 12 '2026-08-27T02:00:00.000Z' '调优' $script:taskA
    New-TestJsonl 's2' 15 '2026-08-28T02:00:00.000Z' '日志整理' $script:taskA
    New-TestJsonl 's3' 20 '2026-08-29T02:00:00.000Z' '部署' $script:taskB

    # 强制走全量扫描（无缓存文件 < 拐点 20 天然全量），不走真实用户缓存
    $script:cachePath = Join-Path $script:tmp 'not-exist-cache.json'
    $script:noExclude = [string[]]@()
}

AfterAll {
    Set-Location $script:origLoc
    if (Test-Path $script:tmp) { Remove-Item -Recurse -Force $script:tmp }
}

Describe 'Normalize-CctTokens（空格规范化）' {
    It '空输入返回空数组' {
        @(Normalize-CctTokens @()).Count | Should -Be 0
    }
    It '常规半角分词直接透传' {
        $r = @(Normalize-CctTokens @('ui', '调优'))
        $r.Count | Should -Be 2
        $r[1] | Should -Be '调优'
    }
    It '全角空格黏在参数开头被拆掉' {
        $r = @(Normalize-CctTokens @('　ui'))
        $r.Count | Should -Be 1
        $r[0] | Should -Be 'ui'
    }
    It '词间全角空格被当作分隔符' {
        $r = @(Normalize-CctTokens @('调优　优化'))
        $r.Count | Should -Be 2
        $r[0] | Should -Be '调优'
        $r[1] | Should -Be '优化'
    }
    It '半角全角混合折叠' {
        $r = @(Normalize-CctTokens @('ui', '调优　优化'))
        $r.Count | Should -Be 3
        $r[1] | Should -Be '调优'
        $r[2] | Should -Be '优化'
    }
}

Describe 'Test-CctCommandName（子命令名判定）' {
    It '命中注册子命令 list' {
        Test-CctCommandName 'list' | Should -BeTrue
    }
    It '大小写不敏感' {
        Test-CctCommandName 'List' | Should -BeTrue
    }
    It '普通关键词不命中' {
        Test-CctCommandName '调优' | Should -BeFalse
        Test-CctCommandName 'sub2api' | Should -BeFalse
    }
    It '空串不命中' {
        Test-CctCommandName '' | Should -BeFalse
    }
}

Describe 'Resolve-CctInvocation（路由决策）' {
    It 'cct（有 TTY）→ Interactive，空关键词' {
        $r = Resolve-CctInvocation -Tokens @() -HasTty $true
        $r.Mode | Should -Be 'Interactive'
        $r.Keyword | Should -Be ''
    }
    It 'cct（无 TTY）→ List 降级（不卡 TUI）' {
        (Resolve-CctInvocation -Tokens @() -HasTty $false).Mode | Should -Be 'List'
    }
    It 'cct -h → Help（全局帮助，Command 为空）' {
        $r = Resolve-CctInvocation -Tokens @('-h') -HasTty $true
        $r.Mode | Should -Be 'Help'
        $r.Command | Should -BeNullOrEmpty
    }
    It 'cct --help → Help（无 TTY 也不影响）' {
        (Resolve-CctInvocation -Tokens @('--help') -HasTty $false).Mode | Should -Be 'Help'
    }
    It 'cct help → Help（help 子命令等价 -h）' {
        (Resolve-CctInvocation -Tokens @('help') -HasTty $true).Mode | Should -Be 'Help'
    }
    It 'cct -v / --version / version → Version' {
        (Resolve-CctInvocation -Tokens @('-v') -HasTty $true).Mode | Should -Be 'Version'
        (Resolve-CctInvocation -Tokens @('--version') -HasTty $true).Mode | Should -Be 'Version'
        (Resolve-CctInvocation -Tokens @('version') -HasTty $true).Mode | Should -Be 'Version'
    }
    It 'cct list → Command，无剩余参数' {
        $r = Resolve-CctInvocation -Tokens @('list') -HasTty $true
        $r.Mode | Should -Be 'Command'
        $r.Name | Should -Be 'list'
        @($r.Tokens).Count | Should -Be 0
    }
    It 'cct list 调优 → Command + 过滤参数' {
        $r = Resolve-CctInvocation -Tokens @('list', '调优') -HasTty $true
        $r.Mode | Should -Be 'Command'
        $r.Tokens[0] | Should -Be '调优'
    }
    It 'cct list（无 TTY）仍走 Command' {
        (Resolve-CctInvocation -Tokens @('list') -HasTty $false).Mode | Should -Be 'Command'
    }
    It 'cct find 部署 → Command + 参数' {
        $r = Resolve-CctInvocation -Tokens @('find', '部署') -HasTty $true
        $r.Mode | Should -Be 'Command'
        $r.Name | Should -Be 'find'
        $r.Tokens[0] | Should -Be '部署'
    }
    It 'cct run 调优 → Command' {
        (Resolve-CctInvocation -Tokens @('run', '调优') -HasTty $true).Mode | Should -Be 'Command'
    }
    It 'cct ui 调优（有 TTY）→ Command' {
        $r = Resolve-CctInvocation -Tokens @('ui', '调优') -HasTty $true
        $r.Mode | Should -Be 'Command'
        $r.Name | Should -Be 'ui'
    }
    It 'cct ui 调优（无 TTY）→ List 降级，过滤词透传' {
        $r = Resolve-CctInvocation -Tokens @('ui', '调优') -HasTty $false
        $r.Mode | Should -Be 'List'
        @($r.Tokens).Count | Should -Be 1
        $r.Tokens[0] | Should -Be '调优'
    }
    It 'cct list -h → CommandHelp（子命令帮助）' {
        $r = Resolve-CctInvocation -Tokens @('list', '-h') -HasTty $true
        $r.Mode | Should -Be 'CommandHelp'
        $r.Command | Should -Be 'list'
    }
    It 'cct find --help → CommandHelp' {
        $r = Resolve-CctInvocation -Tokens @('find', '--help') -HasTty $true
        $r.Mode | Should -Be 'CommandHelp'
        $r.Command | Should -Be 'find'
    }
    It 'cct ui -h → CommandHelp（ui 的帮助）' {
        (Resolve-CctInvocation -Tokens @('ui', '-h') -HasTty $true).Command | Should -Be 'ui'
    }
    It '未注册词（有 TTY）→ Error，不再回退交互式' {
        $r = Resolve-CctInvocation -Tokens @('调优') -HasTty $true
        $r.Mode | Should -Be 'Error'
        $r.Message | Should -Match '未知子命令'
    }
    It '未注册词（无 TTY）→ Error（不再是 List）' {
        (Resolve-CctInvocation -Tokens @('123') -HasTty $false).Mode | Should -Be 'Error'
    }
    It '未知选项 -x → Error' {
        $r = Resolve-CctInvocation -Tokens @('-x') -HasTty $true
        $r.Mode | Should -Be 'Error'
        $r.Message | Should -Match '未知选项'
    }
    It '全角空格归一后仍正确路由' {
        $r = Resolve-CctInvocation -Tokens @('ui　调优') -HasTty $true
        $r.Mode | Should -Be 'Command'
        $r.Name | Should -Be 'ui'
        $r.Tokens[0] | Should -Be '调优'
    }
}

Describe 'Invoke-CctCommand（子命令分派机制）' {
    It '按注册表分派：调用了注册的处理函数并透传参数' {
        $script:fakeCalled = $null
        function Invoke-CctFake { param([string[]]$Tokens) $script:fakeCalled = ($Tokens -join ','); return 'fake-ok' }
        $script:CctCommands['fake'] = 'Invoke-CctFake'
        try {
            $out = Invoke-CctCommand 'fake' -Tokens @('a', 'b')
            $out | Should -Be 'fake-ok'
            $script:fakeCalled | Should -Be 'a,b'
        } finally {
            $script:CctCommands.Remove('fake')
            Remove-Item Function:Invoke-CctFake -ErrorAction SilentlyContinue
        }
    }
    It 'HasTty 显式传入时透传给 handler' {
        $script:fakeTty = $null
        function Invoke-CctFake2 { param([string[]]$Tokens, [bool]$HasTty = $true) $script:fakeTty = $HasTty }
        $script:CctCommands['fake2'] = 'Invoke-CctFake2'
        try {
            Invoke-CctCommand 'fake2' -Tokens @() -HasTty $false
            $script:fakeTty | Should -BeFalse
        } finally {
            $script:CctCommands.Remove('fake2')
            Remove-Item Function:Invoke-CctFake2 -ErrorAction SilentlyContinue
        }
    }
    It '未注册子命令抛错' {
        { Invoke-CctCommand 'no-such-cmd' -Tokens @() } | Should -Throw
    }
}

Describe 'Get-CctHelpText（帮助文本）' {
    It '无参返回全局帮助，含用法与全部命令' {
        $h = @(Get-CctHelpText) -join "`n"
        $h | Should -Match '用法: cct <命令>'
        $h | Should -Match 'cct ui \[过滤词\]'
        $h | Should -Match 'cct list \[过滤词\.\.\.\]'
        $h | Should -Match 'cct find <过滤词>'
        $h | Should -Match 'cct run \[选项\] \('
        $h | Should -Match '\-\-json'
        $h | Should -Match '\-h, \-\-help'
    }
    It '全局帮助命令列表带 [交互]/[指令] 类型标记' {
        $h = @(Get-CctHelpText) -join "`n"
        $h | Should -Match '\[交互\] ui'
        $h | Should -Match '\[指令\] list'
        $h | Should -Match '\[指令\] find'
        $h | Should -Match '\[指令\] run'
        $h | Should -Match '\[指令\] help'
        $h | Should -Match '\[指令\] version'
    }
    It 'find 帮助：含 cct find 用法与中文必填占位符' {
        $h = @(Get-CctHelpText -Command 'find') -join "`n"
        $h | Should -Match 'cct find \[选项\] <过滤词>'
        $h | Should -Match '必填'
    }
    It '占位符 <> 与 [] 内用中文而非英文' {
        $h = @(Get-CctHelpText -Command 'find') -join "`n"
        $m = [regex]::Matches($h, '[<\[][^<\[\]>]+[>\]]')
        $m.Count | Should -BeGreaterThan 0
        foreach ($mm in $m) {
            $inner = $mm.Value.TrimStart('<', '[').TrimEnd('>', ']')
            $inner -match '[a-zA-Z]' | Should -BeFalse
        }
    }
    It 'ui / list / run 帮助都可取到' {
        @(Get-CctHelpText -Command 'ui').Count | Should -BeGreaterThan 0
        @(Get-CctHelpText -Command 'list').Count | Should -BeGreaterThan 0
        @(Get-CctHelpText -Command 'run').Count | Should -BeGreaterThan 0
    }
    It '子命令帮助标题带类型标记：ui→[交互]，list/find/run→[指令]' {
        (@(Get-CctHelpText -Command 'ui')   -join "`n") | Should -Match '\[交互\] cct ui'
        (@(Get-CctHelpText -Command 'list') -join "`n") | Should -Match '\[指令\] cct list'
        (@(Get-CctHelpText -Command 'find') -join "`n") | Should -Match '\[指令\] cct find'
        (@(Get-CctHelpText -Command 'run')  -join "`n") | Should -Match '\[指令\] cct run'
    }
    It 'run 帮助：用法为 选项在前 + 目标（最不确定）在后，含 -i' {
        $h = @(Get-CctHelpText -Command 'run') -join "`n"
        $h | Should -Match 'cct run \[选项\] \(-i <会话id> \| <过滤词>\)'
        $h | Should -Match '\-i, \-\-id <会话id>'
    }
    It 'find 帮助：用法为 选项在前 + 过滤词在后' {
        @(Get-CctHelpText -Command 'find') -join "`n" | Should -Match 'cct find \[选项\] <过滤词>'
    }
    It '未知命令返回提示' {
        (@(Get-CctHelpText -Command 'nope') -join "`n") | Should -Match '无法显示帮助'
    }
}

Describe 'Get-CctVersion（版本号）' {
    It '返回 cct v 前缀 + 语义化版本号' {
        Get-CctVersion | Should -Match '^cct v\d+\.\d+\.\d+'
    }
}

Describe 'Invoke-CctList（list 命令：扫描 + 过滤）' {
    It '默认只输出会话项（不含 folder）' {
        $r = @(Invoke-CctList -Root $script:projRoot -ConfigPath $script:cfgPath -ExcludePatterns $script:noExclude)
        $r.Count | Should -BeGreaterThan 0
        ($r | Where-Object Kind -eq 'Folder').Count | Should -Be 0
        ($r | Where-Object Kind -eq 'Session').Count | Should -BeGreaterThan 0
    }
    It 'config includeFolderFind=1 时同时输出 folder 与会话' {
        $cfg1 = Join-Path $script:tmp 'config_inc.json'
        @{ launchCommand='x'; resumeCommand='x'; excludePathPatterns=@(); maxVisibleRows=0; minUserMessages=10; includeFolderFind=1 } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $cfg1 -Encoding utf8
        $r = @(Invoke-CctList -Root $script:projRoot -ConfigPath $cfg1 -ExcludePatterns $script:noExclude)
        ($r | Where-Object Kind -eq 'Folder').Count | Should -BeGreaterThan 0
        ($r | Where-Object Kind -eq 'Session').Count | Should -BeGreaterThan 0
    }
    It '过滤词命中手动命名会话' {
        $r = @(Invoke-CctList -Tokens @('调优') -Root $script:projRoot -ConfigPath $script:cfgPath -ExcludePatterns $script:noExclude)
        $r.Count | Should -BeGreaterThan 0
        ($r | Where-Object Name -eq '调优') | Should -Not -BeNullOrEmpty
    }
    It '过滤词无命中返回空' {
        @(Invoke-CctList -Tokens @('zzzzz') -Root $script:projRoot -ConfigPath $script:cfgPath -ExcludePatterns $script:noExclude).Count | Should -Be 0
    }
    It '多词过滤：join 空格后作为单一子串查询' {
        @(Invoke-CctList -Tokens @('调优', 'x') -Root $script:projRoot -ConfigPath $script:cfgPath -ExcludePatterns $script:noExclude).Count | Should -Be 0
    }
    It '--json 输出可解析的 JSON 字符串' {
        $r = Invoke-CctList -Tokens @('--json') -Root $script:projRoot -ConfigPath $script:cfgPath -ExcludePatterns $script:noExclude
        $r | Should -BeOfType [string]
        @($r | ConvertFrom-Json).Count | Should -BeGreaterThan 0
    }
}

Describe 'Invoke-CctFind（find 命令）' {
    It '缺过滤词抛错' {
        { Invoke-CctFind -Tokens @() -Root $script:projRoot -ConfigPath $script:cfgPath -ExcludePatterns $script:noExclude } | Should -Throw
    }
    It '命中返回任务项' {
        $r = @(Invoke-CctFind -Tokens @('调优') -Root $script:projRoot -ConfigPath $script:cfgPath -ExcludePatterns $script:noExclude)
        $r.Count | Should -BeGreaterThan 0
        ($r | Where-Object Name -eq '调优') | Should -Not -BeNullOrEmpty
    }
    It '不命中返回空' {
        @(Invoke-CctFind -Tokens @('zzzzz') -Root $script:projRoot -ConfigPath $script:cfgPath -ExcludePatterns $script:noExclude).Count | Should -Be 0
    }
}

Describe 'Invoke-CctRun（run 命令：定位并启动）' {
    It '缺过滤词抛错' {
        { Invoke-CctRun -Tokens @() -Root $script:projRoot -ConfigPath $script:cfgPath -ExcludePatterns $script:noExclude } | Should -Throw
    }
    It '唯一会话匹配：--dry-run 返回启动信息而不真正启动' {
        Push-Location $script:origLoc
        try {
            $r = Invoke-CctRun -Tokens @('调优', '--dry-run') -Root $script:projRoot -ConfigPath $script:cfgPath -ExcludePatterns $script:noExclude
            $r.Started | Should -BeTrue
            $r.Command | Should -Not -BeNullOrEmpty
            $r.Location | Should -Be $script:taskA
        } finally { Pop-Location }
    }
    It '多会话匹配：列出候选并返回空（不自动启动）' {
        $r = Invoke-CctRun -Tokens @('taskA') -Root $script:projRoot -ConfigPath $script:cfgPath -ExcludePatterns $script:noExclude
        $r | Should -BeNullOrEmpty
    }
    It '无匹配：抛错' {
        { Invoke-CctRun -Tokens @('zzzzz') -Root $script:projRoot -ConfigPath $script:cfgPath -ExcludePatterns $script:noExclude } | Should -Throw
    }
    It '-i 会话 ID 直达：--dry-run 启动命中会话' {
        Push-Location $script:origLoc
        try {
            $r = Invoke-CctRun -Tokens @('-i', 's3', '--dry-run') -Root $script:projRoot -ConfigPath $script:cfgPath -ExcludePatterns $script:noExclude
            $r.Started | Should -BeTrue
            $r.Location | Should -Be $script:taskB
            $r.Command | Should -Match '--resume s3'
        } finally { Pop-Location }
    }
    It '-i 会话 ID 直达：--id 长格式别名等价值' {
        Push-Location $script:origLoc
        try {
            $r = Invoke-CctRun -Tokens @('--id', 's3', '--dry-run') -Root $script:projRoot -ConfigPath $script:cfgPath -ExcludePatterns $script:noExclude
            $r.Started | Should -BeTrue
            $r.Command | Should -Match '--resume s3'
        } finally { Pop-Location }
    }
    It '-i 不存在的会话 ID：抛错' {
        { Invoke-CctRun -Tokens @('-i', 'no-such-id', '--dry-run') -Root $script:projRoot -ConfigPath $script:cfgPath -ExcludePatterns $script:noExclude } | Should -Throw
    }
    It '-i 缺值：抛错提示需要会话 ID' {
        { Invoke-CctRun -Tokens @('-i') -Root $script:projRoot -ConfigPath $script:cfgPath -ExcludePatterns $script:noExclude } | Should -Throw
    }
    It '同时给 -i 与过滤词：以 -i 为准（绕过过滤）' {
        Push-Location $script:origLoc
        try {
            # 过滤词 'taskB' 会命中 taskB 的 Folder + s3 会话；用 -i s3 应仍精准直达
            $r = Invoke-CctRun -Tokens @('-i', 's3', 'taskB', '--dry-run') -Root $script:projRoot -ConfigPath $script:cfgPath -ExcludePatterns $script:noExclude
            $r.Started | Should -BeTrue
            $r.Command | Should -Match '--resume s3'
        } finally { Pop-Location }
    }
}
