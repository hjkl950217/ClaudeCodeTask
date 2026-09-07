BeforeAll {
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Data.ps1"
    $script:tmpRoot = Join-Path $env:TEMP ("cct_agg_" + [guid]::NewGuid().ToString('N'))
    # 模拟 projects 目录
    $script:proj = Join-Path $script:tmpRoot 'projects'
    # 模拟真实存在的任务目录
    $script:taskA = Join-Path $script:tmpRoot 'taskA'
    $script:taskB = Join-Path $script:tmpRoot 'taskB'
    $script:taskC = Join-Path $script:tmpRoot 'taskC'
    New-Item -ItemType Directory -Force "$script:proj\E---taskA---", "$script:proj\E---taskB---", "$script:proj\E---taskC---", "$script:proj\E---ConfigBackup---", $script:taskA, $script:taskB, $script:taskC | Out-Null
    $script:taskDeleted = Join-Path $script:tmpRoot '已删除目录'   # 不创建
    # 第九轮场景：会话启动于 taskA，中途 cd 到子目录 sub——jsonl 首现 cwd=taskA、末现 cwd=sub
    $script:taskSub = Join-Path $script:taskA 'sub'
    New-Item -ItemType Directory -Force $script:taskSub | Out-Null

    function New-TestJsonl {
        # StartCwd 可选：给定时第一条 user 记录用 StartCwd、其余用 Cwd → 模拟「会话中途 cd 到子目录」
        param([string]$Dir, [string]$SessionId, [string]$Cwd, [string]$Ts, [int]$Msgs, [string]$Title = $null, [string]$TitleType = $null, [string]$StartCwd = $null)
        # JSON 里反斜杠转义：C:\a → JSON "C:\\a"。单引号 PS 字符串里 '\\' 就是两个字面反斜杠，直接拼接即可
        $cwdJson = $Cwd -replace '\\', '\\'
        $startCwdJson = if ($StartCwd) { $StartCwd -replace '\\', '\\' } else { $cwdJson }
        $lines = [System.Collections.Generic.List[string]]::new()
        if ($Title) {
            $key = if ($TitleType -eq 'custom') { 'customTitle' } else { 'aiTitle' }
            $lines.Add(('{"type":"' + $TitleType + '-title","' + $key + '":"' + $Title + '","sessionId":"' + $SessionId + '"}'))
        }
        for ($i = 1; $i -le $Msgs; $i++) {
            $c = if ($StartCwd -and $i -eq 1) { $startCwdJson } else { $cwdJson }
            $lines.Add(('{"type":"user","cwd":"' + $c + '","timestamp":"' + $Ts + '","message":{"role":"user","content":"m' + $i + '"},"uuid":"u' + $i + '","parentUuid":null}'))
        }
        $path = Join-Path $Dir "$SessionId.jsonl"
        [System.IO.File]::WriteAllLines($path, $lines, [System.Text.UTF8Encoding]::new($false))
        return $path
    }

    # taskA：两个手动命名 + 一个自动命名（3 条，低于阈值）+ agent 文件
    New-TestJsonl "$script:proj\E---taskA---" 'a3' $script:taskA '2026-08-25T10:00:00.000Z' 12 'codex伪装' 'custom'
    New-TestJsonl "$script:proj\E---taskA---" 'a1' $script:taskA '2026-08-26T10:00:00.000Z' 3 'git status概览' 'ai'
    New-TestJsonl "$script:proj\E---taskA---" 'a2' $script:taskA '2026-08-27T10:00:00.000Z' 15 '账号调优' 'custom'
    New-TestJsonl "$script:proj\E---taskA---" 'agent-xyz' $script:taskA '2026-08-27T11:00:00.000Z' 99
    # 第九轮：启动于 taskA、中途 cd 到 taskA\sub 的会话——jsonl 首现 cwd=taskA（存储目录）、末现 cwd=taskSub
    New-TestJsonl "$script:proj\E---taskA---" 'a5' $script:taskSub '2026-08-24T10:00:00.000Z' 12 '中途切换' 'custom' -StartCwd $script:taskA
    # taskB：全部会话 <10 条 + journal
    New-TestJsonl "$script:proj\E---taskB---" 'b1' $script:taskB '2026-08-20T10:00:00.000Z' 4
    [System.IO.File]::WriteAllLines("$script:proj\E---taskB---\journal.jsonl", @('{"type":"workflow"}'), [System.Text.UTF8Encoding]::new($false))
    # taskC：只有一个自动命名 12 条（无手动项 → 保底自动项出现）+ /clear 空壳链尾
    New-TestJsonl "$script:proj\E---taskC---" 'c2' $script:taskC '2026-08-27T09:00:00.000Z' 0 '整理用量接口' 'ai'
    New-TestJsonl "$script:proj\E---taskC---" 'c1' $script:taskC '2026-08-26T09:00:00.000Z' 12 '整理用量接口' 'ai'
    # 已删除目录
    New-TestJsonl "$script:proj\E---taskC---" 'c9' $script:taskDeleted '2026-08-27T12:00:00.000Z' 5
    # ConfigBackup
    New-TestJsonl "$script:proj\E---ConfigBackup---" 'cb1' $script:taskA '2026-08-27T12:00:00.000Z' 20 '备份会话' 'custom'
}
AfterAll {
    if (Test-Path $script:tmpRoot) { Remove-Item -Recurse -Force $script:tmpRoot }
}

