# 本机真实数据回归测试（不可在别的机器复现，仅验证设计文档实测结论的实现一致性）
BeforeAll {
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Data.ps1"
}

Describe '真实数据回归（spec 9）' {
    It '全库扫描 < 8 秒（设计预期 ~3.2 秒，留余量）' {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $script:tasks = @(Get-CctTasks)
        $sw.Stop()
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 8
    }
    It '列表规模在 20-80 项之间（设计结论 ≈39 项）' {
        $script:tasks.Count | Should -BeGreaterThan 20
        $script:tasks.Count | Should -BeLessThan 80
    }
    It '文件夹项全部存在且非 worktree' {
        $folders = @($script:tasks | Where-Object Kind -eq 'Folder')
        $folders.Count | Should -BeGreaterThan 10
        foreach ($f in $folders) {
            $f.Path | Should -Not -Match 'worktrees'
            (Test-Path -LiteralPath $f.Path) | Should -BeTrue
        }
    }
    It '每个会话项的 SessionId 对应的文件存在且有 ≥1 条真实用户消息（发现 22 空壳防护）' {
        $projRoot = Join-Path $env:USERPROFILE '.claude\projects'
        $sessions = @($script:tasks | Where-Object Kind -eq 'Session')
        $sessions.Count | Should -BeGreaterThan 3
        foreach ($s in $sessions) {
            $file = Get-ChildItem -LiteralPath $projRoot -Recurse -Filter "$($s.SessionId).jsonl" -File | Select-Object -First 1
            $file | Should -Not -BeNullOrEmpty
            $r = Read-CctSessionFile $file.FullName
            $r.HasRealUserMsg | Should -BeTrue
        }
    }
    It '排序单调：文件夹项按 LastActive 降序' {
        $folders = @($script:tasks | Where-Object Kind -eq 'Folder')
        for ($i = 1; $i -lt $folders.Count; $i++) {
            $folders[$i].LastActive | Should -BeLessThan ($folders[$i-1].LastActive.AddSeconds(1))
        }
    }
}

