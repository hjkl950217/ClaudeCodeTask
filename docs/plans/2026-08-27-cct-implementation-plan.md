# cct 任务文件夹选择器 · 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 一条 `cct` 命令弹出任务列表（从 Claude Code 会话历史反推），选中后自动 cd 到任务目录并启动 claude。

**Architecture:** PowerShell 模块三层单向依赖：数据层 `Get-CctTasks`（扫 `~/.claude/projects/**/*.jsonl`，头尾 50 行 + 消息计数早停，聚合排序）→ 界面层 `Show-CctSelector`（备用屏幕全屏列表、实时过滤、行 diff 重绘）→ 执行层 `Invoke-CctTask`（先 `Set-Location` 再启动 claude）。

**Tech Stack:** PowerShell 7.6（pwsh）、`[System.Text.Json.JsonDocument]` 流式解析、ANSI 转义（备用屏幕 `[?1049h/l`）、Pester 6（已装，`-MinimumVersion 5`）。

**Spec:** `docs/specs/2026-08-27-cct-任务文件夹选择器-design.md`（含 40 条决策与 22 条实测发现，是本计划的依据；执行者需同时读 spec 与本计划）

## Global Constraints

- 运行环境：Windows 11 + pwsh 7.6.5 + Windows Terminal；Claude Code 2.1.237。
- 模块路径：`E:\个人\PersonalAITaskCenter\工具\CC插件_管理文件夹会话\cct\cct.psm1`；测试在 `tests\`。
- **JSON 解析只用 `[System.Text.Json.JsonDocument]`**，禁止逐行 `ConvertFrom-Json`（性能：21k 行/秒 vs 169k 行/秒，且会 OOM）。
- **`TryGetProperty($name, [ref]$var)` 的 ref 变量必须先 `[System.Text.Json.JsonElement]::new()` 类型化**——传未类型化 `$null` 会因无法绑定 `JsonElement&` 重载而每行抛异常被静默跳过（调研两次踩坑）。统一用帮助函数 `Get-JsonProp` 封装。
- ANSI 转义直接写 `[char]27` 字符串，**不用 `$PSStyle`**（重定向时被剥离）。
- **不能用文件 mtime 代替会话内 timestamp 排序**（ConfigBackup 5 个复制文件偏差 66-187 小时）。
- 消息数按**单文件**计（同标题多文件是独立会话，发现 22 证伪了聚合模型）。
- 会话项的 resume 目标必须取「最新有实质内容的文件」（链尾可能是 `/clear` 空壳，8 行，直接 resume 会进空会话）。
- 测试运行方式：`pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5; Invoke-Pester -Path '<测试文件>' -Output Minimal -PassThru | Select-Object PassedCount, FailedCount"`（Windows 自带 Pester 3.4.0 会抢先加载，必须 `-MinimumVersion 5`）。
- 每个任务结束都 `git add` **显式列出的本任务文件**后提交，禁止 `git add .`（本仓库跨任务未提交改动多，`git add .` 会混入无关删除记录）。
- 测试里构造的 jsonl 必须放 `$env:TEMP` 下的临时目录，`AfterAll` 清理。
- 所有输出/注释/commit message 用中文。

---

### Task 1: 显示宽度计算（Display.ps1 基础）

**Files:**
- Create: `cct/Display.ps1`
- Create: `cct/cct.psm1`
- Test: `tests/Display.Tests.ps1`

**Interfaces:**
- Consumes: 无（最底层）
- Produces: `Get-DisplayWidth([string]$Text) → [int]`；`Pad-DisplayRight([string]$Text, [int]$Width, [char]$PadChar=' ') → [string]`；`Truncate-Display([string]$Text, [int]$MaxWidth, [string]$Ellipsis='…') → [string]`。后续所有界面任务都依赖这三个函数（Task 7/8/9）。

- [ ] **Step 1: 搭模块骨架 + 写失败测试**

`cct/cct.psm1`（模块入口，后续每个任务往里加一行 dot-source）：

```powershell
# cct 模块入口
$moduleRoot = $PSScriptRoot
. (Join-Path $moduleRoot 'Display.ps1')
```

`tests/Display.Tests.ps1`：

```powershell
BeforeAll {
    . "$PSScriptRoot\..\cct\Display.ps1"
}

Describe 'Get-DisplayWidth' {
    It 'ASCII 字符每个计 1' {
        Get-DisplayWidth 'abc' | Should -Be 3
    }
    It '中文每个计 2（显示宽度，非字节数）' {
        Get-DisplayWidth '中文' | Should -Be 4
    }
    It '全角符号计 2' {
        Get-DisplayWidth '（全角）' | Should -Be 8
    }
    It 'emoji 代理对计 2' {
        Get-DisplayWidth '😀' | Should -Be 2
    }
    It 'emoji + 肤色修饰符整体计 2（修饰符零宽）' {
        Get-DisplayWidth '👍🏽' | Should -Be 2
    }
    It '组合重音符号零宽' {
        # 显式构造 e + U+0301，避免编辑器把 é 规范化成单字符
        $s = "e$([char]0x301)"
        Get-DisplayWidth $s | Should -Be 1
    }
    It '零宽空格不计宽' {
        Get-DisplayWidth "a$([char]0x200B)b" | Should -Be 2
    }
    It '混合文本' {
        Get-DisplayWidth 'ab中😀' | Should -Be 7
    }
    It '空字符串为 0' {
        Get-DisplayWidth '' | Should -Be 0
    }
}

Describe 'Pad-DisplayRight' {
    It '窄文本右侧补空格到目标宽' {
        (Pad-DisplayRight '中文' 8) | Should -Be '中文    '
    }
    It '超宽文本不截断不补' {
        (Pad-DisplayRight '中文中文' 4) | Should -Be '中文中文'
    }
}

Describe 'Truncate-Display' {
    It '不超宽原样返回' {
        Truncate-Display '中文' 10 | Should -Be '中文'
    }
    It '超宽截断加省略号' {
        Truncate-Display '中文中文中文' 6 | Should -Be '中文…'
    }
    It '截断按显示宽度不按字符数' {
        # 5 个中文宽 10，限 7 → 保留 3 个中文 + …（宽 7）
        Truncate-Display '中文中文中文中文中文' 7 | Should -Be '中文中文…'
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5; Invoke-Pester -Path 'tests/Display.Tests.ps1' -Output Minimal -PassThru | Select-Object PassedCount, FailedCount"`（在项目根 `E:\个人\PersonalAITaskCenter\工具\CC插件_管理文件夹会话` 下执行）
Expected: FAIL——`cct/Display.ps1` 不存在，BeforeAll 加载报错。

- [ ] **Step 3: 实现 Display.ps1**

`cct/Display.ps1`（宽度表来自 `_perf_test/demo_selector.ps1` 实测验证版）：

```powershell
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
```

- [ ] **Step 4: 运行测试确认通过**

Run: 同 Step 2。
Expected: PassedCount = 14, FailedCount = 0。

- [ ] **Step 5: Commit**

```bash
git add cct/cct.psm1 cct/Display.ps1 tests/Display.Tests.ps1
git commit -m "feat(cct): 显示宽度计算与对齐截断工具（Task 1）"
```

---

### Task 2: 相对时间格式化 + 路径尾部级数

**Files:**
- Modify: `cct/Display.ps1`（追加函数）
- Test: `tests/Display2.Tests.ps1`

**Interfaces:**
- Consumes: 无新依赖
- Produces: `Get-RelativeTime([datetime]$Time, [datetime]$Now) → [string]`（决策 17）；`Get-TailPaths([string[]]$Paths) → [hashtable]`（路径 → 尾部路径映射，决策 18/19）。Task 8 界面渲染依赖。

- [ ] **Step 1: 写失败测试**

`tests/Display2.Tests.ps1`：

```powershell
BeforeAll {
    . "$PSScriptRoot\..\cct\Display.ps1"
    $script:now = [datetime]'2026-08-27 12:00:00'
}

Describe 'Get-RelativeTime（决策 17）' {
    It '小于 5 分钟 → 刚刚' {
        Get-RelativeTime ([datetime]'2026-08-27 11:58:00') $now | Should -Be '刚刚'
    }
    It '5-59 分钟 → N分钟前' {
        Get-RelativeTime ([datetime]'2026-08-27 11:30:00') $now | Should -Be '30分钟前'
    }
    It '1-23 小时 → N小时前' {
        Get-RelativeTime ([datetime]'2026-08-27 08:00:00') $now | Should -Be '4小时前'
    }
    It '恰好 24 小时前算昨天（同日历日或满 1 天）' {
        Get-RelativeTime ([datetime]'2026-08-26 12:00:00') $now | Should -Be '昨天'
    }
    It '2-7 天 → N天前' {
        Get-RelativeTime ([datetime]'2026-08-25 12:00:00') $now | Should -Be '2天前'
    }
    It '超过 7 天 → 绝对日期 MM-dd' {
        Get-RelativeTime ([datetime]'2026-08-05 12:00:00') $now | Should -Be '08-05'
    }
}

Describe 'Get-TailPaths（决策 18/19：默认 2 级，冲突加级直到区分）' {
    It '无冲突时尾部 2 级' {
        $m = Get-TailPaths @('E:\个人\PersonalAITaskCenter\工具\管理_sub2api', 'E:\个人\PersonalAITaskCenter\工作\写日志')
        $m['E:\个人\PersonalAITaskCenter\工具\管理_sub2api'] | Should -Be '工具/管理_sub2api'
        $m['E:\个人\PersonalAITaskCenter\工作\写日志'] | Should -Be '工作/写日志'
    }
    It '尾部 2 级冲突时各多显示一级' {
        $m = Get-TailPaths @(
            'E:\个人\PersonalAITaskCenter\0A_参考源码\源代码仓库\sub2api',
            'E:\个人\PersonalAITaskCenter\0A_参考源码\源代码理解\sub2api'
        )
        $m['E:\个人\PersonalAITaskCenter\0A_参考源码\源代码仓库\sub2api'] | Should -Be '源代码仓库/sub2api'
        $m['E:\个人\PersonalAITaskCenter\0A_参考源码\源代码理解\sub2api'] | Should -Be '源代码理解/sub2api'
    }
    It '3 级仍冲突继续加级' {
        $m = Get-TailPaths @(
            'E:\a\b\c\d\x',
            'E:\a\b\z\d\x'
        )
        $m['E:\a\b\c\d\x'] | Should -Be 'c/d/x'
        $m['E:\a\b\z\d\x'] | Should -Be 'z/d/x'
    }
    It '路径整个相同（不可能但防御）→ 停在 2 级不死循环' {
        $m = Get-TailPaths @('E:\a\b', 'E:\a\b')
        $m['E:\a\b'] | Should -Be 'a/b'
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5; Invoke-Pester -Path 'tests/Display2.Tests.ps1' -Output Minimal -PassThru | Select-Object PassedCount, FailedCount"`
Expected: FAIL——函数未定义。

- [ ] **Step 3: 实现（追加到 Display.ps1 末尾）**

