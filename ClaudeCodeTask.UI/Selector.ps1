# 界面层：全屏选择器（spec 4，决策 43 重构为卡片式网格，第八轮重构为固定栏位布局）
# 帧渲染是纯函数（可测）；主循环 + ReadKey 见 Show-CctSelector
# 第十轮布局：搜索行(固定) / 空行 / 卡片网格(滚动区,带边框) / [填充行] / 帮助行(固定)
# 帧高恒 = WindowHeight（帮助行贴底，决策 76）；搜索行恒在行 0、帮助行恒在最后一行，
# 滚动时二者行号恒定（行 diff 不重绘 = 固定栏位效果），终端永不滚屏
# （第八轮 bug2 根因：旧版 MaxRows 按 3 行/块预算，实际每块 4 行（3 内容+1 空行），帧高超出
#   屏高后绝对定位行号把超出行推入滚动区，屏幕内容整体错位——「提示 提示」残影即此）

$script:CctEsc = [char]27

# stdin 控制台模式管理（第六轮根因修复，2026-09-01 探针实锤）：
#   stdin 带 ENABLE_VIRTUAL_TERMINAL_INPUT(0x0200) 时 [Console]::ReadKey 把方向键拆成
#   ESC/'['/'C' 三个普通字符（Key=None）——方向键导航失效 + '[C[C[D' 污染 query、
#   ESC/ctrl+C 退出全失灵。用户终端可能带着该模式进来（PSReadLine/其他 TUI 工具残留），
#   cct 进入时防御性关闭，退出时恢复原样。
if (-not ('CctConsoleMode' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot '..\ClaudeCodeTask.Core\lib\ClaudeCodeTask.Core.dll')
}

# 清掉 mode 的 VT_INPUT 位（纯函数，可测）；stdin 非控制台（重定向）返回原值
function Get-CctCleanInputMode {
    param([uint32]$Mode)
    return $Mode -band (-bnot [uint32]0x0200)
}

# 进入选择器前关闭 VT_INPUT；返回「恢复函数」供 finally 调用（模式不可读时返回 null）
function Enter-CctInputMode {
    try {
        $h = [CctConsoleMode]::GetStdHandle([CctConsoleMode]::STD_INPUT)
        $m = [uint32]0
        if (-not [CctConsoleMode]::GetConsoleMode($h, [ref]$m)) { return $null }
        $clean = Get-CctCleanInputMode $m
        if ($clean -ne $m) {
            [void][CctConsoleMode]::SetConsoleMode($h, $clean)
            return {
                try {
                    $h2 = [CctConsoleMode]::GetStdHandle([CctConsoleMode]::STD_INPUT)
                    [void][CctConsoleMode]::SetConsoleMode($h2, $m)
                } catch {}
            }.GetNewClosure()
        }
        return $null   # 本来就没开 VT_INPUT，无需恢复
    } catch { return $null }
}

# ANSI 剥离（计算纯文本宽度用）
$script:CctAnsiPattern = "$([char]27)\[[0-9;?]*[a-zA-Z]"

# 版权文字按可用显示宽分档：完整 → 缩短 → 极短 → 省略（终端窗口缩窄时渐进隐藏，不挤压左侧按键提示）
function Get-CctCopyright {
    param([int]$AvailWidth)   # 版权文字可用显示宽 = 窗口宽 - 帮助行左侧按键提示宽 - 间隔
    if ($AvailWidth -ge 20) { return 'by github - hjkl950217' }
    if ($AvailWidth -ge 9)  { return 'by github' }
    if ($AvailWidth -ge 2)  { return 'by' }
    return ''
}