Describe 'Get-CctTasks 聚合' {
    BeforeAll { $script:tasks = @(Get-CctTasks -Root $script:proj -MinUserMsgs 10 -ExcludePatterns @('ConfigBackup')) }

    It 'taskA 目录有会话组：folder 头被 session 取代（session 优先），会话平铺保留' {
        # 同目录已有可 resume 的会话时 folder 头冗余——taskA 有账号调优/codex伪装/中途切换 3 个会话组 → 不输出 folder
        ($script:tasks | Where-Object { $_.Kind -eq 'Folder' -and $_.Path -eq $script:taskA }) | Should -BeNullOrEmpty
        @($script:tasks | Where-Object { $_.Kind -eq 'Session' -and $_.GroupKey -eq $script:taskA }).Count | Should -Be 3
    }
    It 'taskA 会话项：手动命名全保留（codex伪装 12 条 + 账号调优 15 条），自动命名 3 条不保留（已有手动项，决策 36）' {
        $sessions = @($script:tasks | Where-Object { $_.Kind -eq 'Session' -and $_.Path -eq $script:taskA })
        $sessions.Count | Should -Be 2
        ($sessions | Where-Object Name -eq '账号调优') | Should -Not -BeNullOrEmpty
        ($sessions | Where-Object Name -eq 'codex伪装') | Should -Not -BeNullOrEmpty
        ($sessions | Where-Object Name -eq 'git status概览') | Should -BeNullOrEmpty
    }
    It '手动命名同样受阈值约束（决策 34 修订）：a4 只有 3 条消息 → 不保留' {
        New-TestJsonl "$script:proj\E---taskA---" 'a4' $script:taskA '2026-08-24T10:00:00.000Z' 3 '签到' 'custom'
        $tasks2 = @(Get-CctTasks -Root $script:proj -MinUserMsgs 10 -ExcludePatterns @('ConfigBackup'))
        ($tasks2 | Where-Object { $_.Kind -eq 'Session' -and $_.Path -eq $script:taskA -and $_.Name -eq '签到' }) | Should -BeNullOrEmpty
    }
    It '第九轮：cwd 首现≠末现（启动后中途 cd 到子目录）的会话归到 StartCwd 分组，且 Path 用末现目录' {
        # a5 jsonl 首现 cwd=taskA（存储目录）、末现 cwd=taskA\sub（resume 目标目录）
        $s = $script:tasks | Where-Object { $_.Kind -eq 'Session' -and $_.Name -eq '中途切换' }
        $s | Should -Not -BeNullOrEmpty
        $s.GroupKey | Should -Be $script:taskA        # 归到 StartCwd（taskA）分组
        $s.Path | Should -Be $script:taskSub         # resume 目标 = 末现目录（sub）
    }
    It '第九轮：无 cwd 首现=taskSub 的文件夹项（幻影 Folder 消失，不再产生 sub 文件夹）' {
        # 旧逻辑按末现 cwd 分组 → 会凭空造出 taskA\sub 文件夹；修复后分组键是首现 cwd，sub 只是会话的 Path
        $script:tasks | Where-Object { $_.Kind -eq 'Folder' -and $_.Path -eq $script:taskSub } | Should -BeNullOrEmpty
    }
    It '手动命名组内 ≥阈值 的文件被选中：账号调优取 a2（15 条）而非更新的碎片' {
        # a2 是唯一的账号调优文件（15 条 ≥ 10），选它
        $s = $script:tasks | Where-Object { $_.Kind -eq 'Session' -and $_.Name -eq '账号调优' }
        $s.SessionId | Should -Be 'a2'
    }
    It 'taskB：全部会话 <10 条，文件夹项仍在（决策 33），无会话项（无标题不算候选，决策 37）' {
        $f = $script:tasks | Where-Object { $_.Kind -eq 'Folder' -and $_.Path -eq $script:taskB }
        $f | Should -Not -BeNullOrEmpty
        $f.Subtitle | Should -BeNullOrEmpty      # b1 无标题 → 副标题留空（决策 38）
        @($script:tasks | Where-Object { $_.Kind -eq 'Session' -and $_.Path -eq $script:taskB }).Count | Should -Be 0
    }
    It 'taskC：无手动项，自动命名 >10 条的留最新一个作保底（决策 35/36）' {
        $sessions = @($script:tasks | Where-Object { $_.Kind -eq 'Session' -and $_.Path -eq $script:taskC })
        $sessions.Count | Should -Be 1
        $sessions[0].Name | Should -Be '整理用量接口'
        $sessions[0].SessionId | Should -Be 'c1'   # c2 是 0 条空壳，跳过（发现 22）
        $sessions[0].TitleType | Should -Be '自动生成'
    }
    It 'taskC 目录有会话组：folder 头同样被 session 取代（不输出），保留保底自动项' {
        ($script:tasks | Where-Object { $_.Kind -eq 'Folder' -and $_.Path -eq $script:taskC }) | Should -BeNullOrEmpty
        ($script:tasks | Where-Object { $_.Kind -eq 'Session' -and $_.GroupKey -eq $script:taskC }).SessionId | Should -Be 'c1'
    }
    It '已删除目录不出现（决策 9）' {
        $script:tasks | Where-Object { $_.Path -eq $script:taskDeleted } | Should -BeNullOrEmpty
    }
    It '排除 agent- 前缀与 journal.jsonl（决策 12）' {
        # taskA 只能有 2 个会话项（若 agent 未排除会多出项）
        @($script:tasks | Where-Object { $_.Kind -eq 'Session' -and $_.Path -eq $script:taskA }).Count | Should -Be 2
    }
    It 'ConfigBackup 目录排除' {
        $script:tasks | Where-Object { $_.Name -eq '备份会话' -or $_.Subtitle -eq '备份会话' } | Should -BeNullOrEmpty
    }
    It '排序：folder 头仅保留在纯目录；会话按目录分组、组内按最近活动降序' {
        # 目录组先后由组内最新活动决定：taskA(08-27T10) > taskC(08-27T09) > taskB(08-20)
        # 有会话组的目录（taskA/taskC）不输出 folder 头、直接平铺会话；纯目录 taskB 的 folder 头保留在末尾
        $script:tasks[0].Name | Should -Be '账号调优'        # taskA 组（无 folder 头，会话直接平铺）
        $script:tasks[1].Name | Should -Be 'codex伪装'
        $script:tasks[2].Name | Should -Be '中途切换'
        $script:tasks[3].Name | Should -Be '整理用量接口'      # taskC 组
        $script:tasks[4].Kind | Should -Be 'Folder'           # taskB 是纯目录 → folder 头在
        $script:tasks[4].Path | Should -Be $script:taskB
    }
    It 'LastActive 转本地时间（UTC+8）' {
        $f = $script:tasks | Where-Object { $_.Kind -eq 'Folder' -and $_.Path -eq $script:taskB }
        $f.LastActive | Should -Be ([datetime]'2026-08-20 18:00:00')   # 10:00Z + 8h
    }
    It '决策 34 修订：手动组内最新文件是 1 条碎片、老文件 12 条达标 → 选老文件，时间用老文件的' {
        # 在 taskC 目录（无其他干扰）构造：标题「设计」新文件 1 条 + 老文件 12 条
        New-TestJsonl "$script:proj\E---taskC---" 'd2' $script:taskC '2026-08-27T20:00:00.000Z' 1 '设计' 'custom'
        New-TestJsonl "$script:proj\E---taskC---" 'd1' $script:taskC '2026-08-15T10:00:00.000Z' 12 '设计' 'custom'
        $tasks3 = @(Get-CctTasks -Root $script:proj -MinUserMsgs 10 -ExcludePatterns @('ConfigBackup'))
        $s = $tasks3 | Where-Object { $_.Kind -eq 'Session' -and $_.Name -eq '设计' }
        $s | Should -Not -BeNullOrEmpty
        $s.SessionId | Should -Be 'd1'          # 选达标的老文件，不是 1 条的新碎片
        $s.LastActive | Should -Be ([datetime]'2026-08-15 18:00:00')   # 老文件时间（UTC+8）
    }
    It '决策 34 修订：手动组内全部文件 <阈值 → 整组不按同名规则列出（第十九轮起由目录升格接手）' {
        New-TestJsonl "$script:proj\E---taskB---" 'b2' $script:taskB '2026-08-26T10:00:00.000Z' 2 '小会话' 'custom'
        $tasks4 = @(Get-CctTasks -Root $script:proj -MinUserMsgs 10 -ExcludePatterns @('ConfigBackup'))
        # taskB 目录无 ≥阈值 会话 → 同名会话规则不生效；由升格机制代表该目录（组内最新有标题者 = b2）
        $tb = @($tasks4 | Where-Object { $_.Kind -eq 'Session' -and $_.GroupKey -eq $script:taskB })
        $tb.Count | Should -Be 1
        $tb[0].SessionId | Should -Be 'b2'
        $tb[0].Name | Should -Be '小会话'
        $tb[0].TitleType | Should -Be '自定义命名'
    }
    It '同名手动命名：组内多条 ≥10 各自列出，不再只留最新（旧同名会话不再被隐藏）' {
        New-TestJsonl "$script:proj\E---taskC---" 'e1' $script:taskC '2026-08-10T10:00:00.000Z' 12 '重构' 'custom'
        New-TestJsonl "$script:proj\E---taskC---" 'e2' $script:taskC '2026-08-20T10:00:00.000Z' 15 '重构' 'custom'
        New-TestJsonl "$script:proj\E---taskC---" 'e3' $script:taskC '2026-08-21T10:00:00.000Z' 5 '重构' 'custom'   # <10，不列出
        $tasks5 = @(Get-CctTasks -Root $script:proj -MinUserMsgs 10 -ExcludePatterns @('ConfigBackup'))
        $s = @($tasks5 | Where-Object { $_.Kind -eq 'Session' -and $_.Name -eq '重构' })
        $s.Count | Should -Be 2
        @($s | ForEach-Object SessionId | Sort-Object) | Should -Be @('e1', 'e2')   # 各列一条，含较旧但达标的 e1
        # 过滤链路去重键并入 SessionId：同名两条经 Query 过滤后仍各自保留（不被 Kind|Path|Name 并成一条）
        $filtered = @(Filter-CctTasks -Tasks $tasks5 -Query '重构')
        @($filtered | Where-Object Kind -eq 'Session').Count | Should -Be 2
        @($filtered | ForEach-Object SessionId | Sort-Object) | Should -Be @('e1', 'e2')
    }
}