```powershell
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

# 路径尾部（决策 18/19：默认 2 级，冲突时逐级加深直到区分，路径耗尽即停）
function Get-TailPaths {
    param([string[]]$Paths)
    $levels = @{}
    foreach ($p in ($Paths | Select-Object -Unique)) { $levels[$p] = 2 }
    while ($true) {
        $tails = @{}
        foreach ($p in $levels.Keys) { $tails[$p] = (Get-PathTail $p $levels[$p]) }
        # 找出有冲突的尾部值，冲突组内能加深级的加深；全部不能再加就退出
        $conflicted = @($tails.Values | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
        if ($conflicted.Count -eq 0) { break }
        $extended = $false
        foreach ($p in ($tails.Keys | Where-Object { $conflicted -contains $tails[$_] })) {
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
```

- [ ] **Step 4: 运行确认通过**

Run: 同 Step 2。
Expected: PassedCount = 10, FailedCount = 0。

- [ ] **Step 5: Commit**

```bash
git add cct/Display.ps1 tests/Display2.Tests.ps1
git commit -m "feat(cct): 相对时间格式化与路径尾部级数动态调整（Task 2）"
```

---

### Task 3: JSON 字段提取（单文件 → 会话记录）

**Files:**
- Create: `cct/Data.ps1`
- Test: `tests/DataExtract.Tests.ps1`

**Interfaces:**
- Consumes: 无
- Produces: `Read-CctSessionFile([string]$Path, [int]$MinUserMsgs = 10) → [pscustomobject]`，属性：`SessionId`（文件名去 .jsonl）、`Cwd`（最后一条 cwd，无则 $null）、`LastTimestamp`（[datetime] UTC，无则 $null）、`Title`、`TitleType`（'custom'/'ai'/$null）、`UserMsgs`（真实用户消息数，早停时为「≥MinUserMsgs 的下界」）、`HasRealUserMsg`（bool，是否含 ≥1 条真实用户消息——用于跳过 `/clear` 空壳）。Task 4/11 消费。

**测试数据构造约定**（Task 3/4/5 共用）：在 `BeforeAll` 里写一个 `New-TestJsonl` 帮助函数，用 `[System.IO.File]::WriteAllLines` 写 UTF-8 无 BOM。每行是手工构造的 JSON 字符串（单引号 here-string 拼接，`"` 转义成 `\"`），例如：

```powershell
function New-TestJsonl {
    param([string]$Dir, [string]$SessionId, [string[]]$Lines)
    $path = Join-Path $Dir "$SessionId.jsonl"
    [System.IO.File]::WriteAllLines($path, $Lines, [System.Text.UTF8Encoding]::new($false))
    return $path
}
# user 消息行模板（content 为字符串）：
'{"type":"user","cwd":"C:\\t","timestamp":"2026-08-27T01:00:00.000Z","message":{"role":"user","content":"你好"},"uuid":"u1","parentUuid":null}'
# tool_result 回传行（不计入 UserMsgs）：
'{"type":"user","cwd":"C:\\t","timestamp":"2026-08-27T01:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"uuid":"u2","parentUuid":"u1"}'
# isMeta 行（不计入）：
'{"type":"user","isMeta":true,"cwd":"C:\\t","timestamp":"2026-08-27T01:00:02.000Z","message":{"role":"user","content":"meta"},"uuid":"u3","parentUuid":"u2"}'
# slash command 行（content 以 / 开头，不计入）：
'{"type":"user","cwd":"C:\\t","timestamp":"2026-08-27T01:00:03.000Z","message":{"role":"user","content":"/clear"},"uuid":"u4","parentUuid":"u3"}'
# custom-title 行：
'{"type":"custom-title","customTitle":"账号调优","sessionId":"s1"}'
# ai-title 行：
'{"type":"ai-title","aiTitle":"git status概览","sessionId":"s1"}'
```

- [ ] **Step 1: 写失败测试**

`tests/DataExtract.Tests.ps1`（`$env:TEMP` 下建临时目录，AfterAll 清理）：

```powershell
BeforeAll {
    . "$PSScriptRoot\..\cct\Data.ps1"
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
    It '早停：满 10 条真实用户消息停止读取（后续行不再解析）' {
        $lines = for ($i = 1; $i -le 15; $i++) {
            '{"type":"user","cwd":"C:\\t","timestamp":"2026-08-27T01:00:00.000Z","message":{"role":"user","content":"m' + $i + '"},"uuid":"u' + $i + '","parentUuid":null}'
        }
        # 第 12 行之后放一个「应该读不到」的更晚 timestamp
        $lines[13] = '{"type":"user","cwd":"C:\\t","timestamp":"2026-12-31T23:59:59.000Z","message":{"role":"user","content":"late"},"uuid":"uX","parentUuid":null}'
        $p = New-TestJsonl 's-stop' $lines
        $r = Read-CctSessionFile $p
        $r.UserMsgs | Should -BeExactly 10
        # 早停后 LastTimestamp 不能来自读不到的行
        $r.LastTimestamp | Should -Not -Be ([datetime]'2026-12-31 23:59:59')
    }
    It '早停文件仍要有标题与 cwd（头尾 50 行窗口内的字段全量提取）' {
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
```

- [ ] **Step 2: 运行确认失败**

Run: `pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5; Invoke-Pester -Path 'tests/DataExtract.Tests.ps1' -Output Minimal -PassThru | Select-Object PassedCount, FailedCount"`
Expected: FAIL——`cct/Data.ps1` 不存在。

- [ ] **Step 3: 实现 Data.ps1**

```powershell
# 数据层：从 ~/.claude/projects 的 jsonl 提取会话记录
# 约束：只用 JsonDocument 流式解析；ref 变量必须先类型化（调研踩坑两次）

function Get-JsonProp {
    param([System.Text.Json.JsonElement]$Element, [string]$Name)
    if ($Element.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return $null }
    $v = [System.Text.Json.JsonElement]::new()
    if ($Element.TryGetProperty($Name, [ref]$v)) { return $v }
    return $null
}

# 判断一条 user 记录是否为「真实用户消息」：非 isMeta、content 是字符串（非 / 开头）或含 text 块
function Test-IsRealUserMsg {
    param([System.Text.Json.JsonElement]$Element)
    $m = Get-JsonProp $Element 'isMeta'
    if ($null -ne $m -and $m.ValueKind -eq [System.Text.Json.JsonValueKind]::True) { return $false }
    $msg = Get-JsonProp $Element 'message'
    if ($null -eq $msg -or $msg.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return $false }
    $c = Get-JsonProp $msg 'content'
    if ($null -eq $c) { return $false }
    if ($c.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
        $s = $c.GetString()
        if ($s.StartsWith('/')) { return $false }   # slash command（如 /clear）
        return $true
    }
    if ($c.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $c.EnumerateArray()) {
            $it = Get-JsonProp $item 'type'
            if ($null -ne $it -and $it.GetString() -eq 'text') { return $true }
        }
    }
    return $false
}

# 读取单个会话文件：全量流式（早停：数满 MinUserMsgs 停）
function Read-CctSessionFile {
    param([string]$Path, [int]$MinUserMsgs = 10)

    $sessionId = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $cwd = $null; $lastTs = $null
    $title = $null; $titleType = $null
    $userMsgs = 0

    $fs = $null; $sr = $null
    try {
        $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = [System.IO.StreamReader]::new($fs)
        while ($null -ne ($line = $sr.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $doc = $null
            try { $doc = [System.Text.Json.JsonDocument]::Parse($line) } catch { continue }
            try {
                $el = $doc.RootElement
                $typeEl = Get-JsonProp $el 'type'
                if ($null -eq $typeEl) { continue }
                $type = $typeEl.GetString()

                $w = Get-JsonProp $el 'cwd'
                if ($null -ne $w) { $cwd = $w.GetString() }
                $t = Get-JsonProp $el 'timestamp'
                if ($null -ne $t) {
                    $parsed = [datetime]::MinValue
                    if ([datetime]::TryParse($t.GetString(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed)) {
                        $lastTs = $parsed
                    }
                }

                if ($type -eq 'user') {
                    if (Test-IsRealUserMsg $el) {
                        $userMsgs++
                        if ($userMsgs -ge $MinUserMsgs) {
                            # 早停：字段已提取的仍然有效（cwd/ts 顺序位置在前 5 行的概率 99.6%）
                            $doc.Dispose()
                            break
                        }
                    }
                }
                elseif ($type -eq 'custom-title') {
                    $v = Get-JsonProp $el 'customTitle'
                    if ($null -ne $v) { $title = $v.GetString(); $titleType = 'custom' }
                }
                elseif ($type -eq 'ai-title') {
                    $v = Get-JsonProp $el 'aiTitle'
                    # custom 已有则不覆盖（优先级），除非本文件后面又出现 custom
                    if ($null -ne $v -and $titleType -ne 'custom') { $title = $v.GetString(); $titleType = 'ai' }
                }
            } finally {
                if ($doc) { $doc.Dispose() }
            }
        }
    } catch {
        # 读取失败（文件被占用等）：返回已提取的部分
    } finally {
        if ($sr) { $sr.Dispose() }
        if ($fs) { $fs.Dispose() }
    }

    return [pscustomobject]@{
        SessionId      = $sessionId
        Cwd            = $cwd
        LastTimestamp  = $lastTs
        Title          = $title
        TitleType      = $titleType
        UserMsgs       = $userMsgs
        HasRealUserMsg = ($userMsgs -ge 1)
    }
}
```

> 实现注意：早停 break 后的尾部字段（最后一条 timestamp、尾部 custom-title）可能缺失。
> 这没关系——**消息数 ≥10 的文件早停后，它的角色只是「计数达标」，排序和标题用同目录其他最新文件即可**
> （Task 4 聚合时处理：同 (cwd,title) 组内 LastTimestamp/Title 取自「最新有实质内容的文件」，
> 而 UserMsgs 达标与否每个文件独立判断）。**但 ai-title 优先级有个坑**：先 custom 后 ai 的顺序里
> ai 不覆盖 custom 是对的；但**先 ai 后 custom** 时 custom 应覆盖 ai——上面的实现已处理（custom
> 分支无条件覆盖）。若测试发现标题取错，检查这两个分支的顺序。

- [ ] **Step 4: 运行确认通过**

Run: 同 Step 2。
Expected: PassedCount = 8, FailedCount = 0。

- [ ] **Step 5: Commit**

```bash
git add cct/Data.ps1 tests/DataExtract.Tests.ps1
git commit -m "feat(cct): 会话文件字段提取与消息计数早停（Task 3）"
```

---

### Task 4: 扫描目录 + 排除规则 + 聚合成列表项

**Files:**
- Modify: `cct/Data.ps1`（追加）
- Test: `tests/DataAggregate.Tests.ps1`

