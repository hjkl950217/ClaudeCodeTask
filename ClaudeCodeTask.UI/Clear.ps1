# 清理层：cct clear —— 清 cct 扫描缓存；cct clear -cc —— 清理多余 Claude Code 会话。
# 判定规则源自 2026-09-04 真实清理经验（与显示层 Get-CctTasks 的语义刻意分离）：
#   对 projects 根下每个编码目录：会话 = 该目录内 *.jsonl（排除 journal.jsonl / agent-*，与数据层一致）。
#   「对话次数」按 .jsonl 行数近似（= 消息事件行数，规则同 wc -l）。
#   每目录保留「行数 ≥ 阈值」里最新 keep 个（按文件修改时间降序、行数降序决胜）；
#   目录内无 ≥ 阈值的会话 → 整目录删除（含 memory 与孤立残留）；
#   被删会话的同名附属目录（subagents/tool-results/workflows）与孤立目录一并列入删除。
# 删除不可逆：先打印「过滤规则 + 待删清单 + 理由」，确认后才删；非交互且未给 --yes 只预览不删。

# 字节数人性化（预览用）
function Format-CctBytes {
    param([int64]$Bytes)
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

# 会话文件行数（行流迭代，不整体载入内存）；读取失败返回 -1（不可判 → 调用方不判不删）
function Get-CctLineCount {
    param([string]$Path)
    try {
        $n = 0
        foreach ($_ in [System.IO.File]::ReadLines($Path)) { $n++ }
        return $n
    } catch { return -1 }
}

# 删除项占用大小（字节：目录含全部子文件；估算回收空间用）
function Get-CctCleanupSize {
    param([string]$Path)
    try {
        if ([System.IO.Directory]::Exists($Path)) {
            $sum = 0L
            foreach ($f in [System.IO.Directory]::EnumerateFiles($Path, '*', [System.IO.SearchOption]::AllDirectories)) {
                $sum += [System.IO.FileInfo]::new($f).Length
            }
            return $sum
        }
        if ([System.IO.File]::Exists($Path)) { return [System.IO.FileInfo]::new($Path).Length }
        return 0
    } catch { return 0 }
}

# 行号 → 删除/保留决策（纯函数，不写盘不读确认）。返回:
#   { Root, MinLines, Keep, Keep@(), Candidates@() }
# Keep 项: { DirName, Name, Sid8, Lines, Mod }
# Candidates 项: { Type='J'|'D'|'O'|'W', Path, Display, Reason, Size }
#   W  = 整目录删除（无 ≥MinLines 会话）；其余三类不会与 W 重叠（组内 W 时不再拆列）
function Get-CctCleanupCandidates {
    param(
        [string]$Root,
        [int]$MinLines = 20,
        [int]$Keep = 1,
        [string[]]$ExcludePatterns = @()
    )

    $kept = [System.Collections.Generic.List[object]]::new()
    $cands = [System.Collections.Generic.List[object]]::new()

    foreach ($dir in [System.IO.Directory]::GetDirectories($Root)) {
        # 排除模式（worktrees / Temp 等：路径含模式即跳过，与数据层口径一致）
        $skipDir = $false
        foreach ($pat in $ExcludePatterns) { if ($dir -like "*$pat*") { $skipDir = $true; break } }
        if ($skipDir) { continue }

        $files = [System.Collections.Generic.List[object]]::new()
        foreach ($f in [System.IO.Directory]::EnumerateFiles($dir, '*.jsonl')) {
            $name = [System.IO.Path]::GetFileName($f)
            if ($name -like 'agent-*' -or $name -eq 'journal.jsonl') { continue }
            $lines = Get-CctLineCount -Path $f
            if ($lines -lt 0) { continue }   # 读失败：不判不删，保守跳过
            $files.Add([pscustomobject]@{
                Path = $f; Name = $name; Sid = ($name -replace '\.jsonl$', '')
                Length = [System.IO.FileInfo]::new($f).Length
                Lines = $lines; Mod = [System.IO.File]::GetLastWriteTimeUtc($f)
            })
        }
        if ($files.Count -eq 0) { continue }
        $dirName = [System.IO.Path]::GetFileName($dir)

        # 行数 ≥ 阈值的会话：最新在前
        $eligible = @($files | Where-Object Lines -ge $MinLines | Sort-Object @{Expression = 'Mod'; Descending = $true}, @{Expression = 'Lines'; Descending = $true})

        if ($eligible.Count -eq 0) {
            # 整目录删除：目录内所有会话都 < 阈值（含 memory、附属目录、孤立残留，整体删）
            $cands.Add([pscustomobject]@{
                Type = 'W'; Path = $dir; Display = $dirName
                Reason = "目录内 $($files.Count) 个会话均小于 $MinLines 行，整目录删除（含 memory）"
                Size = Get-CctCleanupSize -Path $dir
            })
            continue
        }

        $nKeep = [Math]::Min($Keep, $eligible.Count)
        $keepItems = @($eligible[0..($nKeep - 1)])
        $keepSids = [System.Collections.Generic.HashSet[string]]::new()
        $allSids = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($f in $files) { [void]$allSids.Add($f.Sid) }
        $keptDesc = [System.Collections.Generic.List[string]]::new()
        foreach ($k in $keepItems) {
            [void]$keepSids.Add($k.Sid)
            [void]$allSids.Add($k.Sid)
            $kept.Add([pscustomobject]@{
                DirName = $dirName; Name = $k.Name; Sid8 = $k.Sid.Substring(0, [Math]::Min(8, $k.Sid.Length))
                Lines = $k.Lines; Mod = $k.Mod
            })
            $keptDesc.Add("$($k.Sid.Substring(0, [Math]::Min(8, $k.Sid.Length)))（$($k.Lines)行）")
        }
        $keptSummary = if ($keepItems.Count -eq 1) { "同目录保留 $($keptDesc[0])" } else { "本目录保留 $($keepItems.Count) 个：$($keptDesc -join '、')" }

        # 未保留的会话 jsonl → J（连同其同名附属目录 → D）
        foreach ($f in $files) {
            if ($keepSids.Contains($f.Sid)) { continue }
            $cands.Add([pscustomobject]@{
                Type = 'J'; Path = $f.Path; Display = "$dirName\$($f.Name)"
                Reason = "非保留会话（$keptSummary）"; Size = $f.Length
            })
        }

        # 目录下子目录：保留会话的附属目录不动；被删会话的附属目录 → D；无对应 jsonl → O（孤立）
        foreach ($sub in [System.IO.Directory]::GetDirectories($dir)) {
            $leaf = [System.IO.Path]::GetFileName($sub)
            if ($leaf -eq 'memory') { continue }          # 目录还有保留会话 → memory 保留
            if ($keepSids.Contains($leaf)) { continue }   # 保留会话的附属目录
            if ($allSids.Contains($leaf)) {
                $cands.Add([pscustomobject]@{
                    Type = 'D'; Path = $sub; Display = "$dirName\$leaf"
                    Reason = "会话 $($leaf.Substring(0, [Math]::Min(8, $leaf.Length))) 的附属目录（subagents/tool-results/workflows）"
                    Size = Get-CctCleanupSize -Path $sub
                })
            } else {
                $cands.Add([pscustomobject]@{
                    Type = 'O'; Path = $sub; Display = "$dirName\$leaf"
                    Reason = '孤立目录（无对应会话 jsonl）'; Size = Get-CctCleanupSize -Path $sub
                })
            }
        }
    }

    return [pscustomobject]@{
        Root = $Root; MinLines = $MinLines; KeepCount = $Keep
        Keep = @($kept); Candidates = @($cands)
    }
}

# 预览文本（行数组，纯函数供测试直接断言）：
#   第一段 = 过滤规则；第二段 = 保留明细；第三段 = 待删清单（类型/路径/理由/大小）+ 合计
function Get-CctClearText {
    param([pscustomobject]$Result)

    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add('清理规则（只处理 ~/.claude/projects 下的会话历史目录）：')
    $out.Add("  1. 「对话次数」按会话 .jsonl 的行数近似，行数 ≥ $($Result.MinLines) 才算有效会话。")
    $out.Add("  2. 每个目录保留「行数 ≥ $($Result.MinLines)」里最新 $($Result.KeepCount) 个（按修改时间降序）；")
    $out.Add('     其余会话 jsonl、被删会话的附属目录（subagents/tool-results/workflows）、孤立目录列入删除。')
    $out.Add('  3. 目录内所有会话都 < 阈值 → 整目录删除（含 memory）。')
    if ($Result.Keep.Count -gt 0) {
        $out.Add('')
        $out.Add("将保留 $($Result.Keep.Count) 个会话（每目录 $($Result.KeepCount) 个最新会话，其余清理）：")
        foreach ($k in $Result.Keep) {
            $out.Add("  保留  $($k.DirName)\$($k.Name)（$($k.Lines) 行，$($k.Mod.ToLocalTime().ToString('MM-dd HH:mm'))）")
        }
    }

    $cands = @($Result.Candidates)
    $out.Add('')
    if ($cands.Count -eq 0) {
        $out.Add('没有需要清理的会话（每个目录都已只剩最新会话，或没有足够多的历史）。')
        return @($out)
    }
    $totalBytes = 0L
    foreach ($c in $cands) { $totalBytes += $c.Size }
    $out.Add("待删除 $($cands.Count) 项（约 $(Format-CctBytes -Bytes $totalBytes)）：")
    foreach ($c in $cands) {
        $out.Add("  [$($c.Type)] $($c.Display)（$(Format-CctBytes -Bytes $c.Size)）——$($c.Reason)")
    }
    return @($out)
}

# 删除待删清单（真实删除，破坏性）。返回 { Deleted, Bytes, Failed }
function Remove-CctCleanupItems {
    param([object[]]$Candidates)
    $deleted = 0; $bytes = 0L; $failed = 0
    foreach ($c in $Candidates) {
        if (-not (Test-Path -LiteralPath $c.Path)) { $deleted++; $bytes += $c.Size; continue }   # 已不存在视为已删
        try {
            Remove-Item -LiteralPath $c.Path -Recurse -Force -ErrorAction Stop
            $deleted++; $bytes += $c.Size
        } catch { $failed++ }
    }
    return [pscustomobject]@{ Deleted = $deleted; Bytes = $bytes; Failed = $failed }
}

# clear 专属参数解析（与共享 Split-CctCommandArgs 分离：-cc/-y/--keep/--min 是 clear 私有，
# 不塞进共享选项层，避免 cct list -cc 之类被静默接受）
function Parse-CctClearArgs {
    param([string[]]$Tokens)
    $cc = $false; $yes = $false; $dryRun = $false; $keep = $null; $min = $null
    $i = 0
    while ($i -lt $Tokens.Count) {
        $t = [string]$Tokens[$i]
        switch ($t.ToLowerInvariant()) {
            '-cc'       { $cc = $true; $i++; break }
            '-y'        { $yes = $true; $i++; break }
            '--yes'     { $yes = $true; $i++; break }
            '--dry-run' { $dryRun = $true; $i++; break }
            '--keep'    {
                if ($i + 1 -ge $Tokens.Count) { throw 'cct clear --keep 需要一个数字值（用 cct clear -h 查看帮助）' }
                $keep = [int]$Tokens[$i + 1]; $i += 2; break
            }
            '--min'     {
                if ($i + 1 -ge $Tokens.Count) { throw 'cct clear --min 需要一个数字值（用 cct clear -h 查看帮助）' }
                $min = [int]$Tokens[$i + 1]; $i += 2; break
            }
            default     { throw "未知选项: $t（用 cct clear -h 查看帮助）" }
        }
    }
    if ($null -ne $keep -and $keep -lt 1) { throw 'cct clear --keep 必须 ≥ 1' }
    if ($null -ne $min -and $min -lt 1) { throw 'cct clear --min 必须 ≥ 1' }
    return [pscustomobject]@{ Cc = $cc; Yes = $yes; DryRun = $dryRun; Keep = $keep; Min = $min }
}

# cct clear 主流程。Tokens 由外层路由传入；Root/ConfigPath 供测试注入。
# 分支：无 -cc → 清扫描缓存；有 -cc → 清理多余会话（先预览，确认后删）。
# 返回状态文本（无 -cc 分支）或 $null（-cc 分支，输出走 Write-Host）。
function Invoke-CctClear {
    param(
        [string[]]$Tokens = @(),
        [bool]$HasTty = $true,
        [string]$Root = (Join-Path $env:USERPROFILE '.claude\projects'),
        [string]$ConfigPath = (Join-Path $env:USERPROFILE '.cct\config.json')
    )
    $o = Parse-CctClearArgs -Tokens @($Tokens)

    if (-not $o.Cc) {
        # 清 cct 扫描缓存（安全操作）：缓存文件 = config 同目录 cache.json；config.json 不动
        $cfgDir = Split-Path -Parent $ConfigPath
        $cachePath = Join-Path $cfgDir 'cache.json'
        if (-not (Test-Path -LiteralPath $cachePath)) {
            return '[ok] 没有 cct 扫描缓存，无需清理（缓存文件：' + (Join-Path $cfgDir 'cache.json') + '）'
        }
        $sz = Get-CctCleanupSize -Path $cachePath
        Remove-Item -LiteralPath $cachePath -Force
        return "[ok] 已清除 cct 扫描缓存（$(Format-CctBytes -Bytes $sz)），下次扫描将全量重建缓存"
    }

    # -cc：清理多余会话（不动 cct 缓存）。删除不可逆 → 先打印规则与清单。
    $cfg = Get-CctConfig -Path $ConfigPath
    $result = Get-CctCleanupCandidates -Root $Root -MinLines ($o.Min ?? 20) -Keep ($o.Keep ?? 1) -ExcludePatterns $cfg.excludePathPatterns
    foreach ($l in Get-CctClearText -Result $result) { Write-Host $l }

    if ($result.Candidates.Count -eq 0) { return }

    if ($o.DryRun -or (-not $HasTty -and -not $o.Yes)) {
        if (-not $HasTty -and -not $o.Yes) { Write-Host '（非交互环境且未加 --yes：仅预览，未执行删除）' }
        return
    }
    if (-not $o.Yes) {
        Write-Host -NoNewline '确认删除以上全部待删项？[y/N] '
        $ans = Read-Host
        if (([string]$ans).Trim().ToLowerInvariant() -notin @('y', 'yes')) {
            Write-Host '已取消，未删除任何文件。'
            return
        }
    }
    $res = Remove-CctCleanupItems -Candidates $result.Candidates
    Write-Host "已删除 $($res.Deleted) 项，释放约 $(Format-CctBytes -Bytes $res.Bytes)。"
    if ($res.Failed -gt 0) { Write-Host "有 $($res.Failed) 项删除失败（请手动检查）。" }
}
