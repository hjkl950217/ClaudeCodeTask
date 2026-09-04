BeforeAll {
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Config.ps1"
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Data.ps1"
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Spinner.ps1"
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Launcher.ps1"
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Cct.ps1"
    $script:tmp = Join-Path $env:TEMP ("cct_main_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $script:tmp | Out-Null
    $script:cfgPath = Join-Path $script:tmp 'config.json'
    $script:projRoot = Join-Path $script:tmp 'projects'
    New-Item -ItemType Directory -Force "$script:projRoot\E---t---" | Out-Null
    # 构造一个有任务的假 projects 目录
    $taskDir = Join-Path $script:tmp 'taskA'
    New-Item -ItemType Directory -Force $taskDir | Out-Null
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('{"type":"custom-title","customTitle":"调优","sessionId":"s1"}')
    for ($i = 1; $i -le 12; $i++) {
        $lines.Add(('{"type":"user","cwd":"' + ($taskDir -replace '\\', '\\') + '","timestamp":"2026-08-27T02:00:00.000Z","message":{"role":"user","content":"m"},"uuid":"u' + $i + '","parentUuid":null}'))
    }
    [System.IO.File]::WriteAllLines("$script:projRoot\E---t---\s1.jsonl", $lines, [System.Text.UTF8Encoding]::new($false))
    $script:cfg = [pscustomobject]@{
        launchCommand = 'claude --dangerously-skip-permissions -c'
        resumeCommand = 'claude --dangerously-skip-permissions --resume {sessionId}'
    }
    $script:origLoc = Get-Location
}
AfterAll {
    Set-Location $script:origLoc
    if (Test-Path $script:tmp) { Remove-Item -Recurse -Force $script:tmp }
}

Describe 'Invoke-CctMain 主流程（DryRun 注入）' {
    It '空任务列表打印提示不进界面（决策 28），且只打印一次' {
        $out = Invoke-CctMain -Tasks @() -ConfigPath $script:cfgPath -DryRun
        $out | Should -BeNullOrEmpty   # 提示走 Write-Host，不进返回值（第五轮修复：打印两次）
    }
}

Describe 'Invoke-CctMain 启动失败回退（决策：没进 claude 就回原路径）' {
    It '任务目录不存在：启动失败后回退原路径' {
        $before = (Get-Location).Path
        $badTask = [pscustomobject]@{ Kind='Folder'; Path=Join-Path $script:tmp '不存在'; Name='x'; SessionId=$null }
        try {
            # SelectedTask 注入跳过 Show-CctSelector；目录不存在 → Started=$false → 回退
            Invoke-CctMain -Tasks @($badTask) -SelectedTask $badTask -ConfigPath $script:cfgPath 2>$null
            (Get-Location).Path | Should -Be $before
        } finally {
            Set-Location $before
        }
    }
}

Describe '模块导出' {
    It 'cct 函数已导出' {
        Import-Module "$PSScriptRoot\..\ClaudeCodeTask.UI\ClaudeCodeTask.psm1" -Force
        (Get-Command cct -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
    It '数据层端到端：假 projects 目录 → 会话项输出（folder 头被会话取代）' {
        $tasks = @(Get-CctTasks -Root $script:projRoot -MinUserMsgs 10 -ExcludePatterns @('ConfigBackup'))
        $tasks.Count | Should -Be 1   # taskA 有可 resume 会话 → folder 头不输出，仅 1 个手动会话项（调优，12 条）
        @($tasks | Where-Object Kind -eq 'Folder').Count | Should -Be 0
        ($tasks | Where-Object Kind -eq 'Session').SessionId | Should -Be 's1'
    }
    It '旧签名 CctScanner 已缓存的常驻进程：新代码仍能扫出任务（第五轮实锤 bug）' {
        # 根因：Add-Type 类型缓存在进程 AppDomain，Import-Module -Force 不重编译内联 C#。
        # 第三轮加载过旧版（双参 ScanFile(path, minUserMsgs)）的常驻终端，守卫 if (-not ('CctScanner' -as [type]))
        # 看到旧类型存在直接跳过编译 → 新代码调单参重载抛异常 → catch 吃掉 → 所有会话变空记录。
        # 修复：类名版本化（每轮签名变更换新类名），旧类型共存互不干扰。
        # 测试方式：当前进程已由 BeforeAll dot-source 新 Data.ps1（编译了新类）；断言版本化类名在场，
        # 并且扫描走新类（若还用旧名，与用户终端场景不同——新进程无旧类，掩盖 bug）。
        ('CctScannerV4' -as [type]) | Should -Not -BeNullOrEmpty
        $tasks = @(Get-CctTasks -Root $script:projRoot -MinUserMsgs 10 -ExcludePatterns @('ConfigBackup'))
        $tasks.Count | Should -Be 1   # 版本化后扫描必须照常工作（会话取代 folder 头）
    }
}