# 生成整帧行数组（不写控制台）
# 第十轮布局：搜索行 / 空行 / [卡片块(边框5行)]*MaxRows / [填充行 h-3-MaxRows*5] / 帮助行
# 帧高恒 = WindowHeight（帮助行贴底）；无块尾空行、无隐藏提示行——行号稳定 = 固定栏位效果
function New-CctFrame {
    param(
        [pscustomobject[]]$Tasks, [int]$SelectedIndex, [string]$Query,
        [int]$WindowWidth, [int]$WindowHeight, [datetime]$Now,
        [int]$TotalCount = $Tasks.Count      # 过滤后的 M/N 里 N = 过滤前总数
    )
    $esc = $script:CctEsc
    $cReset = "$esc[0m"; $cDim = "$esc[90m"; $cSel = "$esc[96m"   # 选中：亮青文字（反馈 4，替代整卡反色 ESC[7m）

    $rows = [System.Collections.Generic.List[string]]::new()

    # ---- 行 0：搜索行（计数紧跟搜索框右侧，决策 47；第八轮 3：占位文案）----
    $leftPlain = '搜索: ['
    $left = '搜索: ['
    if ([string]::IsNullOrEmpty($Query)) {
        $leftPlain += '直接输入即可按关键词实时过滤，支持中文'
        $left += $cDim + '直接输入即可按关键词实时过滤，支持中文' + $cReset
    } else {
        $leftPlain += $Query
        $left += $Query
    }
    $leftPlain += ']'; $left += ']'
    # 计数：无过滤「共 N 项」，有过滤「M/N」——紧跟在 ] 后（不再右对齐到行尾）
    $right = if ([string]::IsNullOrEmpty($Query)) { " 共 $TotalCount 项" } else { " $($Tasks.Count)/$TotalCount" }
    $rows.Add($left + $cDim + $right + $cReset)

    $rows.Add('')   # 空行

    # ---- 卡片网格（第八轮 4：边框卡片）----
    # 列数：≤3，带边框后单卡最小 36 显示宽（内容区最小 34）
    $cols = [Math]::Min(3, [Math]::Max(1, [int][Math]::Floor($WindowWidth / 36)))
    # 卡外框宽：总宽去掉卡间 1 空格后均分（反馈 4：卡间距 2→1）；innerW = 两根 │ 之间的列数；padW = 去掉两侧各 1 空格的文本预算
    $gap = 1
    $cardW = [int][Math]::Floor(($WindowWidth - ($cols - 1) * $gap) / $cols)
    $innerW = $cardW - 2
    $padW = $innerW - 2
    $timeW = 10                                  # 时间列预留 10 显示宽（最宽如「59分钟前」）
    $nameW = $padW - $timeW - 1                  # 标题段：文本预算 - 时间列 - 1 空格间隔
    $tails = Get-TailPaths @($Tasks | ForEach-Object { $_.Path } | Select-Object -Unique)

    # 可见卡片块数：帧高恒 = WindowHeight（反馈 2 帮助行贴底）。余下 (h-3-MaxRows*5) 行填到帮助行
    # 上方做间距——搜索行行 0 与帮助行末行行号恒定（固定栏位，行 diff 不重绘）
    $MaxRows = [Math]::Max(0, [int][Math]::Floor(($WindowHeight - 3) / 5))

    # 滚动：按卡片行号（floor(index/cols)）保持选中可见
    $rSel = [int][Math]::Floor($SelectedIndex / $cols)
    $startRow = [Math]::Max(0, $rSel - $MaxRows + 1)

    # 每个块槽固定 5 行（边框内容），槽不满也填满（第九轮 4+5：去块尾空行）
    for ($r = $startRow; $r -lt ($startRow + $MaxRows); $r++) {
        # 每张卡 5 行：上边框 / 标题+时间 / 路径1 / 路径2 / 下边框
        $tops = [System.Collections.Generic.List[string]]::new()
        $l1s = [System.Collections.Generic.List[string]]::new()
        $l2s = [System.Collections.Generic.List[string]]::new()
        $l3s = [System.Collections.Generic.List[string]]::new()
        $bots = [System.Collections.Generic.List[string]]::new()
        $top = '┌' + ('─' * $innerW) + '┐'
        $bot = '└' + ('─' * $innerW) + '┘'
        for ($c = 0; $c -lt $cols; $c++) {
            $idx = $r * $cols + $c
            if ($idx -ge $Tasks.Count) { continue }
            $t = $Tasks[$idx]
            $isSel = ($idx -eq $SelectedIndex)
            # 标题行：会话项带目录括号（决策 48 + 第八轮去重）
            $displayName = if ($t.Kind -eq 'Session') {
                Get-CctSessionLabel $t.Name $t.Path
            } else { [string]$t.Name }
            # 时间右对齐（第八轮 5）：名称左对齐占 nameW，时间列 Pad-DisplayLeft 靠右
            $namePart = Pad-DisplayRight (Truncate-Display $displayName $nameW) $nameW
            $timePart = Pad-DisplayLeft (Truncate-Display (Get-RelativeTime $t.LastActive $Now) $timeW) $timeW
            $l1 = "│ $namePart $timePart │"
            # 路径两行（决策 47：3 级尾部，超宽换行，不足补空行保证网格对齐）——文本预算 padW
            $tailFull = [string]$tails[$t.Path]
            $l2Plain = if ((Get-DisplayWidth $tailFull) -gt $padW) {
                # 超 1 行宽：第 1 行装满 padW 宽的内容，剩余进第 2 行（可能被截断）
                $w = 0; $i = 0
                while ($i -lt $tailFull.Length -and $w + (Get-DisplayWidth ([string]$tailFull[$i])) -le $padW) {
                    $w += Get-DisplayWidth ([string]$tailFull[$i]); $i++
                }
                ,@($tailFull.Substring(0, $i), (Truncate-Display $tailFull.Substring($i) $padW))
            } else { ,@($tailFull, '') }
            $l2 = '│ ' + (Pad-DisplayRight $l2Plain[0] $padW) + ' │'
            $l3 = '│ ' + (Pad-DisplayRight $l2Plain[1] $padW) + ' │'
            if ($isSel) {
                # 选中整卡（含边框 5 行）亮青文字（反馈 4：整卡反色→亮青，匹配边框线条）
                $top = $cSel + $top + $cReset
                $l1 = $cSel + $l1 + $cReset
                $l2 = $cSel + $l2 + $cReset
                $l3 = $cSel + $l3 + $cReset
                $bot = $cSel + $bot + $cReset
            } else {
                $top = $cDim + $top + $cReset
                $l2 = $cDim + $l2 + $cReset
                $l3 = $cDim + $l3 + $cReset
                $bot = $cDim + $bot + $cReset
            }
            $null = $tops.Add($top)
            $null = $l1s.Add($l1)
            $null = $l2s.Add($l2)
            $null = $l3s.Add($l3)
            $null = $bots.Add($bot)
            # 每卡重置边框模板（选中态已写进变量，下一张卡要用干净的）
            $top = '┌' + ('─' * $innerW) + '┐'
            $bot = '└' + ('─' * $innerW) + '┘'
        }
        $rows.Add(($tops -join (' ' * $gap)))
        $rows.Add(($l1s -join (' ' * $gap)))
        $rows.Add(($l2s -join (' ' * $gap)))
        $rows.Add(($l3s -join (' ' * $gap)))
        $rows.Add(($bots -join (' ' * $gap)))
    }

    # 余数行填充到帮助行上方 → 帧高恒 = WindowHeight，帮助行贴底（反馈 2）
    for ($i = 0; $i -lt ($WindowHeight - 3 - $MaxRows * 5); $i++) { $rows.Add('') }

    # 帮助行恒在末行 → 行号稳定 = 帮助行永远在屏幕最后一行
    # 左侧按键提示 + 右侧居右淡色版权（版权按宽度分档，窗口缩窄时渐进省略）
    $help = '  ↑↓←→ 选择   回车 启动   Esc 取消'
    $helpW = Get-DisplayWidth $help
    $copy = Get-CctCopyright ($WindowWidth - $helpW - 2)   # 2 = 与提示的最小间隔空格
    if ($copy) {
        $rows.Add($cDim + $help + (' ' * ($WindowWidth - $helpW - (Get-DisplayWidth $copy))) + $copy + $cReset)
    } else {
        $rows.Add($cDim + $help + $cReset)
    }
    return $rows.ToArray()
}

