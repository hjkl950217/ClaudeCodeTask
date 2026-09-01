# Launcher 三级降级链 + stderr 捕获 + Ctrl+C 中断语义（三轮反馈 3-1/3-2/3-3/3-4/3-5）
# fixture：tests/fixtures/fake-claude.ps1（CCT_TEST_FAKE 序列控制退出码序列）
# 注意：测试会改当前目录（Invoke-CctTask 真切目录），AfterAll 恢复

BeforeAll {
    . "$PSScriptRoot\..\cct\Display.ps1"
    . "$PSScriptRoot\..\cct\Spinner.ps1"
    . "$PSScriptRoot\..\cct\Launcher.ps1"

    $script:tmp = Join-Path $env:TEMP ("cct_launch3_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $script:tmp | Out-Null
    $script:fixture = "$PSScriptRoot\fixtures\fake-claude.ps1"
    $script:cfg = [pscustomobject]@{
        launchCommand = "pwsh -NoProfile -File `"$script:fixture`" -Mode ok"
        resumeCommand = "pwsh -NoProfile -File `"$script:fixture`" -Mode marker -Token resume:{sessionId}"
    }
    $script:origLoc = Get-Location
    $script:fakeDir = Join-Path $env:TEMP 'cct_fake'
}
AfterAll {
    Set-Location $script:origLoc
    if (Test-Path $script:tmp) { Remove-Item -Recurse -Force $script:tmp }
    Remove-Item Env:CCT_TEST_FAKE -ErrorAction SilentlyContinue
    if (Test-Path $script:fakeDir) { Remove-Item -Recurse -Force $script:fakeDir }
}

Describe 'Invoke-CctTask 三级降级链（反馈 3-1）' {
    BeforeEach {
        if (Test-Path $script:fakeDir) { Remove-Item -Recurse -Force $script:fakeDir }
    }
    It 'L1 成功：直接返回，Started=true，命令含 sessionId' {
        $item = [pscustomobject]@{ Kind='Session'; Path=$script:tmp; Name='x'; SessionId='sid-1' }
        $r = Invoke-CctTask $item $script:cfg
        $r.Started | Should -BeTrue
        $r.Interrupted | Should -BeNullOrEmpty
        $log = Get-Content (Join-Path $script:fakeDir 'log.txt') -Raw
        $log | Should -Match 'resume:sid-1'
    }
    It 'L1 失败 → L2 -c 成功：两次调用，第二次是 launchCommand' {
        $env:CCT_TEST_FAKE = 'fail,ok'
        $item = [pscustomobject]@{ Kind='Session'; Path=$script:tmp; Name='x'; SessionId='sid-1' }
        $r = Invoke-CctTask $item $script:cfg
        $r.Started | Should -BeTrue
        $lines = @((Get-Content (Join-Path $script:fakeDir 'log.txt')) | Where-Object { $_ })
        $lines.Count | Should -Be 2
        $lines[1] | Should -Match '-Mode:ok'      # 第二次调用走 launchCommand 模板
    }
    It 'L1、L2 失败 → L3 带 prompt 成功：第三条命令带「继续」' {
        $env:CCT_TEST_FAKE = 'fail,fail,ok'
        $item = [pscustomobject]@{ Kind='Session'; Path=$script:tmp; Name='x'; SessionId='sid-1' }
        $r = Invoke-CctTask $item $script:cfg
        $r.Started | Should -BeTrue
        $lines = @((Get-Content (Join-Path $script:fakeDir 'log.txt')) | Where-Object { $_ })
        $lines.Count | Should -Be 3
        $lines[2] | Should -Match '继续'
    }
    It '三级全失败：Started=false，Command 是 L3 兜底命令' {
        $env:CCT_TEST_FAKE = 'fail,fail,fail'
        $item = [pscustomobject]@{ Kind='Session'; Path=$script:tmp; Name='x'; SessionId='sid-1' }
        $r = Invoke-CctTask $item $script:cfg
        $r.Started | Should -BeFalse
        $r.Command | Should -Match '继续'
    }
    It 'L1 被用户 Ctrl+C 中断（exit 130）：不降级静默返回' {
        $env:CCT_TEST_FAKE = 'interrupt'
        $item = [pscustomobject]@{ Kind='Session'; Path=$script:tmp; Name='x'; SessionId='sid-1' }
        $r = Invoke-CctTask $item $script:cfg
        $r.Started | Should -BeTrue
        $r.Interrupted | Should -BeTrue
        (Get-Content (Join-Path $script:fakeDir 'count.txt') -Raw).Trim() | Should -Be '1'
    }
    It 'L2 被中断：不继续降级' {
        $env:CCT_TEST_FAKE = 'fail,interrupt'
        $item = [pscustomobject]@{ Kind='Session'; Path=$script:tmp; Name='x'; SessionId='sid-1' }
        $r = Invoke-CctTask $item $script:cfg
        $r.Started | Should -BeTrue
        $r.Interrupted | Should -BeTrue
        (Get-Content (Join-Path $script:fakeDir 'count.txt') -Raw).Trim() | Should -Be '2'
    }
}

Describe 'Invoke-CctClaude stderr 捕获（反馈 3-1 显示错乱根治）' {
    BeforeEach {
        Remove-Item Env:CCT_TEST_FAKE -ErrorAction SilentlyContinue
        if (Test-Path $script:fakeDir) { Remove-Item -Recurse -Force $script:fakeDir }
    }
    It '子进程 stderr 被捕获重放：退出码正确返回' {
        $cmd = "pwsh -NoProfile -File `"$script:fixture`" -Mode stderrfail"
        $exit = Invoke-CctClaude $cmd '测试'
        $exit | Should -Be 1
    }
    It '成功时无 stderr：退出码 0' {
        $cmd = "pwsh -NoProfile -File `"$script:fixture`" -Mode ok"
        $exit = Invoke-CctClaude $cmd '测试'
        $exit | Should -Be 0
    }
    It 'headless 污染防护：子进程 stdout 大量输出时退出码仍是 int（三轮实测 bug）' {
        # 用户终端实况：claude headless 跑时回复文本流经管道污染函数返回值，
        # if(@(文本,0)) 解包判 0 为 falsy → L3 实际成功却误报失败。
        # 现在要求：stdout 被丢弃，返回值必须是 Int32 的 0
        $headless = "Write-Output '长空，这是一段回复文本。'; exit 0"
        $cmd = "pwsh -NoProfile -Command `"$headless`""
        $exit = Invoke-CctClaude $cmd '测试'
        $exit | Should -BeExactly 0
        $exit | Should -BeOfType [int]
    }
}

Describe 'Invoke-CctClaude Start-Process 直启（第四轮根因修复：headless 化）' {
    # 根因（2026-09-01 探针矩阵实锤）：任何形式的输出捕获（$null = / 管道 / 上层赋值）都会
    # 给子进程挂 stdout 管道 → claude 检测非 TTY → headless print 模式 → 无 prompt 报
    # "No deferred tool marker found"。修复：Start-Process 直启，stdout 继承控制台。
    BeforeEach {
        Remove-Item Env:CCT_TEST_FAKE -ErrorAction SilentlyContinue
        if (Test-Path $script:fakeDir) { Remove-Item -Recurse -Force $script:fakeDir }
    }
    It '退出码透传：非 0/1 特殊值（42）原样返回且为 int' {
        $cmd = 'pwsh -NoProfile -Command "exit 42"'
        $exit = Invoke-CctClaude $cmd '测试'
        $exit | Should -Be 42
        $exit | Should -BeOfType [int]
    }
    It '带引号参数的命令拆分：-File 路径含引号与空格仍正确执行' {
        # launchCommand 模板真实形态：pwsh -NoProfile -File "C:\path with space\x.ps1" -Mode ok
        $cmd = "pwsh -NoProfile -File `"$script:fixture`" -Mode ok"
        $exit = Invoke-CctClaude $cmd '测试'
        $exit | Should -Be 0
        # fake-claude ok 模式会写日志到 %TEMP%\cct_fake
        (Test-Path (Join-Path $script:fakeDir 'log.txt')) | Should -BeTrue
    }
    It 'L3 兜底 prompt 双引号内联：命令串里 prompt 用双引号包裹（Windows argv 规则）' {
        $s = [pscustomobject]@{ Kind='Session'; Path=$script:tmp; Name='x'; SessionId='sid-9' }
        # DryRun 走降级链拼装路径吗？不——DryRun 只返回 L1。直接测全失败后的 Command 拼装：
        $env:CCT_TEST_FAKE = 'fail,fail,fail'
        $r = Invoke-CctTask $s $script:cfg
        $r.Started | Should -BeFalse
        # L3 兜底命令：prompt 必须是双引号形态（单引号在 Windows argv 不剥壳，claude 会收到字面 '继续'）
        $r.Command | Should -Match '"继续"'
    }
}

Describe 'spinner 文本与命令拼装（反馈 3-2）' {
    It '会话项 DryRun：Command 含 sessionId；文件夹项用 launchCommand' {
        $s = [pscustomobject]@{ Kind='Session'; Path=$script:tmp; Name='账号调优'; SessionId='s9' }
        $r = Invoke-CctTask $s $script:cfg -DryRun
        $r.Command | Should -Match 'resume:s9'
        $f = [pscustomobject]@{ Kind='Folder'; Path=$script:tmp; Name='dir'; SessionId=$null }
        $r2 = Invoke-CctTask $f $script:cfg -DryRun
        $r2.Command | Should -Match '-Mode ok'
    }
    It 'Get-CctSpinnerText：会话项=标题（父目录），文件夹项=目录名' {
        $s = [pscustomobject]@{ Kind='Session'; Path='E:\t\管理_sub2api'; Name='账号调优'; SessionId='s1' }
        Get-CctSpinnerText $s | Should -Be '正在启动会话：[账号调优（管理_sub2api）]'
        $f = [pscustomobject]@{ Kind='Folder'; Path='E:\t\管理_sub2api'; Name='管理_sub2api'; SessionId=$null }
        Get-CctSpinnerText $f | Should -Be '正在启动会话：[管理_sub2api]'
    }
}
