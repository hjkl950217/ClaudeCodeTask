# 第十三轮：增量缓存测试——文件数 ≥ 拐点时的缓存复用/变更检测
BeforeAll {
    . "$PSScriptRoot\..\cct\Data.ps1"
    $script:CctCacheMinFiles = 2   # 覆盖拐点：2 个文件即触发缓存路径（真实拐点 20，测试用独立小树）
    $script:tmpRoot = Join-Path $env:TEMP ("cct_cache_" + [guid]::NewGuid().ToString('N'))
    $script:proj = Join-Path $script:tmpRoot 'projects'
    $script:taskA = Join-Path $script:tmpRoot 'taskA'
    New-Item -ItemType Directory -Force "$script:proj\E---taskA---", $script:taskA | Out-Null
    $script:cachePath = Join-Path $script:tmpRoot 'cache.json'

    function New-TestJsonl([string]$Name, [int]$Msgs, [string]$Ts, [string]$Title) {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add(('{"type":"custom-title","customTitle":"' + $Title + '","sessionId":"' + $Name + '"}'))
        $cwdJson = $script:taskA -replace '\\', '\\'
        for ($i = 1; $i -le $Msgs; $i++) {
            $lines.Add(('{"type":"user","cwd":"' + $cwdJson + '","timestamp":"' + $Ts + '","message":{"role":"user","content":"m' + $i + '"},"uuid":"u' + $i + '","parentUuid":null}'))
        }
        [System.IO.File]::WriteAllLines((Join-Path "$script:proj\E---taskA---" "$Name.jsonl"), $lines, [System.Text.UTF8Encoding]::new($false))
    }
    New-TestJsonl 'a1' 12 '2026-08-25T10:00:00.000Z' '缓存会话A'
    New-TestJsonl 'a2' 15 '2026-08-26T10:00:00.000Z' '缓存会话B'
}
AfterAll {
    if (Test-Path $script:tmpRoot) { Remove-Item -Recurse -Force $script:tmpRoot }
}

Describe '增量缓存（第十三轮）' {
    BeforeAll {
        # 首次调用：无缓存 → 全量扫描 + 写缓存（文件数 ≥ 拐点）
        $script:t1 = @(Get-CctTasks -Root $script:proj -MinUserMsgs 10 -ExcludePatterns @() -CachePath $script:cachePath)
    }

    It '文件数 ≥ 拐点：首次全量后写缓存（2 条记录）' {
        Test-Path -LiteralPath $script:cachePath | Should -Be $true
        $cache = Get-Content -LiteralPath $script:cachePath -Raw | ConvertFrom-Json
        $cache.version | Should -Be 1
        @($cache.files.PSObject.Properties).Count | Should -Be 2
        foreach ($p in $cache.files.PSObject.Properties) {
            $p.Value.mt | Should -Not -BeNullOrEmpty
            $p.Value.sz | Should -BeGreaterThan 0
            @($p.Value.raw).Count | Should -Be 6   # [firstCwd,lastCwd,lastTs,title,titleType,userMsgs]
        }
    }

    It '文件未变：第二次走缓存，结果与首次一致' {
        $t2 = @(Get-CctTasks -Root $script:proj -MinUserMsgs 10 -ExcludePatterns @() -CachePath $script:cachePath)
        $t2.Count | Should -Be $script:t1.Count
        for ($i = 0; $i -lt $t2.Count; $i++) {
            $t2[$i].SessionId | Should -Be $script:t1[$i].SessionId
            $t2[$i].Name | Should -Be $script:t1[$i].Name
            $t2[$i].Path | Should -Be $script:t1[$i].Path
        }
    }

    It '文件变化（追加消息）→ 重扫该文件，结果反映新数据' {
        # a1 追加一条新 user 消息（新时间戳 → 该会话最新活动更新）
        $path = Join-Path "$script:proj\E---taskA---" 'a1.jsonl'
        Add-Content -LiteralPath $path -Encoding utf8 -Value ('{"type":"user","cwd":"' + ($script:taskA -replace '\\', '\\') + '","timestamp":"2026-08-30T09:00:00.000Z","message":{"role":"user","content":"new"},"uuid":"unew","parentUuid":null}')
        $t3 = @(Get-CctTasks -Root $script:proj -MinUserMsgs 10 -ExcludePatterns @() -CachePath $script:cachePath)
        $folder = $t3 | Where-Object { $_.Kind -eq 'Folder' -and $_.Path -eq $script:taskA }
        $folder | Should -Not -BeNullOrEmpty
        $folder.LastActive | Should -Be ([datetime]'2026-08-30 17:00:00')   # 09:00Z + 8h
        # 缓存已更新：a1 的 userMsgs 12 → 13
        $cache = Get-Content -LiteralPath $script:cachePath -Raw | ConvertFrom-Json
        $a1 = $cache.files.PSObject.Properties | Where-Object Name -like '*a1.jsonl'
        $a1.Value.raw[5] | Should -Be '13'
    }

    It '文件 < 拐点时不读写缓存（少量会话保持原行为）' {
        $origMin = $script:CctCacheMinFiles
        try {
            $script:CctCacheMinFiles = 999   # 拐点抬到无文件能触发
            Remove-Item -LiteralPath $script:cachePath -Force -ErrorAction SilentlyContinue
            [void](Get-CctTasks -Root $script:proj -MinUserMsgs 10 -ExcludePatterns @() -CachePath $script:cachePath)
            Test-Path -LiteralPath $script:cachePath | Should -Be $false
        } finally {
            $script:CctCacheMinFiles = $origMin
        }
    }
}