**Interfaces:**
- Consumes: `Read-CctSessionFile`（Task 3）
- Produces: `Get-CctTasks([string]$Root = "$env:USERPROFILE\.claude\projects", [int]$MinUserMsgs = 10, [string[]]$ExcludePatterns = @('ConfigBackup')) → [pscustomobject[]]`，每项属性见 spec 3.7：`Kind`('Folder'/'Session')、`Path`、`Name`、`Subtitle`（仅 Folder）、`LastActive`（本地时间 [datetime]）、`SessionId`（仅 Session）、`GroupKey`、`TitleType`（仅 Session：'custom'/'ai'）。输出顺序：文件夹按 LastActive 降序，会话项紧跟所属文件夹（组内按 LastActive 降序）。Task 8（界面）、Task 10（执行）消费。**注意：不输出 `TailPath` 和 `UserMsgs`**——TailPath 是显示层概念，由界面层用 `Get-TailPaths` 现算（Task 8）。

**测试目录结构**（模拟 `~/.claude/projects`，两个编码目录名随意）：

```
$tmp/
├── E---taskA---/                  # 模拟编码目录
│   ├── a1.jsonl                   # taskA 目录，含 ai-title「git status概览」，3 条消息
│   ├── a2.jsonl                   # 同目录，custom-title「账号调优」，15 条消息，更晚
│   ├── a3.jsonl                   # 同目录，custom-title「codex伪装」，12 条消息，最早
│   └── agent-xxx.jsonl            # agent 子会话，应被文件名排除
├── E---taskB---/
│   ├── b1.jsonl                   # taskB 目录，无标题，4 条消息（全部会话 <10 → 文件夹项仍在）
│   └── journal.jsonl              # workflow 日志，应被排除
└── E---ConfigBackup---/
    └── cb1.jsonl                  # 备份目录，应被 ConfigBackup 模式排除
```

外加 `$tmp2/`（模拟存在的任务目录）+ `$tmpNonExist`（不创建，模拟已删除目录）。

- [ ] **Step 1: 写失败测试**

`tests/DataAggregate.Tests.ps1`：

```powershell
BeforeAll {
    . "$PSScriptRoot\..\cct\Data.ps1"
    $script:tmpRoot = Join-Path $env:TEMP ("cct_agg_" + [guid]::NewGuid().ToString('N'))
    # 模拟 projects 目录
    $script:proj = Join-Path $script:tmpRoot 'projects'
    # 模拟真实存在的任务目录
    $script:taskA = Join-Path $script:tmpRoot 'taskA'
    $script:taskB = Join-Path $script:tmpRoot 'taskB'
    $script:taskC = Join-Path $script:tmpRoot 'taskC'
    New-Item -ItemType Directory -Force "$script:proj\E---taskA---", "$script:proj\E---taskB---", "$script:proj\E---taskC---", "$script:proj\E---ConfigBackup---", $script:taskA, $script:taskB, $script:taskC | Out-Null
    $script:taskDeleted = Join-Path $script:tmpRoot '已删除目录'   # 不创建

    function New-TestJsonl {
        param([string]$Dir, [string]$SessionId, [string]$Cwd, [string]$Ts, [int]$Msgs, [string]$Title = $null, [string]$TitleType = $null)
        $lines = [System.Collections.Generic.List[string]]::new()
        if ($Title) {
            $key = if ($TitleType -eq 'custom') { 'customTitle' } else { 'aiTitle' }
            $lines.Add(('{"type":"' + $TitleType + '-title","' + $key + '":"' + $Title + '","sessionId":"' + $SessionId + '"}'))
        }
        for ($i = 1; $i -le $Msgs; $i++) {
            $lines.Add(('{"type":"user","cwd":"' + ($Cwd -replace '\\', '\\\\') + '","timestamp":"' + $Ts + '","message":{"role":"user","content":"m' + $i + '"},"uuid":"u' + $i + '","parentUuid":null}'))
        }
        $path = Join-Path $Dir "$SessionId.jsonl"
        [System.IO.File]::WriteAllLines($path, $lines, [System.Text.UTF8Encoding]::new($false))
        return $path
    }

    # taskA：两个手动命名 + 一个自动命名（3 条，低于阈值）+ agent 文件
    New-TestJsonl "$script:proj\E---taskA---" 'a3' $script:taskA '2026-08-25T10:00:00.000Z' 12 'codex伪装' 'custom'
    New-TestJsonl "$script:proj\E---taskA---" 'a1' $script:taskA '2026-08-26T10:00:00.000Z' 3 'git status概览' 'ai'
    New-TestJsonl "$script:proj\E---taskA---" 'a2' $script:taskA '2026-08-27T10:00:00.000Z' 15 '账号调优' 'custom'
    New-TestJsonl "$script:proj\E---taskA---" 'agent-xyz' $script:taskA '2026-08-27T11:00:00.000Z' 99
    # taskB：全部会话 <10 条 + journal
    New-TestJsonl "$script:proj\E---taskB---" 'b1' $script:taskB '2026-08-20T10:00:00.000Z' 4
    [System.IO.File]::WriteAllLines("$script:proj\E---taskB---\journal.jsonl", @('{"type":"workflow"}'), [System.Text.UTF8Encoding]::new($false))
    # taskC：只有一个自动命名 12 条（无手动项 → 保底自动项出现）+ /clear 空壳链尾
    New-TestJsonl "$script:proj\E---taskC---" 'c2' $script:taskC '2026-08-27T09:00:00.000Z' 0 '整理用量接口' 'ai'
    New-TestJsonl "$script:proj\E---taskC---" 'c1' $script:taskC '2026-08-26T09:00:00.000Z' 12 '整理用量接口' 'ai'
    # 已删除目录
    New-TestJsonl "$script:proj\E---taskC---" 'c9' $script:taskDeleted '2026-08-27T12:00:00.000Z' 5
    # ConfigBackup
    New-TestJsonl "$script:proj\E---ConfigBackup---" 'cb1' $script:taskA '2026-08-27T12:00:00.000Z' 20 '备份会话' 'custom'
}
AfterAll {
    if (Test-Path $script:tmpRoot) { Remove-Item -Recurse -Force $script:tmpRoot }
}

Describe 'Get-CctTasks 聚合' {
    BeforeAll { $script:tasks = @(Get-CctTasks -Root $script:proj -MinUserMsgs 10 -ExcludePatterns @('ConfigBackup')) }

    It '输出 taskA 文件夹项（手动命名项目录）' {
        $f = $script:tasks | Where-Object { $_.Kind -eq 'Folder' -and $_.Path -eq $script:taskA }
        $f | Should -Not -BeNullOrEmpty
        $f.Name | Should -Be 'taskA'
    }
    It 'taskA 副标题 = 最近会话标题（a2 账号调优最新）' {
        ($script:tasks | Where-Object { $_.Kind -eq 'Folder' -and $_.Path -eq $script:taskA }).Subtitle | Should -Be '账号调优'
    }
    It 'taskA 会话项：手动命名全保留（codex伪装 12 条 + 账号调优 15 条），自动命名 3 条不保留（已有手动项，决策 36）' {
        $sessions = @($script:tasks | Where-Object { $_.Kind -eq 'Session' -and $_.Path -eq $script:taskA })
        $sessions.Count | Should -Be 2
        ($sessions | Where-Object Name -eq '账号调优') | Should -Not -BeNullOrEmpty
        ($sessions | Where-Object Name -eq 'codex伪装') | Should -Not -BeNullOrEmpty
        ($sessions | Where-Object Name -eq 'git status概览') | Should -BeNullOrEmpty
    }
    It '手动命名不受 10 条阈值影响：给 a3 只留 3 条消息也应保留' {
        # 此测试由「a3 有 12 条」间接覆盖；再显式构造一个 3 条手动命名文件
        New-TestJsonl "$script:proj\E---taskA---" 'a4' $script:taskA '2026-08-24T10:00:00.000Z' 3 '签到' 'custom'
        $tasks2 = @(Get-CctTasks -Root $script:proj -MinUserMsgs 10 -ExcludePatterns @('ConfigBackup'))
        ($tasks2 | Where-Object { $_.Kind -eq 'Session' -and $_.Path -eq $script:taskA -and $_.Name -eq '签到' }) | Should -Not -BeNullOrEmpty
    }
    It '会话项 SessionId = 该 (cwd,title) 组内最新有实质内容的文件（a2 而非更晚的 agent 文件）' {
        $s = $script:tasks | Where-Object { $_.Kind -eq 'Session' -and $_.Name -eq '账号调优' }
        $s.SessionId | Should -Be 'a2'
    }
    It 'taskB：全部会话 <10 条，文件夹项仍在（决策 33），无会话项（无标题不算候选，决策 37）' {
        $f = $script:tasks | Where-Object { $_.Kind -eq 'Folder' -and $_.Path -eq $script:taskB }
        $f | Should -Not -BeNullOrEmpty
        $f.Subtitle | Should -BeNullOrEmpty      # b1 无标题 → 副标题留空（决策 38）
        @($script:tasks | Where-Object { $_.Kind -eq 'Session' -and $_.Path -eq $script:taskB }).Count | Should -Be 0
    }
    It 'taskC：无手动项，自动命名 >10 条的留最新一个作保底（决策 35/36）' {
        $sessions = @($script:tasks | Where-Object { $_.Kind -eq 'Session' -and $_.Path -eq $script:taskC })
        $sessions.Count | Should -Be 1
        $sessions[0].Name | Should -Be '整理用量接口'
        $sessions[0].SessionId | Should -Be 'c1'   # c2 是 0 条空壳，跳过（发现 22）
        $sessions[0].TitleType | Should -Be 'ai'
    }
    It 'taskC 副标题 = c2 的标题（最近会话，尽管它是空壳但有标题）' {
        ($script:tasks | Where-Object { $_.Kind -eq 'Folder' -and $_.Path -eq $script:taskC }).Subtitle | Should -Be '整理用量接口'
    }
    It '已删除目录不出现（决策 9）' {
        $script:tasks | Where-Object { $_.Path -eq $script:taskDeleted } | Should -BeNullOrEmpty
    }
    It '排除 agent- 前缀与 journal.jsonl（决策 12）：agent-xyz 的 99 条与 journal 都不产生项' {
        # taskA 只能有 2 个会话项（若 agent 未排除会多出项）
        @($script:tasks | Where-Object { $_.Kind -eq 'Session' -and $_.Path -eq $script:taskA }).Count | Should -Be 2
        # taskB 的 journal 无 cwd 不产生项（已由上面的 0 会话项覆盖）
    }
    It 'ConfigBackup 目录排除' {
        $script:tasks | Where-Object { $_.Name -eq '备份会话' -or $_.Subtitle -eq '备份会话' } | Should -BeNullOrEmpty
    }
    It '排序：文件夹按最近活动降序，会话项紧跟所属文件夹（决策 15）' {
        # taskA 最近活动 08-27（a2），taskC 08-27（c2 09:00 → 但 c9 已删除不计），taskB 08-20
        # taskA(08-27T10:00) > taskC(08-27T09:00) > taskB(08-20)
        $folders = @($script:tasks | Where-Object Kind -eq 'Folder')
        $folders[0].Path | Should -Be $script:taskA
        $folders[1].Path | Should -Be $script:taskC
        $folders[2].Path | Should -Be $script:taskB
        # taskA 的会话项紧跟其后：索引 1 = 账号调优（组内最新），索引 2 = codex伪装
        $script:tasks[1].Name | Should -Be '账号调优'
        $script:tasks[2].Name | Should -Be 'codex伪装'
        $script:tasks[3].Kind | Should -Be 'Folder'   # 下一个是 taskC
    }
    It 'LastActive 转本地时间（UTC+8）' {
        $f = $script:tasks | Where-Object { $_.Kind -eq 'Folder' -and $_.Path -eq $script:taskB }
        $f.LastActive | Should -Be ([datetime]'2026-08-20 18:00:00')   # 10:00Z + 8h
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5; Invoke-Pester -Path 'tests/DataAggregate.Tests.ps1' -Output Minimal -PassThru | Select-Object PassedCount, FailedCount"`
Expected: FAIL——`Get-CctTasks` 未定义。

