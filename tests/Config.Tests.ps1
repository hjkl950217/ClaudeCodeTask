BeforeAll {
    . "$PSScriptRoot\..\cct\Config.ps1"
    $script:tmp = Join-Path $env:TEMP ("cct_cfg_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $script:tmp | Out-Null
    $script:cfgPath = Join-Path $script:tmp 'config.json'
}
AfterAll {
    if (Test-Path $script:tmp) { Remove-Item -Recurse -Force $script:tmp }
}

Describe 'Get-CctConfig' {
    It '首次调用：生成默认配置文件并返回默认值（决策 25）' {
        $cfg = Get-CctConfig -Path $script:cfgPath
        Test-Path $script:cfgPath | Should -BeTrue
        $cfg.launchCommand | Should -Be 'claude --dangerously-skip-permissions -c'
        $cfg.resumeCommand | Should -Be 'claude --dangerously-skip-permissions --resume {sessionId}'
        $cfg.excludePathPatterns | Should -Not -Contain 'ConfigBackup'
        $cfg.excludePathPatterns | Should -Contain 'AppData\Local\Temp'
        $cfg.maxVisibleRows | Should -Be 0
        $cfg.minUserMessages | Should -Be 10
    }
    It '已存在的配置：读回用户修改值' {
        $json = @'
{
  "launchCommand": "my-claude start",
  "resumeCommand": "my-claude resume {sessionId}",
  "excludePathPatterns": ["zzz"],
  "maxVisibleRows": 20,
  "minUserMessages": 5
}
'@
        [System.IO.File]::WriteAllText($script:cfgPath, $json, [System.Text.UTF8Encoding]::new($false))
        $cfg = Get-CctConfig -Path $script:cfgPath
        $cfg.launchCommand | Should -Be 'my-claude start'
        $cfg.minUserMessages | Should -Be 5
        $cfg.maxVisibleRows | Should -Be 20
    }
    It '损坏的 JSON：返回默认值不抛异常' {
        [System.IO.File]::WriteAllText($script:cfgPath, '{broken', [System.Text.UTF8Encoding]::new($false))
        $cfg = Get-CctConfig -Path $script:cfgPath
        $cfg.launchCommand | Should -Be 'claude --dangerously-skip-permissions -c'
    }
}
