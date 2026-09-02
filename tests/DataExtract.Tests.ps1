BeforeAll {
    . "$PSScriptRoot\..\ClaudeCodeTask\Data.ps1"
    $script:tmp = Join-Path $env:TEMP ("cct_test_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $script:tmp | Out-Null

    function New-TestJsonl {
        param([string]$SessionId, [string[]]$Lines)
        $path = Join-Path $script:tmp "$SessionId.jsonl"
        [System.IO.File]::WriteAllLines($path, $Lines, [System.Text.UTF8Encoding]::new($false))
        return $path
    }
}
AfterAll {
    if (Test-Path $script:tmp) { Remove-Item -Recurse -Force $script:tmp }
}

Describe 'Read-CctSessionFile 字段提取' {
    It 'cwd 取最后一条（发现 15：会话中途会变）' {
        $p = New-TestJsonl 's-cwd' @(
            '{"type":"user","cwd":"C:\\old","timestamp":"2026-08-27T01:00:00.000Z","message":{"role":"user","content":"a"},"uuid":"u1","parentUuid":null}',
            '{"type":"user","cwd":"C:\\new","timestamp":"2026-08-27T02:00:00.000Z","message":{"role":"user","content":"b"},"uuid":"u2","parentUuid":"u1"}'
        )
        $r = Read-CctSessionFile $p
        $r.Cwd | Should -Be 'C:\new'
    }
    It 'StartCwd 取第一条（第九轮：jsonl 首现 cwd = 会话启动/存储目录，用于分组键）' {
        $p = New-TestJsonl 's-startcwd' @(
            '{"type":"user","cwd":"C:\\start","timestamp":"2026-08-27T01:00:00.000Z","message":{"role":"user","content":"a"},"uuid":"u1","parentUuid":null}',
            '{"type":"user","cwd":"C:\\later","timestamp":"2026-08-27T02:00:00.000Z","message":{"role":"user","content":"b"},"uuid":"u2","parentUuid":"u1"}'
        )
        $r = Read-CctSessionFile $p
        $r.StartCwd | Should -Be 'C:\start'
    }
    It 'LastTimestamp 取最后一条 timestamp（UTC）' {
        $p = New-TestJsonl 's-ts' @(
            '{"type":"user","cwd":"C:\\t","timestamp":"2026-08-27T01:00:00.000Z","message":{"role":"user","content":"a"},"uuid":"u1","parentUuid":null}',
            '{"type":"user","cwd":"C:\\t","timestamp":"2026-08-27T09:30:00.000Z","message":{"role":"user","content":"b"},"uuid":"u2","parentUuid":"u1"}'
        )
        $r = Read-CctSessionFile $p
        $r.LastTimestamp | Should -Be ([datetime]'2026-08-27 09:30:00')
    }
    It '标题优先级：custom-title 覆盖 ai-title，都取最后一条' {
        $p = New-TestJsonl 's-title' @(
            '{"type":"ai-title","aiTitle":"自动1","sessionId":"s-title"}',
            '{"type":"custom-title","customTitle":"手动1","sessionId":"s-title"}',
            '{"type":"custom-title","customTitle":"手动2","sessionId":"s-title"}'
        )
        $r = Read-CctSessionFile $p
        $r.Title | Should -Be '手动2'
        $r.TitleType | Should -Be 'custom'
    }
    It '只有 ai-title 时取 ai' {
        $p = New-TestJsonl 's-ai' @(
            '{"type":"ai-title","aiTitle":"git status概览","sessionId":"s-ai"}'
        )
        $r = Read-CctSessionFile $p
        $r.Title | Should -Be 'git status概览'
        $r.TitleType | Should -Be 'ai'
    }
    It 'UserMsgs：字符串 content 计 1，tool_result / isMeta / slash command 不计' {
        $p = New-TestJsonl 's-msgs' @(
            '{"type":"user","cwd":"C:\\t","timestamp":"2026-08-27T01:00:00.000Z","message":{"role":"user","content":"你好"},"uuid":"u1","parentUuid":null}',
            '{"type":"user","cwd":"C:\\t","timestamp":"2026-08-27T01:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"uuid":"u2","parentUuid":"u1"}',
            '{"type":"user","isMeta":true,"cwd":"C:\\t","timestamp":"2026-08-27T01:00:02.000Z","message":{"role":"user","content":"meta"},"uuid":"u3","parentUuid":"u2"}',
            '{"type":"user","cwd":"C:\\t","timestamp":"2026-08-27T01:00:03.000Z","message":{"role":"user","content":"/clear"},"uuid":"u4","parentUuid":"u3"}',
            '{"type":"user","cwd":"C:\\t","timestamp":"2026-08-27T01:00:04.000Z","message":{"role":"user","content":[{"type":"text","text":"真实消息"}]},"uuid":"u5","parentUuid":"u4"}'
        )
        $r = Read-CctSessionFile $p
        $r.UserMsgs | Should -Be 2
        $r.HasRealUserMsg | Should -BeTrue
    }
    It 'HasRealUserMsg=false：只有 /clear 空壳和 tool_result（发现 22 的坑）' {
        $p = New-TestJsonl 's-empty' @(
            '{"type":"custom-title","customTitle":"在线设计文件","sessionId":"s-empty"}',
            '{"type":"mode","sessionId":"s-empty"}',
            '{"type":"user","cwd":"C:\\t","timestamp":"2026-08-27T01:00:00.000Z","message":{"role":"user","content":"/clear"},"uuid":"u1","parentUuid":null}'
        )
        $r = Read-CctSessionFile $p
        $r.UserMsgs | Should -Be 0
        $r.HasRealUserMsg | Should -BeFalse
    }
    It '全量扫描（第四轮修复）：LastTimestamp 取真实最后一行，不卡在第 10 条用户消息' {
        # 旧早停缺陷：b8c4b9b3 实测显示 08-25，实际活动到 08-31——早停点之后的时间戳全部丢
        $lines = for ($i = 1; $i -le 15; $i++) {
            '{"type":"user","cwd":"C:\\t","timestamp":"2026-08-27T01:00:00.000Z","message":{"role":"user","content":"m' + $i + '"},"uuid":"u' + $i + '","parentUuid":null}'
        }
        # 末尾放更晚的活动时间（早停版读不到，全量扫描必须读到）
        $lines += '{"type":"user","cwd":"C:\\t","timestamp":"2026-12-31T23:59:59.000Z","message":{"role":"user","content":"late"},"uuid":"uX","parentUuid":null}'
        $p = New-TestJsonl 's-full' $lines
        $r = Read-CctSessionFile $p
        $r.UserMsgs | Should -BeExactly 16
        $r.LastTimestamp | Should -Be ([datetime]'2026-12-31 23:59:59')
    }
    It '尾部标题能读到（cc-switch 发现：标题行几乎总在文件尾部，早停必丢）' {
        $lines = @( '{"type":"ai-title","aiTitle":"旧标题","sessionId":"s-tail"}' )
        $lines += for ($i = 1; $i -le 12; $i++) {
            '{"type":"user","cwd":"C:\\design","timestamp":"2026-08-27T01:00:00.000Z","message":{"role":"user","content":"m' + $i + '"},"uuid":"u' + $i + '","parentUuid":null}'
        }
        $lines += '{"type":"custom-title","customTitle":"尾部标题","sessionId":"s-tail"}'
        $p = New-TestJsonl 's-tail' $lines
        $r = Read-CctSessionFile $p
        $r.Title | Should -Be '尾部标题'
        $r.UserMsgs | Should -BeExactly 12
    }
    It '伪用户消息不计（cc-switch 吸收：caveat/command-name 是系统注入，不是真实输入）' {
        $p = New-TestJsonl 's-fake' @(
            '{"type":"user","cwd":"C:\\t","timestamp":"2026-08-27T01:00:00.000Z","message":{"role":"user","content":"<local-command-caveat>Caveat: The messages below were generated by the user while running local commands.</local-command-caveat>"},"uuid":"u1","parentUuid":null}',
            '{"type":"user","cwd":"C:\\t","timestamp":"2026-08-27T01:00:01.000Z","message":{"role":"user","content":"<command-name>/clear</command-name>"},"uuid":"u2","parentUuid":"u1"}',
            '{"type":"user","cwd":"C:\\t","timestamp":"2026-08-27T01:00:02.000Z","message":{"role":"user","content":"真实"},"uuid":"u3","parentUuid":"u2"}'
        )
        $r = Read-CctSessionFile $p
        $r.UserMsgs | Should -Be 1
        $r.HasRealUserMsg | Should -BeTrue
    }
    It '头部字段（标题在首行）全量扫描同样兼容' {
        $lines = @( '{"type":"custom-title","customTitle":"在线设计文件","sessionId":"s-stop2"}' )
        $lines += for ($i = 1; $i -le 12; $i++) {
            '{"type":"user","cwd":"C:\\design","timestamp":"2026-08-27T01:00:00.000Z","message":{"role":"user","content":"m' + $i + '"},"uuid":"u' + $i + '","parentUuid":null}'
        }
        $p = New-TestJsonl 's-stop2' $lines
        $r = Read-CctSessionFile $p
        $r.Title | Should -Be '在线设计文件'
        $r.Cwd | Should -Be 'C:\design'
    }
    It '空文件 / 全损坏行不抛异常，返回 null 字段' {
        $p = New-TestJsonl 's-broken' @('not json', '{"type":"user"')
        $r = Read-CctSessionFile $p
        $r | Should -Not -BeNullOrEmpty
        $r.Cwd | Should -BeNullOrEmpty
        $r.UserMsgs | Should -Be 0
    }
}
