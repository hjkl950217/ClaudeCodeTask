# 配置读写（spec 6：~/.cct/config.json，首次自动生成默认值）

function Get-CctConfig {
    param([string]$Path = (Join-Path $env:USERPROFILE '.cct\config.json'))

    $default = [pscustomobject]@{
        launchCommand      = 'claude --dangerously-skip-permissions -c'
        resumeCommand      = 'claude --dangerously-skip-permissions --resume {sessionId}'
        # 排除模式（通用，不含机器特定路径）：worktree 是工具临时区；
        # Temp 是系统临时目录（探针/测试残留）。ConfigBackup 不默认排除——
        # 目录名每台机器不一样且里面可能有真实任务（用户决策 2026-08-31）
        excludePathPatterns = @('.claude/worktrees/', 'AppData\Local\Temp')
        maxVisibleRows     = 0
        minUserMessages    = 10
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        $default | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding utf8
        return $default
    }

    try {
        $user = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        # 合并：用户值优先，缺字段回退默认
        $result = [pscustomobject]@{}
        foreach ($p in $default.PSObject.Properties) {
            $uv = $user.PSObject.Properties[$p.Name]
            if ($null -ne $uv) { $result | Add-Member -NotePropertyName $p.Name -NotePropertyValue $uv.Value }
            else { $result | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
        }
        return $result
    } catch {
        return $default
    }
}
