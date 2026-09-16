# clear 命令测试（0.3.0 新增：cct clear 清缓存 / cct clear -cc 清理多余会话）。
# 覆盖：候选判定（J/D/W/O/保留保护/memory）、参数解析、清缓存分支、预览与删除确认流、
#       路由注册（clear 是命令式指令，非交互选择器）、帮助文本。
# 注：fixture 一律放 TEMP 但传 ExcludePatterns @()——Config 默认排除含 AppData\Local\Temp，
#     会误伤 TEMP 下的测试目录；个别用例显式传排除串验证排除生效。

BeforeAll {
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Config.ps1"
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Data.ps1"     # 第二十三轮：Get-CctDirDeletePlan 读标题走 Read-CctSessionFile
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Clear.ps1"
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Command.ps1"

    $script:tmp = Join-Path $env:TEMP ("cct_clear_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $script:tmp | Out-Null

    # 写会话文件：恰好 $n 行（行数近似「对话次数」的判定输入）
    function New-SesJsonl([string]$dir, [string]$sid, [int]$n) {
        $lines = for ($i = 1; $i -le $n; $i++) { ('{"type":"user","content":"m' + $i + '"} dummy-' + ('x' * 30)) }
        [System.IO.File]::WriteAllLines((Join-Path $dir "$sid.jsonl"), $lines, [System.Text.UTF8Encoding]::new($false))
    }
    function Set-SesAge([string]$dir, [string]$sid, [int]$daysAgo) {
        [System.IO.File]::SetLastWriteTimeUtc((Join-Path $dir "$sid.jsonl"), (Get-Date).AddDays(-$daysAgo).ToUniversalTime())
    }
    # 造 3 个编码目录的标准 fixture：
    #   proj1: 旧会话 30 行(3天前) + 新会话 25 行 + 各自附属目录 + memory → 保留新会话；J 旧 / D 旧附属
    #   proj2: 仅 1 个 5 行会话 + memory → W 整目录删
    #   proj3: 40 行会话 + 附属目录 + 孤立目录 orphan → 保留会话；O orphan
    function New-FullFixture([string]$root) {
        New-Item -ItemType Directory -Force (Join-Path $root 'proj1'), (Join-Path $root 'proj2'), (Join-Path $root 'proj3') | Out-Null
        New-Item -ItemType Directory -Force `
            (Join-Path $root 'proj1\sess-0000000001'), (Join-Path $root 'proj1\sess-0000000002'), (Join-Path $root 'proj1\memory'), `
            (Join-Path $root 'proj2\memory'), `
            (Join-Path $root 'proj3\sess-0000000003'), (Join-Path $root 'proj3\orphan') | Out-Null
        New-Item -ItemType Directory -Force (Join-Path $root 'proj1\sess-0000000001\subagents') | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'proj1\sess-0000000001\subagents\agent-a.jsonl') '{"type":"assistant"}'
        New-SesJsonl (Join-Path $root 'proj1') 'sess-0000000001' 30   # 旧
        New-SesJsonl (Join-Path $root 'proj1') 'sess-0000000002' 25   # 新
        New-SesJsonl (Join-Path $root 'proj2') 'sess-0000000004' 5
        New-SesJsonl (Join-Path $root 'proj3') 'sess-0000000003' 40
        Set-SesAge (Join-Path $root 'proj1') 'sess-0000000001' 3
    }
    # 构造一个只含指定编码目录的独立 fixture 根（删除行为测试用，避免相互污染）
    function New-IsolatedRoot([string]$parent) {
        $r = Join-Path $parent ("iso_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force $r | Out-Null
        return $r
    }

    $script:origLoc = (Get-Location).Path
}

AfterAll {
    Set-Location $script:origLoc
    if (Test-Path $script:tmp) { Remove-Item -Recurse -Force $script:tmp }
}

Describe 'Get-CctCleanupCandidates（候选判定）' {
    It '每目录保留最新 ≥阈值会话，未保留会话列 J（同目录保留信息写入理由）' {
        $root = New-IsolatedRoot $script:tmp
        New-FullFixture $root
        $r = Get-CctCleanupCandidates -Root $root -MinLines 20 -Keep 1 -ExcludePatterns @()
        @($r.Keep).Count | Should -Be 2     # proj1 保留最新 sess-2，proj3 保留 sess-3
        ($r.Keep | Where-Object DirName -eq 'proj1').Name | Should -Be 'sess-0000000002.jsonl'
        ($r.Keep | Where-Object DirName -eq 'proj3').Name | Should -Be 'sess-0000000003.jsonl'
        $j = @($r.Candidates | Where-Object { $_.Type -eq 'J' })
        $j.Count | Should -Be 1
        $j[0].Display | Should -Be 'proj1\sess-0000000001.jsonl'
        $j[0].Reason | Should -Match 'sess-000'          # Reason 里的保留会话展示前 8 位
    }
    It '被删会话的同名附属目录列 D，保留会话附属与 memory 不列入' {
        $root = New-IsolatedRoot $script:tmp
        New-FullFixture $root
        $r = Get-CctCleanupCandidates -Root $root -MinLines 20 -Keep 1 -ExcludePatterns @()
        $d = @($r.Candidates | Where-Object Type -eq 'D')
        $d.Count | Should -Be 1
        $d[0].Display | Should -Be 'proj1\sess-0000000001'
        $disp = @($r.Candidates | ForEach-Object Display) -join '|'
        $disp | Should -Not -Match 'sess-0000000002'      # 保留会话附属不删
        $disp | Should -Not -Match 'memory'               # memory 单独不列
    }
    It '目录内会话全 < 阈值 → 整目录删 W（proj2 连同 memory）' {
        $root = New-IsolatedRoot $script:tmp
        New-FullFixture $root
        $r = Get-CctCleanupCandidates -Root $root -MinLines 20 -Keep 1 -ExcludePatterns @()
        $w = @($r.Candidates | Where-Object Type -eq 'W')
        $w.Count | Should -Be 1
        $w[0].Display | Should -Be 'proj2'
        $w[0].Path | Should -Be (Join-Path $root 'proj2')
    }
    It '孤立目录（无对应 jsonl）列 O' {
        $root = New-IsolatedRoot $script:tmp
        New-FullFixture $root
        $r = Get-CctCleanupCandidates -Root $root -MinLines 20 -Keep 1 -ExcludePatterns @()
        $o = @($r.Candidates | Where-Object Type -eq 'O')
        $o.Count | Should -Be 1
        $o[0].Display | Should -Be 'proj3\orphan'
    }
    It 'Keep=2 时保留前两个最新 ≥阈值会话，第三个才删' {
        $root = New-IsolatedRoot $script:tmp
        New-Item -ItemType Directory -Force (Join-Path $root 'k2') | Out-Null
        New-SesJsonl (Join-Path $root 'k2') 's-a' 40; Set-SesAge (Join-Path $root 'k2') 's-a' 3
        New-SesJsonl (Join-Path $root 'k2') 's-b' 30; Set-SesAge (Join-Path $root 'k2') 's-b' 2
        New-SesJsonl (Join-Path $root 'k2') 's-c' 22
        $r = Get-CctCleanupCandidates -Root $root -MinLines 20 -Keep 2 -ExcludePatterns @()
        @($r.Keep).Count | Should -Be 2
        (@($r.Keep | ForEach-Object Name) | Sort-Object) | Should -Be @('s-b.jsonl', 's-c.jsonl')
        (@($r.Candidates | Where-Object Type -eq 'J' | ForEach-Object Display)) | Should -Be 'k2\s-a.jsonl'
    }
    It '--min 阈值生效：min 只保留 ≥ 指定行数的会话' {
        $root = New-IsolatedRoot $script:tmp
        New-Item -ItemType Directory -Force (Join-Path $root 'm1') | Out-Null
        New-SesJsonl (Join-Path $root 'm1') 's-big' 40; Set-SesAge (Join-Path $root 'm1') 's-big' 2
        New-SesJsonl (Join-Path $root 'm1') 's-mid' 25
        New-SesJsonl (Join-Path $root 'm1') 's-sml' 10
        $r = Get-CctCleanupCandidates -Root $root -MinLines 30 -Keep 1 -ExcludePatterns @()
        ($r.Keep[0].Name) | Should -Be 's-big.jsonl'      # 唯一 ≥30
        (@($r.Candidates | Where-Object Type -eq 'J' | ForEach-Object Display)) | Should -Be @('m1\s-mid.jsonl', 'm1\s-sml.jsonl')
    }
    It '排除模式：路径含排除串的编码目录整体跳过，不产生候选' {
        $root = New-IsolatedRoot $script:tmp
        New-Item -ItemType Directory -Force (Join-Path $root 'skipme'), (Join-Path $root 'keepme') | Out-Null
        New-SesJsonl (Join-Path $root 'skipme') 's-x' 5
        New-SesJsonl (Join-Path $root 'keepme') 's-y' 5
        $r = Get-CctCleanupCandidates -Root $root -MinLines 20 -Keep 1 -ExcludePatterns @('skipme')
        $r.Candidates.Count | Should -Be 1
        $r.Candidates[0].Display | Should -Be 'keepme'
    }
    It 'agent-* 与 journal.jsonl 不算会话：只有这类文件的目录被忽略（不误删）' {
        $root = New-IsolatedRoot $script:tmp
        New-Item -ItemType Directory -Force (Join-Path $root 'aux') | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'aux\agent-abc.jsonl') '{"type":"assistant"}'
        Set-Content -LiteralPath (Join-Path $root 'aux\journal.jsonl') '{"type":"summary"}'
        $r = Get-CctCleanupCandidates -Root $root -MinLines 20 -Keep 1 -ExcludePatterns @()
        $r.Candidates.Count | Should -Be 0
        $r.Keep.Count | Should -Be 0
    }
}

Describe 'Remove-CctCleanupItems（真实删除）' {
    It '删除 J/D/O/W 后目录只剩保留会话与其附属、memory' {
        $root = New-IsolatedRoot $script:tmp
        New-FullFixture $root
        $r = Get-CctCleanupCandidates -Root $root -MinLines 20 -Keep 1 -ExcludePatterns @()
        $res = Remove-CctCleanupItems -Candidates @($r.Candidates)
        $res.Deleted | Should -Be 4      # J1 + D1 + W1 + O1
        $res.Failed | Should -Be 0
        # proj1 保留 sess-2（jsonl + 附属 + memory），proj3 保留 sess-3（jsonl + 附属），proj2 整删
        Test-Path -LiteralPath (Join-Path $root 'proj1\sess-0000000002.jsonl') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'proj1\sess-0000000001.jsonl') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'proj1\sess-0000000001') | Should -BeFalse     # D 附属已删
        Test-Path -LiteralPath (Join-Path $root 'proj1\memory') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'proj2') | Should -BeFalse                     # W 整目录删
        Test-Path -LiteralPath (Join-Path $root 'proj3\sess-0000000003.jsonl') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'proj3\orphan') | Should -BeFalse
    }
}

Describe 'Parse-CctClearArgs（clear 专属选项）' {
    It '空 tokens：默认清缓存分支（Cc=false）' {
        $o = Parse-CctClearArgs @()
        $o.Cc | Should -BeFalse; $o.Yes | Should -BeFalse; $o.DryRun | Should -BeFalse
    }
    It '-cc 解析为 Cc' {
        (Parse-CctClearArgs @('-cc')).Cc | Should -BeTrue
    }
    It '-y / --yes 都解析为 Yes' {
        (Parse-CctClearArgs @('-cc', '-y')).Yes | Should -BeTrue
        (Parse-CctClearArgs @('--yes')).Yes | Should -BeTrue
    }
    It '--dry-run 解析' {
        (Parse-CctClearArgs @('-cc', '--dry-run')).DryRun | Should -BeTrue
    }
    It '--keep / --min 带数值' {
        $o = Parse-CctClearArgs @('-cc', '--keep', '3', '--min', '30')
        $o.Keep | Should -Be 3; $o.Min | Should -Be 30
    }
    It '--keep / --min 缺值抛错；非法取值抛错' {
        { Parse-CctClearArgs @('-cc', '--keep') } | Should -Throw
        { Parse-CctClearArgs @('-cc', '--min') } | Should -Throw
        { Parse-CctClearArgs @('-cc', '--keep', '0') } | Should -Throw
    }
    It '未知选项抛错' {
        { Parse-CctClearArgs @('-x') } | Should -Throw
    }
}

Describe 'Invoke-CctClear（主流程）' {
    It '无 -cc：删缓存文件并返回成功提示' {
        $cfgDir = Join-Path $script:tmp ("cfg_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force $cfgDir | Out-Null
        Set-Content -LiteralPath (Join-Path $cfgDir 'cache.json') '{"version":1,"files":{}}'
        $cfgPath = Join-Path $cfgDir 'config.json'
        Set-Content -LiteralPath $cfgPath '{"excludePathPatterns":[]}'
        $msg = Invoke-CctClear -Tokens @() -ConfigPath $cfgPath -Root (Join-Path $script:tmp 'nope')
        $msg | Should -Match '已清除 cct 扫描缓存'
        Test-Path -LiteralPath (Join-Path $cfgDir 'cache.json') | Should -BeFalse
        Test-Path -LiteralPath $cfgPath | Should -BeTrue   # config.json 不动
    }
    It '无 -cc 且无缓存：返回无需清理提示' {
        $cfgDir = Join-Path $script:tmp ("cfg_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force $cfgDir | Out-Null
        $cfgPath = Join-Path $cfgDir 'config.json'
        $msg = Invoke-CctClear -Tokens @() -ConfigPath $cfgPath -Root (Join-Path $script:tmp 'nope')
        $msg | Should -Match '没有 cct 扫描缓存'
    }
    It '-cc 非交互且未 --yes：只出预览不删（安全兜底）' {
        $root = New-IsolatedRoot $script:tmp
        New-FullFixture $root
        $cfgDir = Join-Path $script:tmp ("cfg_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force $cfgDir | Out-Null
        $cfgPath = Join-Path $cfgDir 'config.json'
        Set-Content -LiteralPath $cfgPath '{"excludePathPatterns":[]}'
        $out = Invoke-CctClear -Tokens @('-cc') -HasTty $false -ConfigPath $cfgPath -Root $root *>&1
        ($out -join "`n") | Should -Match '清理规则'
        ($out -join "`n") | Should -Match '待删除 4 项'
        ($out -join "`n") | Should -Match '仅预览，未执行删除'
        Test-Path -LiteralPath (Join-Path $root 'proj2') | Should -BeTrue   # 未删
        Test-Path -LiteralPath (Join-Path $root 'proj1\sess-0000000001.jsonl') | Should -BeTrue
    }
    It '-cc --dry-run：只预览不删（即使 TTY）' {
        $root = New-IsolatedRoot $script:tmp
        New-FullFixture $root
        $cfgDir = Join-Path $script:tmp ("cfg_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force $cfgDir | Out-Null
        $cfgPath = Join-Path $cfgDir 'config.json'
        Set-Content -LiteralPath $cfgPath '{"excludePathPatterns":[]}'
        $out = Invoke-CctClear -Tokens @('-cc', '--dry-run') -HasTty $true -ConfigPath $cfgPath -Root $root *>&1
        Test-Path -LiteralPath (Join-Path $root 'proj2') | Should -BeTrue
    }
    It '-cc --yes（非交互授权）：执行删除' {
        $root = New-IsolatedRoot $script:tmp
        New-FullFixture $root
        $cfgDir = Join-Path $script:tmp ("cfg_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force $cfgDir | Out-Null
        $cfgPath = Join-Path $cfgDir 'config.json'
        Set-Content -LiteralPath $cfgPath '{"excludePathPatterns":[]}'
        $null = Invoke-CctClear -Tokens @('-cc', '--yes') -HasTty $false -ConfigPath $cfgPath -Root $root *>&1
        Test-Path -LiteralPath (Join-Path $root 'proj2') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'proj1\sess-0000000001.jsonl') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'proj1\sess-0000000002.jsonl') | Should -BeTrue
    }
}

Describe '路由与帮助（clear 是命令式指令）' {
    It 'clear 注册为子命令，路由为 Command' {
        Test-CctCommandName 'clear' | Should -BeTrue
        $r = Resolve-CctInvocation -Tokens @('clear') -HasTty $true
        $r.Mode | Should -Be 'Command'; $r.Name | Should -Be 'clear'
        (Resolve-CctInvocation -Tokens @('clear', '-h') -HasTty $true).Mode | Should -Be 'CommandHelp'
        (Resolve-CctInvocation -Tokens @('clear', '-h') -HasTty $true).Command | Should -Be 'clear'
    }
    It '全局帮助含 clear 命令行；clear 帮助可取得' {
        (@(Get-CctHelpText) -join "`n") | Should -Match '\[指令\] clear'
        (@(Get-CctHelpText) -join "`n") | Should -Match 'cct clear \[-cc\]'
        $h = @(Get-CctHelpText -Command 'clear') -join "`n"
        $h | Should -Match '\[指令\] cct clear'
        $h | Should -Match '\-cc'
        $h | Should -Match '--keep <数>'
        $h | Should -Match '--min <行数>'
        $h | Should -Match '--dry-run'
    }
    It 'cct -h 帮助里的 clear 行位置在 run 之后（新增不破坏既有命令文本）' {
        $h = @(Get-CctHelpText) -join "`n"
        $h.IndexOf('cct run') | Should -BeGreaterThan 0
        $h.IndexOf('cct clear') | Should -BeGreaterThan $h.IndexOf('cct run')
    }
    It 'Parse 拒绝 clear 不认识的选项（不被共享层静默接受）' {
        { Parse-CctClearArgs @('-cc', '--json') } | Should -Throw
    }
}

Describe '选择器删除支持：Get-CctDirDeletePlan / Test-CctDirInUse / Remove-CctDirToRecycleBin（第二十三轮）' {
    BeforeAll {
        $script:dRoot = Join-Path $env:TEMP ("cct_dirplan_" + [guid]::NewGuid().ToString('N'))
        $script:dEnc = Join-Path $script:dRoot 'E---taskX---'
        $script:dSess = Join-Path $script:dEnc 'aaaa1111'      # 某会话的附属目录
        $script:dMem = Join-Path $script:dEnc 'memory'
        New-Item -ItemType Directory -Force $script:dEnc, $script:dSess, $script:dMem | Out-Null

        $bs = [string][char]92
        $script:cwdJson = 'E:\t\taskX'.Replace($bs, $bs + $bs)

        function New-PlanJsonl {
            param([string]$Sid, [string]$Title, [int]$Msgs, [string]$Ts, [datetime]$Mod)
            $lines = [System.Collections.Generic.List[string]]::new()
            if ($Title) { $lines.Add(('{"type":"custom-title","customTitle":"' + $Title + '","sessionId":"' + $Sid + '"}')) }
            for ($i = 1; $i -le $Msgs; $i++) {
                $lines.Add(('{"type":"user","cwd":"' + $script:cwdJson + '","timestamp":"' + $Ts + '","message":{"role":"user","content":"m' + $i + '"},"uuid":"u' + $i + '","parentUuid":null}'))
            }
            $p = Join-Path $script:dEnc "$Sid.jsonl"
            [System.IO.File]::WriteAllLines($p, $lines, [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::SetLastWriteTime($p, $Mod)      # 显式设定，供排序断言
        }
        New-PlanJsonl 'aaaa1111' '会话甲' 5 '2026-09-10T10:00:00.000Z' ([datetime]'2026-09-10 10:00')
        New-PlanJsonl 'bbbb2222' '会话乙' 5 '2026-09-15T10:00:00.000Z' ([datetime]'2026-09-15 10:00')
        New-PlanJsonl 'cccc3333' $null   3 '2026-09-12T10:00:00.000Z' ([datetime]'2026-09-12 10:00')   # 无标题
        New-PlanJsonl 'agent-zzz' '子会话' 2 '2026-09-16T10:00:00.000Z' ([datetime]'2026-09-16 10:00')  # agent → 不进清单
        [System.IO.File]::WriteAllLines((Join-Path $script:dEnc 'journal.jsonl'), @('{"type":"workflow"}'), [System.Text.UTF8Encoding]::new($false))
        # 附属目录与 memory 各放点内容，验证 TotalSize 覆盖整目录
        [System.IO.File]::WriteAllText((Join-Path $script:dMem 'm1.md'), ('x' * 1000))
        [System.IO.File]::WriteAllText((Join-Path $script:dSess 'sub.jsonl'), ('y' * 2000))

        function Get-Plan { Get-CctDirDeletePlan -ProjectDir $script:dEnc }
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:dRoot) { Remove-Item -LiteralPath $script:dRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Sessions 只列真会话：agent-* 与 journal.jsonl 计入 OtherCount 但不进清单' {
        $plan = Get-Plan
        $plan.SessionCount | Should -Be 3
        $plan.OtherCount | Should -Be 2
        @($plan.Sessions | ForEach-Object Sid8) | Should -Not -Contain 'agent-zz'
    }
    It 'Sessions 按最后写入降序（最近动过的排最前，确认屏照此顺序展示）' {
        $plan = Get-Plan
        @($plan.Sessions | ForEach-Object Sid8) | Should -Be @('bbbb2222', 'cccc3333', 'aaaa1111')
    }
    It '无标题会话显示为「(未命名)」，Sid8 取会话 id 前 8 位' {
        $plan = Get-Plan
        $c = $plan.Sessions | Where-Object Sid8 -eq 'cccc3333'
        $c.Title | Should -Be '(未命名)'
        $plan.Sessions[0].Sid8 | Should -Be 'bbbb2222'
    }
    It 'TotalSize 覆盖整目录（含附属目录与 memory，不只是清单里的 jsonl）' {
        # 三个 jsonl 合计远小于 3000 字节，另加 memory 1000 + 附属 2000
        (Get-Plan).TotalSize | Should -BeGreaterThan 2500
    }
    It '目录不存在：Exists=false、清单为空、不判占用' {
        $p = Get-CctDirDeletePlan -ProjectDir (Join-Path $script:dRoot '不存在')
        $p.Exists | Should -BeFalse
        $p.SessionCount | Should -Be 0
        $p.InUse | Should -BeFalse
        $p.TotalSize | Should -Be 0
    }
    It 'Test-CctDirInUse：jsonl 被独占打开时判定为占用，释放后恢复可用' {
        (Test-CctDirInUse -ProjectDir $script:dEnc) | Should -BeFalse
        $fs = [System.IO.File]::Open((Join-Path $script:dEnc 'aaaa1111.jsonl'), 'Open', 'ReadWrite', 'None')
        try {
            (Test-CctDirInUse -ProjectDir $script:dEnc) | Should -BeTrue
        } finally { $fs.Close() }
        (Test-CctDirInUse -ProjectDir $script:dEnc) | Should -BeFalse
    }
    It 'Remove-CctDirToRecycleBin：目录进回收站、调用成功、原路径消失（用独立小目录，不动共享 fixture）' {
        $tmpDir = Join-Path $script:dRoot 'delme'
        New-Item -ItemType Directory -Force $tmpDir | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $tmpDir 'a.jsonl'), '{}')
        $res = Remove-CctDirToRecycleBin -ProjectDir $tmpDir
        $res.Ok | Should -BeTrue
        (Test-Path -LiteralPath $tmpDir) | Should -BeFalse
    }
    It 'Remove-CctDirToRecycleBin：目录已不存在时视为成功（幂等，不报错）' {
        $res = Remove-CctDirToRecycleBin -ProjectDir (Join-Path $script:dRoot '从不存在')
        $res.Ok | Should -BeTrue
    }
}