- [ ] **Step 3: 实现（追加到 Data.ps1）**

```powershell
# 扫描 projects 目录并聚合成列表项（spec 3.3/3.5/3.6）
function Get-CctTasks {
    [CmdletBinding()]
    param(
        [string]$Root = (Join-Path $env:USERPROFILE '.claude\projects'),
        [int]$MinUserMsgs = 10,
        [string[]]$ExcludePatterns = @('ConfigBackup')
    )

    # 1. 收集文件（排除 agent-/journal.jsonl/排除模式）
    $files = Get-ChildItem -LiteralPath $Root -Recurse -Filter *.jsonl -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -ne 'journal.jsonl' -and $_.Name -notlike 'agent-*'
    }
    if ($ExcludePatterns) {
        $files = $files | Where-Object {
            $p = $_.FullName
            -not ($ExcludePatterns | Where-Object { $p -like "*$_*" })
        }
    }

    # 2. 逐文件提取
    $sessions = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $files) {
        $r = Read-CctSessionFile -Path $f.FullName -MinUserMsgs $MinUserMsgs
        if ($r.Cwd -and $r.LastTimestamp) { $sessions.Add($r) }
    }

    # 3. 过滤失效目录（worktree 残留 + 已删除）
    $valid = @($sessions | Where-Object {
        $_.Cwd -notmatch '\.claude[\\/]worktrees' -and (Test-Path -LiteralPath $_.Cwd)
    })

    # 4. 按 cwd 分组
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($g in ($valid | Group-Object Cwd)) {
        $folderPath = $g.Name
        $folderName = Split-Path -Leaf $folderPath
        $byTime = @($g.Group | Sort-Object LastTimestamp -Descending)
        $latest = $byTime[0]

        # 会话项判定（spec 3.5）
        $manualGroups = @($g.Group | Where-Object TitleType -eq 'custom' | Group-Object Title)
        $sessionItems = [System.Collections.Generic.List[object]]::new()
        foreach ($mg in $manualGroups) {
            # resume 目标：组内最新「有实质内容」的文件（发现 22：跳过 /clear 空壳）
            $target = @($mg.Group | Where-Object HasRealUserMsg | Sort-Object LastTimestamp -Descending | Select-Object -First 1)
            if (-not $target) { $target = @($mg.Group | Sort-Object LastTimestamp -Descending | Select-Object -First 1) }  # 全空壳的防御回退
            $sessionItems.Add([pscustomobject]@{
                Kind = 'Session'; Path = $folderPath; Name = $mg.Name
                Subtitle = $null
                LastActive = $target[0].LastTimestamp.ToLocalTime()
                SessionId = $target[0].SessionId
                GroupKey = $folderPath; TitleType = 'custom'
            })
        }
        if ($manualGroups.Count -eq 0) {
            # 保底自动项：>MinUserMsgs 的 ai-title 里最新一个（决策 35/36/37）
            $aiBig = @($g.Group | Where-Object { $_.TitleType -eq 'ai' -and $_.UserMsgs -gt $MinUserMsgs } | Sort-Object LastTimestamp -Descending)
            if ($aiBig.Count -gt 0) {
                $target = @($aiBig | Where-Object HasRealUserMsg | Select-Object -First 1)
                if (-not $target) { $target = @($aiBig | Select-Object -First 1) }
                $sessionItems.Add([pscustomobject]@{
                    Kind = 'Session'; Path = $folderPath; Name = $target[0].Title
                    Subtitle = $null
                    LastActive = $target[0].LastTimestamp.ToLocalTime()
                    SessionId = $target[0].SessionId
                    GroupKey = $folderPath; TitleType = 'ai'
                })
            }
        }

        # 文件夹项（副标题 = 最近会话标题，无标题留空，决策 30/38）
        $folderItem = [pscustomobject]@{
            Kind = 'Folder'; Path = $folderPath; Name = $folderName
            Subtitle = $latest.Title
            LastActive = $latest.LastTimestamp.ToLocalTime()
            SessionId = $null; GroupKey = $folderPath; TitleType = $null
        }
        $items.Add($folderItem)
        foreach ($s in ($sessionItems | Sort-Object LastActive -Descending)) { $items.Add($s) }
    }

    # 5. 文件夹间按最近活动降序，会话项紧跟所属文件夹（两步法：先排序文件夹，再挂会话项）
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($f in ($items | Where-Object Kind -eq 'Folder' | Sort-Object LastActive -Descending)) {
        $result.Add($f)
        foreach ($s in ($items | Where-Object { $_.Kind -eq 'Session' -and $_.GroupKey -eq $f.GroupKey } | Sort-Object LastActive -Descending)) {
            $result.Add($s)
        }
    }
    return $result
}
```

- [ ] **Step 4: 运行确认通过**

Run: 同 Step 2。
Expected: PassedCount = 12, FailedCount = 0。

> 若「排序」测试失败：检查两步法是否真的按 LastActive 降序排文件夹、会话项组内降序。若「taskC 副标题」失败：确认副标题取 `$latest.Title`（c2 最新有标题，即使 0 条消息）——注意 c2 的 LastTimestamp 是 08-27T09:00 比 c1 的 08-26 晚，所以 latest = c2。

- [ ] **Step 5: Commit**

```bash
git add cct/Data.ps1 tests/DataAggregate.Tests.ps1
git commit -m "feat(cct): 目录扫描、排除规则与列表项聚合排序（Task 4）"
```

---

### Task 5: 配置读写（Config.ps1）

**Files:**
- Create: `cct/Config.ps1`
- Modify: `cct/cct.psm1`（加 dot-source 行）
- Test: `tests/Config.Tests.ps1`

**Interfaces:**
- Consumes: 无
- Produces: `Get-CctConfig([string]$Path = "$env:USERPROFILE\.cct\config.json") → [pscustomobject]`（不存在则创建默认并返回；spec 6 的 5 个字段：`launchCommand`、`resumeCommand`、`excludePathPatterns`、`maxVisibleRows`、`minUserMessages`）。Task 6/10 消费。

- [ ] **Step 1: 写失败测试**

`tests/Config.Tests.ps1`：

```powershell
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
        $cfg.excludePathPatterns | Should -Contain 'ConfigBackup'
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
```

- [ ] **Step 2: 运行确认失败**

Run: `pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5; Invoke-Pester -Path 'tests/Config.Tests.ps1' -Output Minimal -PassThru | Select-Object PassedCount, FailedCount"`
Expected: FAIL。

- [ ] **Step 3: 实现 Config.ps1**

```powershell
# 配置读写（spec 6：~/.cct/config.json，首次自动生成默认值）

function Get-CctConfig {
    param([string]$Path = (Join-Path $env:USERPROFILE '.cct\config.json'))

    $default = [pscustomobject]@{
        launchCommand      = 'claude --dangerously-skip-permissions -c'
        resumeCommand      = 'claude --dangerously-skip-permissions --resume {sessionId}'
        excludePathPatterns = @('.claude/worktrees/', 'ConfigBackup')
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
```

`cct/cct.psm1` 追加一行：

```powershell
. (Join-Path $moduleRoot 'Config.ps1')
```

- [ ] **Step 4: 运行确认通过**

Run: 同 Step 2。
Expected: PassedCount = 3, FailedCount = 0。

- [ ] **Step 5: Commit**

```bash
git add cct/Config.ps1 cct/cct.psm1 tests/Config.Tests.ps1
git commit -m "feat(cct): 配置文件读写与默认值（Task 5）"
```

---

### Task 6: 搜索过滤

**Files:**
- Modify: `cct/Data.ps1`（追加）
- Test: `tests/Search.Tests.ps1`

**Interfaces:**
- Consumes: Task 4 的列表项结构
- Produces: `Filter-CctTasks([pscustomobject[]]$Tasks, [string]$Query) → [pscustomobject[]]`（决策 16：匹配文件夹名+会话标题+全路径并集，不区分大小写子串；会话项命中时父文件夹一起显示，决策 15 注）。Task 8 消费。

- [ ] **Step 1: 写失败测试**

`tests/Search.Tests.ps1`：

```powershell
BeforeAll {
    . "$PSScriptRoot\..\cct\Data.ps1"
    $script:tasks = @(
        [pscustomobject]@{ Kind='Folder'; Path='E:\个人\工具\管理_sub2api'; Name='管理_sub2api'; Subtitle='账号3244请求头覆写'; GroupKey='E:\个人\工具\管理_sub2api' }
        [pscustomobject]@{ Kind='Session'; Path='E:\个人\工具\管理_sub2api'; Name='账号调优'; GroupKey='E:\个人\工具\管理_sub2api' }
        [pscustomobject]@{ Kind='Folder'; Path='E:\个人\工作\写日志'; Name='写日志'; Subtitle='日志模板整理'; GroupKey='E:\个人\工作\写日志' }
    )
}

Describe 'Filter-CctTasks（决策 16：名+标题+全路径并集，子串，不区分大小写）' {
    It '空查询返回全部' {
        @(Filter-CctTasks $script:tasks '').Count | Should -Be 3
    }
    It '匹配文件夹名' {
        $r = @(Filter-CctTasks $script:tasks 'sub2api')
        $r.Count | Should -Be 2      # 文件夹 + 它的会话项
        $r[0].Kind | Should -Be 'Folder'
    }
    It '匹配会话标题（副标题也算）' {
        @(Filter-CctTasks $script:tasks '账号调优').Count | Should -Be 2   # 会话项 + 父文件夹上下文
    }
    It '匹配全路径（虽然不显示全路径）' {
        $r = @(Filter-CctTasks $script:tasks '工作')
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be '写日志'
    }
    It '不区分大小写' {
        @(Filter-CctTasks $script:tasks 'SUB2API').Count | Should -Be 2
    }
    It '中文子串' {
        @(Filter-CctTasks $script:tasks '日志').Count | Should -Be 1   # 命中写日志文件夹（Name 含「日志」，Subtitle 也含但同一项去重）
    }
    It '无命中返回空' {
        @(Filter-CctTasks $script:tasks 'zzzzz').Count | Should -Be 0
    }
}
```

> 注意「匹配会话标题」测试的预期：会话项「账号调优」命中 → 父文件夹「管理_sub2api」一起显示（决策 15 的上下文规则）。但文件夹项本身的 Subtitle「账号3244请求头覆写」也含「账号」子串会命中文件夹。所以「账号调优」查询命中集合 = {会话项(账号调优), 文件夹(管理_sub2api 因 Subtitle 含「账号」)}，共 2 项——测试预期正确。「中文子串」查询「日志」命中「写日志」（Name 含）+「日志模板整理」（Subtitle 含）→ 同一个文件夹项一次命中（去重后 1 项），断言已按 1 写。