# 行 diff 重绘（发现 11：缓存上一帧，只重绘变化行，防闪烁）
# 第十一轮反馈：覆盖式写入替代「ESC[K 清行+重写」。选中移动时整行只做颜色切换
# （可见宽不变），直接覆盖不闪；仅当新行可见宽 < 旧行（缩短）或该行被删除（$l2=null）时
# 才 ESC[K 清行/清尾，避免残留。
$script:CctLastRows = @()
function Write-CctFrame {
    param([string[]]$Rows)
    $esc = $script:CctEsc
    $sb = [System.Text.StringBuilder]::new()
    $max = [Math]::Max(@($script:CctLastRows).Count, $Rows.Count)
    for ($i = 0; $i -lt $max; $i++) {
        $l1 = if ($null -ne $script:CctLastRows -and $i -lt @($script:CctLastRows).Count) { $script:CctLastRows[$i] } else { $null }
        $l2 = if ($i -lt $Rows.Count) { $Rows[$i] } else { $null }
        if ($l1 -cne $l2) {
            [void]$sb.Append($esc).Append('[').Append($i + 1).Append(';1H')
            if ($null -ne $l2) {
                # 覆盖式写入：直接写新内容（自带完整 ANSI 颜色状态），不先清行 → 无空白帧闪烁
                [void]$sb.Append($l2)
                if ($null -ne $l1 -and
                    (Get-DisplayWidth ($l2 -replace $script:CctAnsiPattern, '')) -lt
                    (Get-DisplayWidth ($l1 -replace $script:CctAnsiPattern, ''))) {
                    [void]$sb.Append($esc).Append('[K')   # 新行变短：清尾残留
                }
            } else {
                [void]$sb.Append($esc).Append('[K')   # 旧行比新帧多：清行
            }
        }
    }
    $script:CctLastRows = @($Rows)
    if ($sb.Length -gt 0) { [Console]::Write($sb.ToString()) }
}

