# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目定位

cct — Claude Code 任务文件夹选择器。一条命令列出 `~/.claude/projects/` 里的任务文件夹/会话，选中自动 cd 并启动 claude。PowerShell 外壳（`ClaudeCodeTask.UI`）+ C# 内核（`ClaudeCodeTask.Core`，预编译 dll），Pester 6 单测覆盖。

## 常用命令

```powershell
# 全量测试（修改代码后必跑）
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0.0; Invoke-Pester -Path 'tests' -Output Minimal"

# 单文件测试（界面层最常改）
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0.0; Invoke-Pester -Path 'tests\Selector.Tests.ps1' -Output Detailed"

# 重载模块并运行（TUI 手测；改代码后须重开终端或加 -Force）
Import-Module "E:\个人\ClaudeCodeTask\ClaudeCodeTask.UI\ClaudeCodeTask.UI.psm1" -Force
cct
```

## 架构（分层，ClaudeCodeTask.UI/ClaudeCodeTask.UI.psm1 按序 dot-source 加载）

- `ClaudeCodeTask.Core/` 内核层：C# 预编译 dll（`CctScannerV4` 并行扫描器 + `CctSpinner` + `CctConsoleMode`），改内核跑其 `build.ps1` 重新编译，产物 `lib/ClaudeCodeTask.Core.dll`；ps1 用 `Add-Type -Path` 加载
- `Display.ps1` 显示工具：`Get-DisplayWidth`（中文/emoji 宽度按 East Asian Width 手判区间，.NET 无内置）、Pad/Truncate、`Get-CctSessionLabel`（标题（目录名）去重省略括号）、`Get-RelativeTime`、`Get-TailPaths`（路径尾部默认 3 级，冲突逐级加深）
- `Spinner.ps1` 动画：内核 `CctSpinner` + `Invoke-WithSpinner`（输出被重定向时直跑不启动画）
- `Config.ps1` 配置：读写 `~/.cct/config.json`（首次运行自动生成）
- `Data.ps1` 数据层：内核 dll `CctScannerV4`（Parallel.For 并发读盘）+ 增量缓存 `~/.cct/cache.json` + `Get-CctTasks`/`Filter-CctTasks`
- `Selector.ps1` 界面层：`New-CctFrame`（纯函数帧渲染）+ `Write-CctFrame`（行 diff 重绘）+ `Show-CctSelector`（主循环）
- `Launcher.ps1` 执行层：`Invoke-CctClaude`（Start-Process 保 TTY）+ 降级链 `-r` → `-c` → prompt
- `Cct.ps1` 主入口：`Invoke-CctMain`（Tasks/SelectedTask/ConfigPath 均可注入测试）

## 关键设计约束（改代码前必读）

- **帧渲染是纯函数**：`New-CctFrame` 只返回行数组不写控制台；主循环 `Show-CctSelector` 用 `KeySource` 注入按键序列（`$null` 走真实控制台）。新增渲染逻辑先写 `New-CctFrame` 纯函数测试，再接入主循环。
- **固定栏位布局**：搜索行恒在行 0、帮助行恒在末行，帧高恒 = `WindowHeight`，行号稳定 → 终端永不滚屏。`MaxRows = floor((h-3)/5)`，余数行填帮助行上方。
- **resize 响应**：主循环轮询 `WindowWidth/Height`，变化时 `ESC[2J` 清屏 + 置空 `CctLastRows` 强制全量重绘并立即 `continue` 重绘，不要改成局部刷新。
- **行 diff 重绘**：`Write-CctFrame` 只重绘变化行；覆盖式写入（不清行），仅新行变短或被删时 `ESC[K]` 清尾/清行。
- **Add-Type 类型缓存陷阱**：C# 类（`CctScannerV*`、`CctSpinner`、`CctConsoleMode`）经 `Add-Type` 后进程内同名类缓存（内联编译与 `-Path` 加载 dll 同理），改类体必须换类名（V2→V3→V4 惯例），否则旧类型生效。
- **C# 扫描器归组**：按 `firstCwd`（会话启动/存储目录）归组、`lastCwd` 作 resume 目标——幻影 Folder 根因在此，勿改回按末现目录归组。
- **增量缓存**：文件数 ≥ 拐点 20 且缓存存在时按 mtime+size 复用；小于拐点走全量且不读写缓存；读/写失败静默回退全量。缓存结构 `{version, files:{path:{mt,sz,raw}}}`。
- **includeFolderFind 开关**：config 字段 `includeFolderFind`（0 = 默认，只输出含 sessionId 的会话；1 = 同时输出 folder 条目）。扫描始终含 folder（firstCwd 归组/排序依赖它），仅输出/查找层按此过滤。所有 config 消费点统一传 `($cfg.includeFolderFind -eq 1)` 给 `Get-CctTasks -IncludeFolderFind`（`Cct.ps1` 交互式、`Command.ps1` 的 list/find/run）。
- **TitleType 三层值**：jsonl 事件原文 `custom`/`ai`（内核/缓存层）→ 读取层枚举 `userCustom`/`aiGenerate`（`New-CctSessionRecord` 经 `$script:CctTitleKindMap` 映射，**分组比较逻辑用此层**）→ 展示层中文 `自定义命名`/`自动生成`（输出 Session 项，仅供人读、不可比较）。改动任一层须同步比较点与对应测试断言。
- **中文宽度**：终端列宽一律用 `Get-DisplayWidth`（勿用 `.Length`）；对齐用 `Pad-DisplayLeft/Right`、截断用 `Truncate-Display`。
- **入口路由（显式 ui）**：`cct`（无参，有 TTY 进交互式 / 无 TTY 降级 list）；`cct ui [词]`（显式交互式）；`cct list/find/run`（命令式，`-h` 出各自帮助）；`-` 开头为全局选项（`-h`/`-v`）；未注册词报「未知子命令」。简单函数 `$args` 收参（带 `[CmdletBinding()]` 会让 `-v` 被 `-Verbose` 吞掉）。

## 测试结构

- 每个 `ClaudeCodeTask.UI/*.ps1` 对应 `tests/*.Tests.ps1`；`RealData.Tests.ps1` 跑真实 `~/.claude/projects` 数据，勿改其断言语义；`fixtures/fake-claude.ps1` 是假 claude 启动器（Launcher 测试用）
- 界面层测试约定：`New-CctFrame` 直接传 `WindowWidth/Height/Now`，断言前用 ANSI 剥离正则取纯文本；`Show-CctSelector` 用 `New-KeySource` 注入按键队列测导航
- 改界面层必保留既有约束断言：帮助行贴底、帧高恒 = 窗高、每行宽 ≤ WindowWidth

## 进度追踪

`PROGRESS.md` 按轮记录「反馈 → 决策 → 验证」（决策编号顺延，含 Add-Type 换名等踩坑经验）。改代码前先查最近决策；完成一轮调整后按同样格式登记。