- [ ] **Step 2: 运行确认失败**

Run: `pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5; Invoke-Pester -Path 'tests/Search.Tests.ps1' -Output Minimal -PassThru | Select-Object PassedCount, FailedCount"`
Expected: FAIL。

- [ ] **Step 3: 实现（追加到 Data.ps1）**

```powershell
# 搜索过滤（决策 16：文件夹名+会话标题+全路径并集，不区分大小写子串；会话命中带出父文件夹）
function Filter-CctTasks {
    param([pscustomobject[]]$Tasks, [string]$Query)
    if ([string]::IsNullOrWhiteSpace($Query)) { return $Tasks }
    $q = $Query.ToLowerInvariant()

    $hits = @($Tasks | Where-Object {
        $t = $_
        ($t.Name -and $t.Name.ToLowerInvariant().Contains($q)) -or
        ($t.Subtitle -and $t.Subtitle.ToLowerInvariant().Contains($q)) -or
        ($t.Path -and $t.Path.ToLowerInvariant().Contains($q))
    })
    # 会话项命中 → 父文件夹（同 GroupKey 的 Folder 项）一起显示
    $groupKeys = @($hits | Where-Object Kind -eq 'Session' | ForEach-Object GroupKey)
    $withContext = @($hits) + @($Tasks | Where-Object { $_.Kind -eq 'Folder' -and $groupKeys -contains $_.GroupKey })
    # 保持原顺序去重
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $result = foreach ($it in $withContext) {
        $key = "$($it.Kind)|$($it.Path)|$($it.Name)"
        if ($seen.Add($key)) { $it }
    }
    return @($result)
}
```

- [ ] **Step 4: 运行确认通过**

Run: 同 Step 2。
Expected: PassedCount = 7, FailedCount = 0。

> 若「匹配会话标题」测试失败（实际 3 项而非 2）：检查上下文规则——会话项「账号调优」命中时把文件夹带出，而文件夹的 Subtitle「账号3244请求头覆写」也命中（同一个文件夹已在集合里，去重即可，不应变成两个文件夹项）。

- [ ] **Step 5: Commit**

```bash
git add cct/Data.ps1 tests/Search.Tests.ps1
git commit -m "feat(cct): 搜索过滤与会话项父文件夹上下文（Task 6）"
```

---

### Task 7: 界面层——帧渲染（纯函数，可测试）

**Files:**
- Create: `cct/Selector.ps1`
- Test: `tests/SelectorRender.Tests.ps1`

**Interfaces:**
- Consumes: `Get-DisplayWidth`/`Pad-DisplayRight`/`Truncate-Display`/`Get-RelativeTime`/`Get-TailPaths`（Task 1/2）、Task 4 列表项结构
- Produces: `New-CctFrame([pscustomobject[]]$Tasks, [int]$SelectedIndex, [string]$Query, [int]$WindowWidth, [int]$MaxRows, [datetime]$Now) → [string[]]`——生成整帧行数组（含 ANSI 颜色码），**不写控制台**。Task 8 主循环消费。行结构（spec 4.1）：行 0 = 搜索行（左：`搜索> ` + 输入或淡色占位「输入关键词，按Enter过滤」；右：未过滤 `共 N 项` / 过滤后 `M/N`，用 PadRight 撑到 WindowWidth 后右对齐）、空行、列表行（选中行前缀 `❯ `，未选中 `  `；会话项缩进 `    └ `；列：主列 22 字符显示宽 + 副标题 16 + 时间 8 + 淡色尾路径）、尾部帮助行 `  ↑↓ 选择   回车 启动   Esc 取消`。

- [ ] **Step 1: 写失败测试**

`tests/SelectorRender.Tests.ps1`：

```powershell
BeforeAll {
    . "$PSScriptRoot\..\cct\Display.ps1"
    . "$PSScriptRoot\..\cct\Selector.ps1"
    $script:esc = [char]27
    $script:now = [datetime]'2026-08-27 12:00:00'
    $script:tasks = @(
        [pscustomobject]@{ Kind='Folder'; Path='E:\个人\工具\管理_sub2api'; Name='管理_sub2api'; Subtitle='账号调优'; LastActive=[datetime]'2026-08-27 11:00:00'; SessionId=$null; GroupKey='E:\个人\工具\管理_sub2api' }
        [pscustomobject]@{ Kind='Session'; Path='E:\个人\工具\管理_sub2api'; Name='账号调优'; Subtitle=$null; LastActive=[datetime]'2026-08-26 11:00:00'; SessionId='a2'; GroupKey='E:\个人\工具\管理_sub2api' }
        [pscustomobject]@{ Kind='Folder'; Path='E:\个人\工作\写日志'; Name='写日志'; Subtitle=$null; LastActive=[datetime]'2026-08-26 09:00:00'; SessionId=$null; GroupKey='E:\个人\工作\写日志' }
    )
}

Describe 'New-CctFrame' {
    It '第一行是搜索行：空查询显示淡色占位 + 右侧共 N 项（决策 39/40）' {
        $frame = @(New-CctFrame $script:tasks 0 '' 80 10 $script:now)
        $first = $frame[0] -replace "$script:esc\[[0-9;?]*[a-zA-Z]", ''    # 剥 ANSI 看纯文本
        $first | Should -Match '搜索> '
        $first | Should -Match '输入关键词，按Enter过滤'
        $first | Should -Match '共 3 项'
    }
    It '有查询时显示输入内容 + M/N 计数' {
        # 手工传 2 项 + TotalCount=3，模拟过滤后状态（不依赖 Data.ps1 的 Filter）
        $two = @($script:tasks[0], $script:tasks[1])
        $frame = @(New-CctFrame $two 0 'sub' 80 10 $script:now 3)
        $first = $frame[0] -replace "$script:esc\[[0-9;?]*[a-zA-Z]", ''
        $first | Should -Match '搜索> sub'
        $first | Should -Match '2/3'
    }
    It '选中行有 ❯ 前缀，会话项有缩进 └' {
        $frame = @(New-CctFrame $script:tasks 0 '' 80 10 $script:now)
        ($frame[2] -replace "$script:esc\[[0-9;?]*[a-zA-Z]", '') | Should -Match '^❯ 管理_sub2api'
        ($frame[3] -replace "$script:esc\[[0-9;?]*[a-zA-Z]", '') | Should -Match '^    └ 账号调优'
    }
    It '选中行用反白，未选中路径列淡色（剥 ANSI 后纯文本一致，带 ANSI 时颜色码不同）' {
        $frame = @(New-CctFrame $script:tasks 0 '' 80 10 $script:now)
        $frame[2] | Should -Match [regex]::Escape("$script:esc[7m")      # 选中反白
        $frame[4] | Should -Match [regex]::Escape("$script:esc[90m")     # 未选中淡色
    }
    It '超过 MaxRows 截断显示 + 「↓ 还有 N 项」' {
        $frame = @(New-CctFrame $script:tasks 0 '' 80 2 $script:now)
        $plain = $frame | ForEach-Object { $_ -replace "$script:esc\[[0-9;?]*[a-zA-Z]", '' }
        ($plain | Where-Object { $_ -match '还有' }) | Should -Not -BeNullOrEmpty
    }
    It '最后一行是帮助行' {
        $frame = @(New-CctFrame $script:tasks 0 '' 80 10 $script:now)
        ($frame[-1] -replace "$script:esc\[[0-9;?]*[a-zA-Z]", '') | Should -Match '↑↓ 选择'
    }
    It '每行显示宽度不超过 WindowWidth（含中文）' {
        . "$PSScriptRoot\..\cct\Display.ps1"
        $frame = @(New-CctFrame $script:tasks 0 '' 80 10 $script:now)
        foreach ($line in $frame) {
            $plain = $line -replace "$script:esc\[[0-9;?]*[a-zA-Z]", ''
            (Get-DisplayWidth $plain) | Should -BeLessThanOrEqual 80
        }
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5; Invoke-Pester -Path 'tests/SelectorRender.Tests.ps1' -Output Minimal -PassThru | Select-Object PassedCount, FailedCount"`
Expected: FAIL——Selector.ps1 不存在。

- [ ] **Step 3: 实现 Selector.ps1（帧渲染部分）**

```powershell
# 界面层：全屏选择器（spec 4）
# 帧渲染是纯函数（可测）；主循环 + ReadKey 在 Task 8

$script:CctEsc = [char]27

# 生成整帧行数组（不写控制台）
function New-CctFrame {
    param(
        [pscustomobject[]]$Tasks, [int]$SelectedIndex, [string]$Query,
        [int]$WindowWidth, [int]$MaxRows, [datetime]$Now,
        [int]$TotalCount = $Tasks.Count      # 过滤后的 M/N 里 N = 过滤前总数
    )
    $esc = $script:CctEsc
    $cReset = "$esc[0m"; $cDim = "$esc[90m"; $cSel = "$esc[7m"; $cQuery = "$esc[36m"

    $rows = [System.Collections.Generic.List[string]]::new()

    # ---- 行 0：搜索行（决策 39/40）----
    $left = '搜索> '
    if ([string]::IsNullOrEmpty($Query)) {
        $left += $cDim + '输入关键词，按Enter过滤' + $cReset
    } else {
        $left += $Query
    }
    $right = if ([string]::IsNullOrEmpty($Query)) { "共 $TotalCount 项" } else { "$($Tasks.Count)/$TotalCount" }
    $pad = [Math]::Max(1, $WindowWidth - (Get-DisplayWidth ($left -replace "$esc\[[0-9;?]*[a-zA-Z]", '')) - (Get-DisplayWidth $right))
    $rows.Add($left + (' ' * $pad) + $cDim + $right + $cReset)

    $rows.Add('')   # 空行

    # ---- 列表行 ----
    $nameW = 22; $subW = 16; $timeW = 8
    $pathW = [Math]::Max(10, $WindowWidth - $nameW - $subW - $timeW - 6)
    $tails = Get-TailPaths @($Tasks | ForEach-Object Path | Select-Object -Unique)

    # 滚动窗口（决策 31）：选中项保持在窗口内
    $start = 0
    if ($SelectedIndex -ge $MaxRows) { $start = $SelectedIndex - $MaxRows + 1 }
    $end = [Math]::Min($Tasks.Count - 1, $start + $MaxRows - 1)

    for ($i = $start; $i -le $end; $i++) {
        $t = $Tasks[$i]
        $isSel = ($i -eq $SelectedIndex)
        $prefix = if ($t.Kind -eq 'Session') { '    └ ' } elseif ($isSel) { '❯ ' } else { '  ' }
        $name = if ($t.Kind -eq 'Session') { $t.Name } else { $t.Name }
        $mainCol = $prefix + (Truncate-Display $name ($nameW - (Get-DisplayWidth $prefix)))
        $subCol = Pad-DisplayRight (Truncate-Display ($t.Subtitle ?? '') $subW) $subW
        $timeCol = Pad-DisplayRight (Get-RelativeTime $t.LastActive $Now) $timeW
        $tailCol = Truncate-Display ($tails[$t.Path] ?? '') $pathW

        $row = ''
        if ($isSel) { $row += $cSel }
        $row += $mainCol + '  ' + $subCol + '  ' + $timeCol
        if (-not $isSel) { $row += $cDim }
        $row += '  ' + $tailCol + $cReset
        $rows.Add($row)
    }
    $hidden = $Tasks.Count - ($end - $start + 1)
    if ($hidden -gt 0) { $rows.Add($cDim + "  ↓ 还有 $hidden 项" + $cReset) }

    $rows.Add('')
    $rows.Add($cDim + '  ↑↓ 选择   回车 启动   Esc 取消' + $cReset)
    return $rows.ToArray()
}
```