# 主循环（决策 7/24/31/43/45；KeySource 可注入供测试，生产用轮询读键）
function Show-CctSelector {
    param(
        [pscustomobject[]]$Tasks,
        [string]$InitialQuery = '',
        [scriptblock]$KeySource = $null
    )
    $esc = $script:CctEsc
    if (@($Tasks).Count -eq 0) { return $null }
    $total = @($Tasks).Count

    try { $w = [Console]::WindowWidth } catch { $w = 120 }
    try { $h = [Console]::WindowHeight } catch { $h = 40 }
    # 帧高恒 = $h（帮助行贴底，决策 76）；MaxRows 由 New-CctFrame 按 $h 内部计算

    $query = $InitialQuery
    $selected = 0
    $script:CctLastRows = @()
    $result = $null

    # 生产模式：进备用屏幕 + 隐藏光标（发现 11）。测试模式（KeySource 注入）跳过控制台操作
    $interactive = $null -eq $KeySource
    $savedCtrl = $false
    $restoreMode = $null
    try {
        if ($interactive) {
            # 第六轮修复：关掉 VT_INPUT（残留时 ReadKey 把方向键拆成 ESC 序列字符）
            $restoreMode = Enter-CctInputMode
            try { $savedCtrl = [Console]::TreatControlCAsInput } catch { $savedCtrl = $false }
            [Console]::TreatControlCAsInput = $true
            [Console]::Write("$esc[?1049h$esc[?25l")
        }
        while ($true) {
            $filtered = @(Filter-CctTasks $Tasks $query)
            if ($selected -ge $filtered.Count) { $selected = [Math]::Max(0, $filtered.Count - 1) }
            # 列数随当前宽度计算（resize 后 $w 已更新，这里驱动 ↑↓ 跳列；边框卡按 36 算）
            $cols = [Math]::Min(3, [Math]::Max(1, [int][Math]::Floor($w / 36)))
            $frame = @(New-CctFrame $filtered $selected $query $w $h ([datetime]::Now) $total)
            if ($interactive) { Write-CctFrame $frame }   # 测试模式不写控制台
            # 读键：生产模式用 KeyAvailable 轮询以检测终端 resize；测试模式直接调 KeySource
            if ($KeySource) {
                $key = & $KeySource
            } else {
                $resized = $false
                while (-not [Console]::KeyAvailable) {
                    $nw = $null; $nh = $null
                    try { $nw = [Console]::WindowWidth } catch { $nw = $w }
                    try { $nh = [Console]::WindowHeight } catch { $nh = $h }
                    if ($nw -ne $w -or $nh -ne $h) {
                        $w = $nw; $h = $nh
                        if ($w -gt 0) { $cols = [Math]::Min(3, [Math]::Max(1, [int][Math]::Floor($w / 36))) }
                        # 反馈 1 根因：旧版 resize 只置空 CctLastRows 触发「全量重绘」，但 Write-CctFrame
                        # 行数取 Max(旧帧数,新帧数)，置空后旧帧行数=0 → 旧帧比新帧多的行永不重绘 → 残影。
                        # 修复：先真清屏（ESC[2J）再置空，物理屏旧内容彻底清除，下一帧全量重绘。
                        # 反馈 11：清屏后必须立即重绘（continue 跳回外层循环顶部），否则停止后需按键才显示。
                        [Console]::Write("$esc[2J$esc[H")
                        $script:CctLastRows = @()   # 清屏后强制下一帧全量重绘；selected 保持
                        $resized = $true
                        break
                    }
                    Start-Sleep -Milliseconds 30
                }
                if ($resized) { continue }   # 跳过 ReadKey，立即用新尺寸重绘一帧
                $key = [Console]::ReadKey($true)
            }
            if ($null -eq $key) { return $null }           # 序列耗尽 = 取消
            # Ctrl+C 取消
            if ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [System.ConsoleModifiers]::Control)) { return $null }
            switch ($key.Key) {
                ([ConsoleKey]::LeftArrow)  { $selected = [Math]::Max(0, $selected - 1) }
                ([ConsoleKey]::RightArrow) { $selected = [Math]::Min($filtered.Count - 1, $selected + 1) }
                ([ConsoleKey]::UpArrow)    { $selected = [Math]::Max(0, $selected - $cols) }
                ([ConsoleKey]::DownArrow)  { $selected = [Math]::Min($filtered.Count - 1, $selected + $cols) }
                ([ConsoleKey]::Enter) {
                    if ($filtered.Count -gt 0) { $result = $filtered[$selected] }
                    return $result
                }
                ([ConsoleKey]::Escape)     { return $null }
                ([ConsoleKey]::Backspace)  { if ($query.Length -gt 0) { $query = $query.Substring(0, $query.Length - 1) } }
                default {
                    $ch = $key.KeyChar
                    if ($ch -ge [char]0x20 -and $ch -ne [char]0x7F) { $query += $ch }
                }
            }
        }
    } finally {
        if ($interactive) {
            try { [Console]::TreatControlCAsInput = $savedCtrl } catch {}
            try { [Console]::Write("$esc[?25h$esc[?1049l$esc[0m") } catch {}
            if ($restoreMode) { & $restoreMode }
        }
    }
}