Describe '第十九轮：续接分叉折叠与目录升格' {
    BeforeAll {
        # 独立 fixture 目录（不与上面共享，避免既有断言相互干扰）。
        # 注意：分组键 = jsonl 内容首现 cwd（非物理存放目录），任务目录须真实存在（Directory.Exists 过滤）
        $script:forkDirA = Join-Path $script:tmpRoot 'forkDirA'
        $script:forkDirB = Join-Path $script:tmpRoot 'forkDirB'
        New-Item -ItemType Directory -Force $script:forkDirA, $script:forkDirB | Out-Null
        $script:proj19 = Join-Path $script:tmpRoot 'projects19'
        New-Item -ItemType Directory -Force "$script:proj19\E---forkA---", "$script:proj19\E---forkB---" | Out-Null

        # 带血缘的 fixture：jsonl 内历史行携带「蛇形 session_id 指向祖先」
        function New-ForkJsonl {
            param([string]$Dir, [string]$SessionId, [string]$Cwd, [string]$Ts, [int]$Msgs, [string]$Title, [string[]]$AncestorIds)
            $cwdJson = $Cwd -replace '\\', '\\'
            $lines = [System.Collections.Generic.List[string]]::new()
            if ($Title) {
                $lines.Add(('{"type":"custom-title","customTitle":"' + $Title + '","sessionId":"' + $SessionId + '"}'))
            }
            foreach ($a in $AncestorIds) {
                # 祖先复制历史：真实 CC 分叉文件里历史行 message 层带蛇形 session_id 指向祖先
                $lines.Add(('{"parentUuid":null,"type":"user","cwd":"' + $cwdJson + '","timestamp":"' + $Ts + '","session_id":"' + $a + '","message":{"role":"user","content":"history"},"uuid":"h-' + $a + '"}'))
            }
            for ($i = 1; $i -le $Msgs; $i++) {
                $lines.Add(('{"type":"user","cwd":"' + $cwdJson + '","timestamp":"' + $Ts + '","message":{"role":"user","content":"m' + $i + '"},"uuid":"u' + $i + '","parentUuid":null}'))
            }
            [System.IO.File]::WriteAllLines((Join-Path $Dir "$SessionId.jsonl"), $lines, [System.Text.UTF8Encoding]::new($false))
        }

        # forkA：祖先 old（12 条，达标）+ 后代 new（13 条达标，血缘指向 old）→ 只列 new，old 被折叠。
        # 血缘判据两个硬条件：id 与祖先文件名（SessionId）一致 + GUID 形态（V5 校验）→ fixture 全用 GUID
        $script:aidOld = '11111111-2222-3333-4444-555555555555'
        $script:sidNew = '22222222-3333-4444-5555-666666666666'
        New-ForkJsonl "$script:proj19\E---forkA---" $script:aidOld $script:forkDirA '2026-08-25T10:00:00.000Z' 12 '分叉祖先' @()
        New-ForkJsonl "$script:proj19\E---forkA---" $script:sidNew $script:forkDirA '2026-08-28T10:00:00.000Z' 13 '分叉祖先' @($script:aidOld)
        # forkB：续接碎片（全部 <10 条、同标题「账号调优」）→ 全被阈值过滤 →
        # 目录升格：最新且 ≥1 真实消息的碎片（f2）升格为会话卡，标题与进入后一致
        $script:sidF1 = '33333333-4444-5555-6666-777777777777'
        $script:sidF2 = '44444444-5555-6666-7777-888888888888'
        New-ForkJsonl "$script:proj19\E---forkB---" $script:sidF1 $script:forkDirB '2026-09-04T02:00:00.000Z' 2 '账号调优' @()
        New-ForkJsonl "$script:proj19\E---forkB---" $script:sidF2 $script:forkDirB '2026-09-07T02:00:00.000Z' 1 '账号调优' @($script:sidF1)
        New-ForkJsonl "$script:proj19\E---forkB---" 'f0' $script:forkDirB '2026-09-03T02:00:00.000Z' 0 '账号调优' @()

        $script:tasks19 = @(Get-CctTasks -Root $script:proj19 -MinUserMsgs 10 -ExcludePatterns @('ConfigBackup'))
    }

    It '分叉折叠：后代达标时祖先不单独列出，只留对话链最新端点（bug 1：同标题同路径只出一张卡）' {
        $s = @($script:tasks19 | Where-Object { $_.Kind -eq 'Session' -and $_.GroupKey -eq $script:forkDirA })
        $s.Count | Should -Be 1
        $s[0].SessionId | Should -Be $script:sidNew
    }
    It '祖先折叠不误伤独立会话：无血缘的不同目录同名会话不受影响' {
        # 主 fixture（proj）的 taskA 三条会话不在 proj19 扫描范围内（proj19 只含 forkA/forkB 编码目录），
        # 「不误伤」的正向验证 = 既有 18 用例全过（无血缘会话行为不变）；这里断言 forkA 组折叠后仅剩 new
        $s = @($script:tasks19 | Where-Object { $_.Kind -eq 'Session' -and $_.GroupKey -eq $script:forkDirA })
        $s.Count | Should -Be 1
        $s[0].SessionId | Should -Be $script:sidNew
    }
    It '目录升格：纯碎片目录（全部 <阈值）的最新有标题会话升格为会话卡（bug 2：标题与进入后一致）' {
        $s = @($script:tasks19 | Where-Object { $_.Kind -eq 'Session' -and $_.GroupKey -eq $script:forkDirB })
        $s.Count | Should -Be 1
        $s[0].SessionId | Should -Be $script:sidF2
        $s[0].Name | Should -Be '账号调优'
        $s[0].TitleType | Should -Be '自定义命名'
    }
    It '目录升格后 folder 头被既有逻辑滤除（同组有会话项）' {
        @($script:tasks19 | Where-Object { $_.Kind -eq 'Folder' -and $_.GroupKey -eq $script:forkDirB }).Count | Should -Be 0
    }
    It '无标题碎片不升格：目录只剩无标题 <阈值 碎片时仍保留 folder 头（决策 37 语义不变）' {
        $script:proj19b = Join-Path $script:tmpRoot 'projects19b'
        New-Item -ItemType Directory -Force "$script:proj19b\E---forkC---" | Out-Null
        New-ForkJsonl "$script:proj19b\E---forkC---" 'g1' $script:forkDirA '2026-09-01T02:00:00.000Z' 2 $null @()
        $tasks19b = @(Get-CctTasks -Root $script:proj19b -MinUserMsgs 10 -ExcludePatterns @())
        @($tasks19b | Where-Object { $_.Kind -eq 'Session' }).Count | Should -Be 0
        $f = @($tasks19b | Where-Object { $_.Kind -eq 'Folder' })
        $f.Count | Should -Be 1
        $f[0].GroupKey | Should -Be $script:forkDirA
    }
}