`cct/cct.psm1` 追加：

```powershell
. (Join-Path $moduleRoot 'Selector.ps1')
```

> 实现注意：`(Get-DisplayWidth ($left -replace ...))` 剥 ANSI 后计算宽度的写法可行但啰嗦——更稳的做法是分别记录纯文本再拼颜色。若测试「每行显示宽度不超过 WindowWidth」失败，优先检查 ANSI 剥离正则是否覆盖帧里所有颜色码（`ESC[0m`、`ESC[90m`、`ESC[7m`、`ESC[36m`）。`Get-TailPaths` 的输入应该用**全部任务**的 Path（过滤前），避免过滤后冲突集变化导致尾部级数跳动——本任务先按过滤后集合算（简单），Task 8 集成时若发现级数跳动问题再改为传入全量 Path 集合（记为已知小坑）。

- [ ] **Step 4: 运行确认通过**

Run: 同 Step 2。
Expected: PassedCount = 7, FailedCount = 0。

- [ ] **Step 5: Commit**

```bash
git add cct/Selector.ps1 cct/cct.psm1 tests/SelectorRender.Tests.ps1
git commit -m "feat(cct): 选择器帧渲染纯函数（Task 7）"
```

---

### Task 8: 界面层——主循环 + 按键 + 备用屏幕 + 行 diff 重绘

**Files:**
- Modify: `cct/Selector.ps1`（追加）
- Test: `tests/SelectorLoop.Tests.ps1`

**Interfaces:**
- Consumes: `New-CctFrame`（Task 7）、`Filter-CctTasks`（Task 6）、`Get-CctTasks`（Task 4）
- Produces: `Show-CctSelector([pscustomobject[]]$Tasks, [string]$InitialQuery = '', [int]$MaxRows = 0, [scriptblock]$KeySource = $null) → [pscustomobject]`（选中的项；Esc/Ctrl+C 返回 $null）。`$KeySource` 是可注入的按键枚举器（`Func[ConsoleKeyInfo]`），测试用模拟按键序列驱动；生产传 $null 走 `[Console]::ReadKey($true)`。Task 10 的 `cct` 主函数消费。

- [ ] **Step 1: 写失败测试（DryRun 注入按键序列）**

`tests/SelectorLoop.Tests.ps1`：

```powershell
BeforeAll {
    . "$PSScriptRoot\..\cct\Display.ps1"
    . "$PSScriptRoot\..\cct\Data.ps1"
    . "$PSScriptRoot\..\cct\Selector.ps1"
    $script:tasks = @(
        [pscustomobject]@{ Kind='Folder'; Path='E:\t\a'; Name='alpha'; Subtitle='s1'; LastActive=[datetime]'2026-08-27 11:00:00'; SessionId=$null; GroupKey='E:\t\a' }
        [pscustomobject]@{ Kind='Folder'; Path='E:\t\b'; Name='beta'; Subtitle='s2'; LastActive=[datetime]'2026-08-26 11:00:00'; SessionId=$null; GroupKey='E:\t\b' }
        [pscustomobject]@{ Kind='Folder'; Path='E:\t\c'; Name='gamma'; Subtitle='s3'; LastActive=[datetime]'2026-08-25 11:00:00'; SessionId=$null; GroupKey='E:\t\c' }
    )
    function New-Key([char]$ch, [ConsoleKey]$key) {
        [System.ConsoleKeyInfo]::new($ch, $key, $false, $false, $false)
    }
    # 按键序列枚举器（Show-CctSelector 的 KeySource 协议：每次调用返回下一个 ConsoleKeyInfo，$null 表示序列结束）
    function New-KeySource([System.ConsoleKeyInfo[]]$keys) {
        $i = 0
        { if ($i -lt $keys.Count) { $k = $keys[$i]; $i++; $k } else { $null } }.GetNewClosure()
    }
}

Describe 'Show-CctSelector 交互逻辑（注入按键，不进真备用屏幕）' {
    It '回车直接确认第一项' {
        $src = New-KeySource @((New-Key ([char]13) [ConsoleKey]::Enter))
        $r = Show-CctSelector $script:tasks -KeySource $src
        $r | Should -Not -BeNullOrEmpty
        $r.Name | Should -Be 'alpha'
    }
    It '↓↓ + 回车选第三项' {
        $down = New-Key ([char]0) [ConsoleKey]::DownArrow
        $src = New-KeySource @($down, $down, (New-Key ([char]13) [ConsoleKey]::Enter))
        $r = Show-CctSelector $script:tasks -KeySource $src
        $r.Name | Should -Be 'gamma'
    }
    It 'Esc 返回 null' {
        $src = New-KeySource @((New-Key ([char]27) [ConsoleKey]::Escape))
        $r = Show-CctSelector $script:tasks -KeySource $src
        $r | Should -BeNullOrEmpty
    }
    It '输入字母实时过滤 + 回车选过滤后第一项' {
        $b = New-Key 'b' ([ConsoleKey]::B)
        $src = New-KeySource @($b, (New-Key ([char]13) [ConsoleKey]::Enter))
        $r = Show-CctSelector $script:tasks -KeySource $src
        $r.Name | Should -Be 'beta'
    }
    It 'Backspace 删除查询字符' {
        $b = New-Key 'b' ([ConsoleKey]::B)
        $z = New-Key 'z' ([ConsoleKey]::Z)
        $bs = New-Key ([char]8) [ConsoleKey]::Backspace
        $down = New-Key ([char]0) [ConsoleKey]::DownArrow
        # bz → backspace → b（beta 命中）→ ↓ 无效（只剩 1 项）→ Enter = beta
        $src = New-KeySource @($b, $z, $bs, $down, (New-Key ([char]13) [ConsoleKey]::Enter))
        $r = Show-CctSelector $script:tasks -KeySource $src
        $r.Name | Should -Be 'beta'
    }
    It '过滤后 0 项时回车不启动（返回 null）' {
        $z = New-Key 'z' ([ConsoleKey]::Z)
        $src = New-KeySource @($z, (New-Key ([char]13) [ConsoleKey]::Enter))
        $r = Show-CctSelector $script:tasks -KeySource $src
        $r | Should -BeNullOrEmpty
    }
    It '过滤后选中索引越界时自动收敛' {
        # 先 ↓↓ 选中第 3 项，再输入 'al' 过滤只剩 1 项 → 选中索引应为 0
        $down = New-Key ([char]0) [ConsoleKey]::DownArrow
        $a = New-Key 'a' ([ConsoleKey]::A)
        $l = New-Key 'l' ([ConsoleKey]::L)
        $src = New-KeySource @($down, $down, $a, $l, (New-Key ([char]13) [ConsoleKey]::Enter))
        $r = Show-CctSelector $script:tasks -KeySource $src
        $r.Name | Should -Be 'alpha'
    }
    It 'KeySource 序列耗尽视为取消（返回 null，不死循环）' {
        $src = New-KeySource @()
        $r = Show-CctSelector $script:tasks -KeySource $src
        $r | Should -BeNullOrEmpty
    }
    It 'Ctrl+C 视为取消' {
        # Ctrl+C 的 ConsoleKeyInfo：Key=C, Mods=Control。TreatControlCAsInput 场景下 ReadKey 返回它
        $cc = [System.ConsoleKeyInfo]::new([char]3, [ConsoleKey]::C, $false, $false, $true)
        $src = New-KeySource @($cc)
        $r = Show-CctSelector $script:tasks -KeySource $src
        $r | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5; Invoke-Pester -Path 'tests/SelectorLoop.Tests.ps1' -Output Minimal -PassThru | Select-Object PassedCount, FailedCount"`
Expected: FAIL——`Show-CctSelector` 未定义。

- [ ] **Step 3: 实现（追加到 Selector.ps1）**

```powershell
# 行 diff 重绘（发现 11：缓存上一帧，只重绘变化行，防闪烁）
$script:CctLastRows = $null
function Write-CctFrame {
    param([string[]]$Rows)
    $esc = $script:CctEsc
    $sb = [System.Text.StringBuilder]::new()
    $max = [Math]::Max(@($script:CctLastRows).Count, $Rows.Count)
    for ($i = 0; $i -lt $max; $i++) {
        $l1 = if ($i -lt @($script:CctLastRows).Count) { $script:CctLastRows[$i] } else { $null }
        $l2 = if ($i -lt $Rows.Count) { $Rows[$i] } else { $null }
        if ($l1 -cne $l2) {
            [void]$sb.Append($esc).Append('[').Append($i + 1).Append(';1H')
            [void]$sb.Append($esc).Append('[K')
            [void]$sb.Append($l2)
        }
    }
    $script:CctLastRows = @($Rows)
    if ($sb.Length -gt 0) { [Console]::Write($sb.ToString()) }
}

# 主循环（决策 7/24/31；KeySource 可注入供测试，生产用 [Console]::ReadKey）
function Show-CctSelector {
    param(
        [pscustomobject[]]$Tasks,
        [string]$InitialQuery = '',
        [int]$MaxRows = 0,
        [scriptblock]$KeySource = $null
    )
    $esc = $script:CctEsc
    if ($Tasks.Count -eq 0) { return $null }
    $total = $Tasks.Count

    try { $w = [Console]::WindowWidth } catch { $w = 120 }
    try { $h = [Console]::WindowHeight } catch { $h = 40 }
    if ($MaxRows -le 0) { $MaxRows = [Math]::Max(3, $h - 6) }

    $query = $InitialQuery
    $selected = 0
    $script:CctLastRows = $null
    $result = $null

    # 生产模式：进备用屏幕 + 隐藏光标（发现 11）。测试模式（KeySource 注入）跳过控制台操作
    $interactive = $null -eq $KeySource
    $savedCtrl = $false
    try {
        if ($interactive) {
            try { $savedCtrl = [Console]::TreatControlCAsInput } catch { $savedCtrl = $false }
            [Console]::TreatControlCAsInput = $true
            [Console]::Write("$esc[?1049h$esc[?25l")
        }
        while ($true) {
            $filtered = @(Filter-CctTasks $Tasks $query)
            if ($selected -ge $filtered.Count) { $selected = [Math]::Max(0, $filtered.Count - 1) }
            $frame = @(New-CctFrame $filtered $selected $query $w $MaxRows ([datetime]::Now) $total)
            if ($interactive) { Write-CctFrame $frame }   # 测试模式不写控制台
            # 读键
            $key = if ($KeySource) { & $KeySource } else { [Console]::ReadKey($true) }
            if ($null -eq $key) { return $null }           # 序列耗尽 = 取消
            # Ctrl+C 取消
            if ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [System.ConsoleModifiers]::Control)) { return $null }
            switch ($key.Key) {
                ([ConsoleKey]::UpArrow)   { $selected = [Math]::Max(0, $selected - 1) }
                ([ConsoleKey]::DownArrow) { $selected = [Math]::Min($filtered.Count - 1, $selected + 1) }
                ([ConsoleKey]::Enter) {
                    if ($filtered.Count -gt 0) { $result = $filtered[$selected] }
                    return $result
                }
                ([ConsoleKey]::Escape)    { return $null }
                ([ConsoleKey]::Backspace) { if ($query.Length -gt 0) { $query = $query.Substring(0, $query.Length - 1) } }
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
        }
    }
}
```

