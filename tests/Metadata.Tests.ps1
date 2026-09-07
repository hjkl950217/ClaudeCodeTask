# 集中元数据（build-metadata.json）一致性测试：版本号/域名/发版说明只编辑元数据文件，
# psd1 由盖章函数自动派生。本测试守卫两者一致——单改 psd1 或元数据未盖章都会红。
BeforeAll {
    . "$PSScriptRoot\..\StampMetadata.ps1"
    $script:metaPath = Join-Path $PSScriptRoot '..\build-metadata.json'
    $script:psd1Path = Join-Path $PSScriptRoot '..\ClaudeCodeTask.UI\ClaudeCodeTask.psd1'
    $script:meta = Read-CctBuildMetadata -MetadataPath $script:metaPath
    $script:tmp = Join-Path $env:TEMP ("cct_meta_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $script:tmp | Out-Null

    function New-FixturePsd1 {
        # 迷你 psd1 fixture（CRLF 换行，与真实清单同构）
        $lines = @(
            '@{',
            '    RootModule           = ''ClaudeCodeTask.psm1''',
            '    ModuleVersion        = ''0.9.9''',
            '    Description          = ''测试清单''',
            '    PrivateData          = @{',
            '        PSData = @{',
            '            LicenseUri   = ''https://example.com/old/blob/main/LICENSE''',
            '            ProjectUri   = ''https://example.com/old''',
            '            ReleaseNotes = ''0.9.9：旧说明''',
            '        }',
            '    }',
            '}'
        )
        $p = Join-Path $script:tmp 'fixture.psd1'
        [System.IO.File]::WriteAllText($p, ($lines -join "`r`n") + "`r`n", [System.Text.UTF8Encoding]::new($false))
        return $p
    }
    function New-FixtureMeta {
        $p = Join-Path $script:tmp 'fixture.json'
        @{
            version      = '1.2.3'
            projectUri   = 'https://example.com/new'
            licenseUri   = 'https://example.com/new/blob/main/LICENSE'
            releaseNotes = '1.2.3：新说明'
            buildProxy   = 'http://127.0.0.1:10193'
        } | ConvertTo-Json | Set-Content -LiteralPath $p -Encoding utf8
        return $p
    }
}
AfterAll {
    if (Test-Path $script:tmp) { Remove-Item -Recurse -Force $script:tmp }
}

Describe 'build-metadata.json 集中元数据' {
    It '字段齐全且形态合法（Read-CctBuildMetadata 校验通过）' {
        $script:meta | Should -Not -BeNullOrEmpty
        $script:meta.version | Should -Match '^\d+\.\d+\.\d+(\.\d+)?$'
        $script:meta.projectUri | Should -BeLike 'https://*'
        $script:meta.licenseUri | Should -BeLike 'https://*'
        $script:meta.releaseNotes | Should -Not -BeNullOrEmpty
        $script:meta.buildProxy | Should -Not -BeNullOrEmpty
    }
    It 'psd1 与集中元数据一致（防漂移守卫：改版本号只改 build-metadata.json，同步时自动盖章进 psd1）' {
        $psd1 = Import-PowerShellDataFile -LiteralPath $script:psd1Path
        $psd1.ModuleVersion | Should -Be $script:meta.version
        $psd1.PrivateData.PSData.ProjectUri | Should -Be $script:meta.projectUri
        $psd1.PrivateData.PSData.LicenseUri | Should -Be $script:meta.licenseUri
        $psd1.PrivateData.PSData.ReleaseNotes | Should -Be $script:meta.releaseNotes
    }
}

Describe 'Update-CctPsd1FromMetadata 盖章函数' {
    It '版本/域名/发版说明盖章进 psd1，其余字段与换行形态保持不变' {
        $fp = New-FixturePsd1; $fm = New-FixtureMeta
        $r = Update-CctPsd1FromMetadata -MetadataPath $fm -Psd1Path $fp
        $r.Changed | Should -BeTrue
        $r.Version | Should -Be '1.2.3'
        @($r.Updated) | Should -Contain 'ModuleVersion'
        $raw = [System.IO.File]::ReadAllText($fp, [System.Text.UTF8Encoding]::new($false))
        $raw | Should -BeLike "*ModuleVersion        = '1.2.3'*"
        $raw | Should -BeLike "*ProjectUri   = 'https://example.com/new'*"
        $raw | Should -BeLike "*LicenseUri   = 'https://example.com/new/blob/main/LICENSE'*"
        $raw | Should -BeLike "*ReleaseNotes = '1.2.3：新说明'*"
        # 未涉字段原样保留；CRLF 换行形态保持
        $raw | Should -BeLike "*RootModule           = 'ClaudeCodeTask.psm1'*"
        $raw.Contains("`r`n") | Should -BeTrue
        $raw.Contains("`n`r") | Should -BeFalse
    }
    It '幂等：连续两次盖章，第二次无变化不写文件' {
        $fp = New-FixturePsd1; $fm = New-FixtureMeta
        [void](Update-CctPsd1FromMetadata -MetadataPath $fm -Psd1Path $fp)
        $mtime1 = (Get-Item -LiteralPath $fp).LastWriteTimeUtc.Ticks
        Start-Sleep -Milliseconds 50
        $r2 = Update-CctPsd1FromMetadata -MetadataPath $fm -Psd1Path $fp
        $r2.Changed | Should -BeFalse
        (Get-Item -LiteralPath $fp).LastWriteTimeUtc.Ticks | Should -Be $mtime1
    }
    It '元数据缺必填字段 / version 形态非法 / 值含单引号 → 明确报错' {
        $fp = New-FixturePsd1
        $bad1 = Join-Path $script:tmp 'bad1.json'
        @{ projectUri = 'https://x'; licenseUri = 'https://x'; releaseNotes = 'x'; buildProxy = 'http://x' } | ConvertTo-Json | Set-Content -LiteralPath $bad1 -Encoding utf8
        { Update-CctPsd1FromMetadata -MetadataPath $bad1 -Psd1Path $fp } | Should -Throw '*version*'
        $bad2 = Join-Path $script:tmp 'bad2.json'
        @{ version = 'abc'; projectUri = 'https://x'; licenseUri = 'https://x'; releaseNotes = 'x'; buildProxy = 'http://x' } | ConvertTo-Json | Set-Content -LiteralPath $bad2 -Encoding utf8
        { Update-CctPsd1FromMetadata -MetadataPath $bad2 -Psd1Path $fp } | Should -Throw '*x.y.z*'
        $bad3 = Join-Path $script:tmp 'bad3.json'
        @{ version = '1.0.0'; projectUri = "https://x'o"; licenseUri = 'https://x'; releaseNotes = 'x'; buildProxy = 'http://x' } | ConvertTo-Json | Set-Content -LiteralPath $bad3 -Encoding utf8
        { Update-CctPsd1FromMetadata -MetadataPath $bad3 -Psd1Path $fp } | Should -Throw "*单引号*"
    }
    It 'psd1 缺字段行 / 元数据文件不存在 → 明确报错' {
        $fm = New-FixtureMeta
        $noField = Join-Path $script:tmp 'nofield.psd1'
        Set-Content -LiteralPath $noField -Encoding utf8 -Value "@{`n    ModuleVersion = '0.9.9'`n}"
        { Update-CctPsd1FromMetadata -MetadataPath $fm -Psd1Path $noField } | Should -Throw '*ProjectUri*'
        { Update-CctPsd1FromMetadata -MetadataPath (Join-Path $script:tmp '不存在.json') -Psd1Path $fm } | Should -Throw '*找不到*'
    }
}
