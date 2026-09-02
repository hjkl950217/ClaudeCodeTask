BeforeAll {
    . "$PSScriptRoot\..\ClaudeCodeTask\Data.ps1"
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

    It '输出 taskA 文件夹项（手动命名项目录）' {
        $f = $script:tasks | Where-Object { $_.Kind -eq 'Folder' -and $_.Path -eq $script:taskA }
        $f | Should -Not -BeNullOrEmpty
        $f.Name | Should -Be 'taskA'
    }
    It 'taskA 副标题 = 最近会话标题（a2 账号调优最新）' {
        ($script:tasks | Where-Object { $_.Kind -eq 'Folder' -and $_.Path -eq $script:taskA }).Subtitle | Should -Be '账号调优'
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
        $sessions[0].TitleType | Should -Be 'ai'
    }
    It 'taskC 副标题 = c2 的标题（最近会话，尽管它是空壳但有标题）' {
        ($script:tasks | Where-Object { $_.Kind -eq 'Folder' -and $_.Path -eq $script:taskC }).Subtitle | Should -Be '整理用量接口'
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
    It '排序：文件夹按最近活动降序，会话项紧跟所属文件夹（决策 15）' {
        # taskA 最近活动 08-27（a2），taskC 08-27（c2 09:00，c9 已删除不计），taskB 08-20
        # taskA(08-27T10:00) > taskC(08-27T09:00) > taskB(08-20)
        $folders = @($script:tasks | Where-Object Kind -eq 'Folder')
        $folders[0].Path | Should -Be $script:taskA
        $folders[1].Path | Should -Be $script:taskC
        $folders[2].Path | Should -Be $script:taskB
        # taskA 的会话项紧跟其后：索引 1 = 账号调优（组内最新），索引 2 = codex伪装，索引 3 = 中途切换（最早）
        $script:tasks[1].Name | Should -Be '账号调优'
        $script:tasks[2].Name | Should -Be 'codex伪装'
        $script:tasks[3].Name | Should -Be '中途切换'
        $script:tasks[4].Kind | Should -Be 'Folder'   # 下一个是 taskC
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
    It '决策 34 修订：手动组内全部文件 <阈值 → 整组不保留（不防御回退）' {
        New-TestJsonl "$script:proj\E---taskB---" 'b2' $script:taskB '2026-08-26T10:00:00.000Z' 2 '小会话' 'custom'
        $tasks4 = @(Get-CctTasks -Root $script:proj -MinUserMsgs 10 -ExcludePatterns @('ConfigBackup'))
        ($tasks4 | Where-Object { $_.Kind -eq 'Session' -and $_.Name -eq '小会话' }) | Should -BeNullOrEmpty
    }
}