> 实现注意：`New-CctFrame` 的参数顺序是 `(Tasks, SelectedIndex, Query, WindowWidth, MaxRows, Now, TotalCount)`——最后两个位置参数传 `([datetime]::Now) $total` 时必须写成 `([datetime]::Now), $total` 或用命名参数，直接贴上面代码即可（已修正为正确形式）。

- [ ] **Step 4: 运行确认通过**

Run: 同 Step 2。
Expected: PassedCount = 9, FailedCount = 0。

- [ ] **Step 5: 手工冒烟（不可自动化，跑一次真实渲染）**

Run（项目根，PowerShell 交互窗口）：
```powershell
pwsh -NoProfile -Command ". .\cct\Display.ps1; . .\cct\Data.ps1; . .\cct\Selector.ps1; `$t = Get-CctTasks; `$r = Show-CctSelector `$t; Write-Host ('选中: ' + `$r.Name)"
```
Expected: 进全屏列表，方向键移动、输入字母过滤、Esc 退出后终端内容恢复。**此步需要人在终端操作，subagent 跳过并在报告中标注「留待用户手工验证」。**

- [ ] **Step 6: Commit**

```bash
git add cct/Selector.ps1 tests/SelectorLoop.Tests.ps1
git commit -m "feat(cct): 选择器主循环、按键处理与备用屏幕（Task 8）"
```

---

### Task 9: 执行层（Launcher.ps1）

**Files:**
- Create: `cct/Launcher.ps1`
- Modify: `cct/cct.psm1`（加 dot-source 行）
- Test: `tests/Launcher.Tests.ps1`

**Interfaces:**
- Consumes: Task 4 列表项、Task 5 配置（`launchCommand`/`resumeCommand` 模板）
- Produces: `Invoke-CctTask([pscustomobject]$Item, [pscustomobject]$Config) → [bool]`（是否成功启动）。行为（spec 5）：`Test-Path` 失败 → 写错误返回 $false 且**不切目录不启动**；否则 `Set-Location -LiteralPath $item.Path`（先切目录！发现 9）后按 Kind 执行 `launchCommand`（Folder）或 `resumeCommand` 替换 `{sessionId}`（Session）。**claude 是交互程序，测试不能真启动**——加 `[switch]$DryRun` 参数：DryRun 时不执行命令，改为把「将执行的命令行 + 切到的目录」写入返回对象的 `Command`/`Location` 属性并返回 `[pscustomobject]@{ Started=[bool]; Command; Location }`。Task 10 消费。

- [ ] **Step 1: 写失败测试**

`tests/Launcher.Tests.ps1`：

```powershell
BeforeAll {
    . "$PSScriptRoot\..\cct\Launcher.ps1"
    $script:tmp = Join-Path $env:TEMP ("cct_launch_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $script:tmp | Out-Null
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

Describe 'Invoke-CctTask（spec 5）' {
    It '文件夹项：先 Set-Location 再执行 launchCommand（DryRun 验证顺序）' {
        $item = [pscustomobject]@{ Kind='Folder'; Path=$script:tmp; Name='x'; SessionId=$null }
        $r = Invoke-CctTask $item $script:cfg -DryRun
        $r.Started | Should -BeTrue
        $r.Command | Should -Be 'claude --dangerously-skip-permissions -c'
        $r.Location | Should -Be $script:tmp
        (Get-Location).Path | Should -Be $script:tmp      # 真的切了目录（决策 22：留在任务目录）
    }
    It '会话项：resumeCommand 的 {sessionId} 被替换' {
        $item = [pscustomobject]@{ Kind='Session'; Path=$script:tmp; Name='x'; SessionId='abc-123' }
        $r = Invoke-CctTask $item $script:cfg -DryRun
        $r.Command | Should -Be 'claude --dangerously-skip-permissions --resume abc-123'
    }
    It '目录不存在：报错不启动，留在原地（决策 26）' {
        $before = (Get-Location).Path
        $item = [pscustomobject]@{ Kind='Folder'; Path='Z:\不存在\x'; Name='x'; SessionId=$null }
        $r = Invoke-CctTask $item $script:cfg -DryRun
        $r.Started | Should -BeFalse
        (Get-Location).Path | Should -Be $before
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5; Invoke-Pester -Path 'tests/Launcher.Tests.ps1' -Output Minimal -PassThru | Select-Object PassedCount, FailedCount"`
Expected: FAIL。

- [ ] **Step 3: 实现 Launcher.ps1**

```powershell
# 执行层（spec 5）：先切目录再启动 claude（顺序不可颠倒，发现 9）

function Invoke-CctTask {
    [CmdletBinding()]
    param([pscustomobject]$Item, [pscustomobject]$Config, [switch]$DryRun)

    # 目录校验（决策 26：不存在报错留原地）
    if (-not (Test-Path -LiteralPath $Item.Path)) {
        Write-Error "任务目录不存在: $($Item.Path)"
        return [pscustomobject]@{ Started = $false; Command = $null; Location = (Get-Location).Path }
    }

    # 1. 先切目录（发现 9：--resume 不会自动回原目录，必须先 Set-Location）
    Set-Location -LiteralPath $Item.Path

    # 2. 组命令（决策 4/10）
    $cmd = if ($Item.Kind -eq 'Session' -and $Item.SessionId) {
        $Config.resumeCommand -replace '\{sessionId\}', $Item.SessionId
    } else {
        $Config.launchCommand
    }

    if ($DryRun) {
        return [pscustomobject]@{ Started = $true; Command = $cmd; Location = $Item.Path }
    }

    # 3. 启动（交互式 claude，直接 & 调用透传错误——决策 27）
    try {
        # 用 Invoke-Expression 执行模板命令（配置是整行命令字符串）
        Invoke-Expression $cmd
        return [pscustomobject]@{ Started = $true; Command = $cmd; Location = $Item.Path }
    } catch {
        Write-Error "启动失败: $_"
        return [pscustomobject]@{ Started = $false; Command = $cmd; Location = $Item.Path }
    }
}
```

`cct/cct.psm1` 追加：

```powershell
. (Join-Path $moduleRoot 'Launcher.ps1')
```

- [ ] **Step 4: 运行确认通过**

Run: 同 Step 2。
Expected: PassedCount = 3, FailedCount = 0。

- [ ] **Step 5: Commit**

```bash
git add cct/Launcher.ps1 cct/cct.psm1 tests/Launcher.Tests.ps1
git commit -m "feat(cct): 执行层——先切目录再启动 claude（Task 9）"
```

---

### Task 10: cct 主函数（入口串联）+ resume 失败降级

**Files:**
- Create: `cct/Cct.ps1`
- Modify: `cct/cct.psm1`（加 dot-source 行 + Export-ModuleMember）
- Test: `tests/Cct.Tests.ps1`

**Interfaces:**
- Consumes: 全部前置任务（`Get-CctConfig`、`Get-CctTasks`、`Show-CctSelector`、`Invoke-CctTask`、`Filter-CctTasks`）
- Produces: `cct([string]$Keyword = '')`——用户入口命令。逻辑：读配置 → `Get-CctTasks`（用配置的 `minUserMessages`/`excludePathPatterns`）→ 空列表打印「没有可显示的任务」退出（决策 28）→ `Show-CctSelector -InitialQuery $Keyword` → 选中则 `Invoke-CctTask`，取消则静默返回（决策 24：唯一命中也不自动启动，界面总显示）。

**resume 失败降级（决策 23）**：`Invoke-CctTask` 里无法预先探测 resume 是否会失败（claude 是交互程序），降级逻辑放在**启动命令本身**：会话项命令改为 PowerShell 包装——若 claude 退出码非 0 且是 resume 场景，打印提示行并降级执行 launchCommand。**简化方案**（首版采用）：`Invoke-CctTask` 对 Session 项执行：

```powershell
$cmd = $Config.resumeCommand -replace '\{sessionId\}', $Item.SessionId
# 交互模式下无法可靠探测失败（claude 可能正常退出码 0 但进入了新会话），
# 首版直接执行 resumeCommand；若用户反馈进了空会话，后续版本加 --fork-session 重试逻辑
```

设计文档 5.4 说「打印一行提示后降级为 -c」。**可测的实现**：把降级决策做成独立纯函数 `Get-CctFallbackCommand([pscustomobject]$Item, [pscustomobject]$Config) → [string]`，`Invoke-CctTask` 在 claude 进程退出码非 0 时调用它。测试只测这个纯函数 + DryRun 路径。

- [ ] **Step 1: 写失败测试**

`tests/Cct.Tests.ps1`：

```powershell
BeforeAll {
    . "$PSScriptRoot\..\cct\Config.ps1"
    . "$PSScriptRoot\..\cct\Data.ps1"
    . "$PSScriptRoot\..\cct\Launcher.ps1"
    . "$PSScriptRoot\..\cct\Cct.ps1"
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
        $lines.Add(('{"type":"user","cwd":"' + ($taskDir -replace '\\', '\\\\') + '","timestamp":"2026-08-27T02:00:00.000Z","message":{"role":"user","content":"m"},"uuid":"u' + $i + '","parentUuid":null}'))
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

Describe 'Get-CctFallbackCommand（决策 23）' {
    It '会话项降级为 launchCommand（-c）' {
        $item = [pscustomobject]@{ Kind='Session'; Path='E:\x'; Name='x'; SessionId='abc' }
        $cmd = Get-CctFallbackCommand $item $script:cfg
        $cmd | Should -Be 'claude --dangerously-skip-permissions -c'
    }
    It '文件夹项无需降级（返回 launchCommand 原样）' {
        $item = [pscustomobject]@{ Kind='Folder'; Path='E:\x'; Name='x'; SessionId=$null }
        $cmd = Get-CctFallbackCommand $item $script:cfg
        $cmd | Should -Be 'claude --dangerously-skip-permissions -c'
    }
}

Describe 'Invoke-CctCatching 主流程（DryRun 注入）' {
    It '空任务列表打印提示不进界面（决策 28）' {
        $out = Invoke-CctMain -Tasks @() -ConfigPath $script:cfgPath -DryRun
        $out | Should -Match '没有'
    }
}

Describe '模块导出' {
    It 'cct 函数已导出' {
        Import-Module "$PSScriptRoot\..\cct\cct.psm1" -Force
        (Get-Command cct -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
    It '数据层端到端：假 projects 目录 → 文件夹项 + 1 个手动会话项' {
        $tasks = @(Get-CctTasks -Root $script:projRoot -MinUserMsgs 10 -ExcludePatterns @('ConfigBackup'))
        $tasks.Count | Should -Be 2   # 文件夹 + 1 个手动会话项（调优，12 条）
        ($tasks | Where-Object Kind -eq 'Folder').Name | Should -Be 'taskA'
        ($tasks | Where-Object Kind -eq 'Session').SessionId | Should -Be 's1'
    }
}
```

> 实现注意（PowerShell 空数组陷阱）：`-Tasks @()`（显式空数组）与不传 `-Tasks`（$null）在 PowerShell 里行为不同——`$null -eq @()` 为假，`-not @()` 为真。判空必须分两步：先 `$null -eq $Tasks` 判断「是否注入」（$null = 未注入走扫描；空数组 = 注入了且就是空的），再 `@($Tasks).Count -eq 0` 判断「列表是否为空」（打印提示退出，决策 28）。Step 3 的实现代码已按此写法给出，直接照抄即可。

- [ ] **Step 2: 运行确认失败**

Run: `pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5; Invoke-Pester -Path 'tests/Cct.Tests.ps1' -Output Minimal -PassThru | Select-Object PassedCount, FailedCount"`
Expected: FAIL——Cct.ps1 不存在。

- [ ] **Step 3: 实现 Cct.ps1**

```powershell
# cct 主入口（spec 2：数据层 → 界面层 → 执行层）

function Invoke-CctMain {
    [CmdletBinding()]
    param(
        [string]$Keyword = '',
        [string]$ConfigPath = (Join-Path $env:USERPROFILE '.cct\config.json'),
        [string]$ProjectsRoot = (Join-Path $env:USERPROFILE '.claude\projects'),
        [pscustomobject[]]$Tasks = $null,      # 测试注入（$null = 未注入，走扫描）
        [switch]$DryRun
    )
    $cfg = Get-CctConfig -Path $ConfigPath

    if ($null -eq $Tasks) {
        $Tasks = @(Get-CctTasks -Root $ProjectsRoot -MinUserMsgs $cfg.minUserMessages -ExcludePatterns $cfg.excludePathPatterns)
    }
    if (@($Tasks).Count -eq 0) {
        Write-Host '没有可显示的任务（没有会话历史或目录都已失效）'
        return
    }
    if ($DryRun) { return "共 $($Tasks.Count) 项" }

    $selected = Show-CctSelector -Tasks $Tasks -InitialQuery $Keyword
    if ($null -eq $selected) { return }   # Esc 取消，静默退出
    Invoke-CctTask -Item $selected -Config $cfg
}

# 用户命令入口
function cct {
    param([string]$Keyword = '')
    Invoke-CctMain -Keyword $Keyword
}

# resume 失败的降级命令（决策 23：打印提示后降级 -c）
function Get-CctFallbackCommand {
    param([pscustomobject]$Item, [pscustomobject]$Config)
    return $Config.launchCommand
}
```

`cct/cct.psm1` 最终版（追加 + 导出）：

```powershell
# cct 模块入口
$moduleRoot = $PSScriptRoot
. (Join-Path $moduleRoot 'Display.ps1')
. (Join-Path $moduleRoot 'Config.ps1')
. (Join-Path $moduleRoot 'Data.ps1')
. (Join-Path $moduleRoot 'Selector.ps1')
. (Join-Path $moduleRoot 'Launcher.ps1')
. (Join-Path $moduleRoot 'Cct.ps1')

Export-ModuleMember -Function cct, Get-CctTasks, Show-CctSelector, Invoke-CctTask, Get-CctConfig
```

> 实现注意：`Invoke-CctTask`（Task 9）里需要补上降级调用——真实（非 DryRun）执行后检查 `$LASTEXITCODE`：
> ```powershell
> if ($global:LASTEXITCODE -ne 0) {
>     Write-Host "该会话无法恢复（退出码 $LASTEXITCODE），已改为接续最近会话" -ForegroundColor Yellow
>     Invoke-Expression (Get-CctFallbackCommand $Item $Config)
> }
> ```
> 但 `Get-CctFallbackCommand` 定义在 Cct.ps1（Launcher.ps1 之后加载），PowerShell 的函数是运行时解析的，调用时已加载，无前向引用问题。`$LASTEXITCODE` 只对原生 exe 有效，`Invoke-Expression` 里的 claude 是 exe，成立。

- [ ] **Step 4: 运行确认通过**

Run: 同 Step 2。
Expected: PassedCount = 4, FailedCount = 0。

- [ ] **Step 5: Commit**

```bash
git add cct/Cct.ps1 cct/cct.psm1 tests/Cct.Tests.ps1
git commit -m "feat(cct): 主入口串联与 resume 失败降级（Task 10）"
```

---

### Task 11: 真实数据回归 + 性能验证 + 安装说明

**Files:**
- Create: `tests/RealData.Tests.ps1`（真实数据回归，**只在本机跑，CI 不可复现——文件头注释标明**）
- Create: `README.md`（安装说明，spec 7）

**Interfaces:**
- Consumes: 全部
- Produces: 无代码产出，回归验证 + 文档。

- [ ] **Step 1: 写真实数据回归测试**

`tests/RealData.Tests.ps1`（对本机 `~/.claude/projects` 全量跑，验证设计文档的实测结论）：

```powershell
# 本机真实数据回归测试（不可在别的机器复现，仅验证设计文档实测结论的实现一致性）
BeforeAll {
    . "$PSScriptRoot\..\cct\Data.ps1"
}

Describe '真实数据回归（spec 9）' {
    It '全库扫描 < 8 秒（设计预期 ~3.2 秒，留余量）' {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $script:tasks = @(Get-CctTasks)
        $sw.Stop()
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 8
    }
    It '列表规模在 20-80 项之间（设计结论 ≈39 项）' {
        $script:tasks.Count | Should -BeGreaterThan 20
        $script:tasks.Count | Should -BeLessThan 80
    }
    It '文件夹项全部存在且非 worktree' {
        $folders = @($script:tasks | Where-Object Kind -eq 'Folder')
        $folders.Count | Should -BeGreaterThan 10
        foreach ($f in $folders) {
            $f.Path | Should -Not -Match 'worktrees'
            (Test-Path -LiteralPath $f.Path) | Should -BeTrue
        }
    }
    It '每个会话项的 SessionId 对应的文件存在且有 ≥1 条真实用户消息（发现 22 空壳防护）' {
        $projRoot = Join-Path $env:USERPROFILE '.claude\projects'
        $sessions = @($script:tasks | Where-Object Kind -eq 'Session')
        $sessions.Count | Should -BeGreaterThan 3
        foreach ($s in $sessions) {
            $file = Get-ChildItem -LiteralPath $projRoot -Recurse -Filter "$($s.SessionId).jsonl" -File | Select-Object -First 1
            $file | Should -Not -BeNullOrEmpty
            $r = Read-CctSessionFile $file.FullName 0
            $r.HasRealUserMsg | Should -BeTrue
        }
    }
    It '排序单调：文件夹项按 LastActive 降序' {
        $folders = @($script:tasks | Where-Object Kind -eq 'Folder')
        for ($i = 1; $i -lt $folders.Count; $i++) {
            $folders[$i].LastActive | Should -BeLessThanOrEqual $folders[$i-1].LastActive
        }
    }
}
```

- [ ] **Step 2: 运行（真实数据，可能要几秒）**

Run: `pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5; Invoke-Pester -Path 'tests/RealData.Tests.ps1' -Output Detailed -PassThru | Select-Object PassedCount, FailedCount"`
Expected: 全部 PASS。若「会话项空壳防护」失败：Task 4 的 resume 目标选择逻辑有 bug（没跳过 0 消息文件）。

- [ ] **Step 3: 写 README.md（安装说明，spec 7）**

```markdown
# cct — Claude Code 任务文件夹选择器

一条命令列出所有 Claude Code 任务文件夹，选中自动 cd 并启动 claude。

## 安装

往 PowerShell profile（`$PROFILE`，通常在 `C:\Users\gt\Documents\PowerShell\Microsoft.PowerShell_profile.ps1`）追加一行：

```powershell
Import-Module "E:\个人\PersonalAITaskCenter\工具\CC插件_管理文件夹会话\cct\cct.psm1"
```

重开终端即生效。改代码后重开终端加载新版。

## 使用

- `cct` —— 弹出任务列表
- `cct sub` —— 带初始过滤词
- ↑↓ 选择、回车启动、Esc 取消；输入字母实时过滤（中文需输入法提交后过滤）
- 文件夹项接续最近会话（`-c`）；手动命名的会话项精确恢复（`--resume`）
- 退出 claude 后终端留在任务目录（想回原处用 `cd -`）

## 配置

`~/.cct/config.json`（首次运行自动生成）：
`launchCommand` / `resumeCommand`（启动命令模板，`{sessionId}` 占位）、
`excludePathPatterns`（排除的路径模式）、`maxVisibleRows`（0 = 自适应）、
`minUserMessages`（会话消息数阈值，默认 10）。

## 数据来源

只读 `~/.claude/projects/` 会话历史反推任务列表，零配置。
详见 `docs/specs/2026-08-27-cct-任务文件夹选择器-design.md`。
```

- [ ] **Step 4: 运行全部测试套件**

Run: `pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5; Invoke-Pester -Path 'tests' -Output Minimal -PassThru | Select-Object PassedCount, FailedCount"`
Expected: 全部通过（约 60+ 个测试）。

- [ ] **Step 5: Commit**

```bash
git add tests/RealData.Tests.ps1 README.md
git commit -m "test(cct): 真实数据回归与安装说明（Task 11）"
```

- [ ] **Step 6: 更新 PROGRESS.md 阶段状态**

把「阶段清单」的 7/8 打勾，当前阶段改为「阶段 9：验证 + 安装使用（等用户手工验证界面交互）」。

```bash
git add PROGRESS.md
git commit -m "docs(cct): 实现完成，进入手工验证阶段"
```

---

## 手工验证清单（交付用户，无法自动化）

1. `Import-Module ...\cct\cct.psm1` 后运行 `cct`：全屏列表出现，约 39 项
2. 方向键滚动、`↓ 还有 N 项` 边界滚动
3. 输入 `sub`：列表实时过滤到 sub2api 相关项，右上角 `2/5` 式计数
4. 中文输入法：提交候选词后过滤生效（预期行为：无法逐键实时）
5. Esc：退出且终端内容恢复原样（备用屏幕）
6. 选一个文件夹项：终端 cd 到任务目录并启动 claude，退出 claude 后留在任务目录
7. 选一个手动命名会话项（如「账号调优」）：恢复的会话上下文正确（能想起之前聊的内容）
8. `cct sub` 直接带过滤词进入
9. Ctrl+C：安全退出界面
10. 空查询回车：启动第一项（不是意外行为——回车语义就是确认当前选择）
