# 显示工具：中文宽度 / 对齐 / 截断（East Asian Width 手动判区间，.NET 无内置支持）

function Get-DisplayWidth {
    param([string]$Text)
    $width = 0
    foreach ($rune in $Text.EnumerateRunes()) {
        $cp = [int]$rune.Value
        # 零宽：组合标记、ZWJ/ZWNJ、变体选择符、emoji 肤色修饰符
        if (($cp -ge 0x0300 -and $cp -le 0x036F) -or ($cp -ge 0x200B -and $cp -le 0x200F) -or
            ($cp -ge 0x2028 -and $cp -le 0x202E) -or ($cp -ge 0x2060 -and $cp -le 0x206F) -or
            ($cp -ge 0x20D0 -and $cp -le 0x20FF) -or ($cp -ge 0xFE00 -and $cp -le 0xFE0F) -or
            ($cp -ge 0xFE20 -and $cp -le 0xFE2F) -or ($cp -ge 0x1F3FB -and $cp -le 0x1F3FF) -or
            ($cp -ge 0xE0100 -and $cp -le 0xE01EF)) { continue }
        # 宽字符（East Asian Width = W/F）
        $isWide = ($cp -ge 0x1100 -and $cp -le 0x115F) -or ($cp -ge 0x2E80 -and $cp -le 0xA4CF) -or
                  ($cp -ge 0xAC00 -and $cp -le 0xD7A3) -or ($cp -ge 0xF900 -and $cp -le 0xFAFF) -or
                  ($cp -ge 0xFE30 -and $cp -le 0xFE4F) -or ($cp -ge 0xFF00 -and $cp -le 0xFF60) -or
                  ($cp -ge 0xFFE0 -and $cp -le 0xFFE6) -or ($cp -ge 0x1F300 -and $cp -le 0x1F64F) -or
                  ($cp -ge 0x1F900 -and $cp -le 0x1F9FF) -or ($cp -ge 0x20000 -and $cp -le 0x3FFFD)
        if ($isWide) { $width += 2 } else { $width += 1 }
    }
    return $width
}

function Pad-DisplayRight {
    param([string]$Text, [int]$Width, [char]$PadChar = ' ')
    $pad = $Width - (Get-DisplayWidth $Text); if ($pad -lt 0) { $pad = 0 }
    return $Text + ($PadChar.ToString() * $pad)
}

function Pad-DisplayLeft {
    param([string]$Text, [int]$Width, [char]$PadChar = ' ')
    $pad = $Width - (Get-DisplayWidth $Text); if ($pad -lt 0) { $pad = 0 }
    return ($PadChar.ToString() * $pad) + $Text
}

function Truncate-Display {
    param([string]$Text, [int]$MaxWidth, [string]$Ellipsis = '…')
    if ((Get-DisplayWidth $Text) -le $MaxWidth) { return $Text }
    $budget = $MaxWidth - (Get-DisplayWidth $Ellipsis)
    $result = ''; $w = 0
    foreach ($rune in $Text.EnumerateRunes()) {
        $rw = Get-DisplayWidth $rune.ToString()
        if ($w + $rw -gt $budget) { break }
        $result += $rune.ToString(); $w += $rw
    }
    return $result + $Ellipsis
}

# 会话项显示名（决策 48 + 第八轮去重）：「标题（目录名）」；标题与目录名
# 归一化后相同（忽略空白/_/-/. 和大小写）则省略括号——「CC汉化」目录 CC_汉化 → 只显示「CC汉化」
function Get-CctSessionLabel {
    param([string]$Name, [string]$Path)
    $dir = Split-Path -Leaf $Path
    if ($dir -eq $Path) { return $Name }   # 根路径无父目录（Split-Path -Leaf 'E:\' 返回自身）
    $norm = [regex]::Replace($Name, '[\s_\-\.]', '').ToLowerInvariant()
    $normDir = [regex]::Replace($dir, '[\s_\-\.]', '').ToLowerInvariant()
    if ($norm -eq $normDir -or [string]::IsNullOrEmpty($normDir)) { return $Name }
    return "$Name（$dir）"
}

# 相对时间（决策 17：刚刚/N分钟前/N小时前/昨天/N天前/MM-dd）
function Get-RelativeTime {
    param([datetime]$Time, [datetime]$Now)
    $span = $Now - $Time
    if ($span.TotalMinutes -lt 5) { return '刚刚' }
    if ($span.TotalHours -lt 1)   { return "$([int][Math]::Ceiling($span.TotalMinutes))分钟前" }
    if ($span.TotalHours -lt 24)  { return "$([int][Math]::Floor($span.TotalHours))小时前" }
    if ($span.TotalDays -lt 2)    { return '昨天' }
    if ($span.TotalDays -le 7)    { return "$([int][Math]::Floor($span.TotalDays))天前" }
    return $Time.ToString('MM-dd')
}

# 路径尾部（决策 18/19 + 47 修订：默认 3 级，冲突时逐级加深直到区分，路径耗尽即停）
function Get-TailPaths {
    param([string[]]$Paths)
    $levels = @{}
    foreach ($p in ($Paths | Select-Object -Unique)) { $levels[$p] = 3 }
    while ($true) {
        $tails = @{}
        foreach ($p in $levels.Keys) { $tails[$p] = (Get-PathTail $p $levels[$p]) }
        # 找出有冲突的尾部值，冲突组内能加深级的加深；全部不能再加就退出
        $conflicted = @($tails.Values | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
        if ($conflicted.Count -eq 0) { break }
        $extended = $false
        foreach ($p in @($tails.Keys | Where-Object { $conflicted -contains $tails[$_] })) {
            if ((Get-PathDepth $p) -gt $levels[$p]) { $levels[$p]++; $extended = $true }
        }
        if (-not $extended) { break }
    }
    $result = @{}
    foreach ($p in $levels.Keys) { $result[$p] = (Get-PathTail $p $levels[$p]) }
    return $result
}

function Get-PathTail {
    param([string]$Path, [int]$Levels)
    $parts = $Path -split '[\\/]' | Where-Object { $_ -ne '' }
    $n = [Math]::Min($Levels, $parts.Count)
    return (($parts | Select-Object -Last $n) -join '/')
}

function Get-PathDepth {
    param([string]$Path)
    return @(($Path -split '[\\/]' | Where-Object { $_ -ne '' })).Count
}
