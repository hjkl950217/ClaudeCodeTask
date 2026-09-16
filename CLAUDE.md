# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目定位

cct — Claude Code 任务文件夹选择器。一条命令列出 `~/.claude/projects/` 里的任务文件夹/会话，选中自动 cd 并启动 claude。PowerShell 外壳（模块名 `ClaudeCodeTask`，源码位于 `ClaudeCodeTask.UI/` 目录）+ C# 内核（`ClaudeCodeTask.Core`，预编译 dll），Pester 6 单测覆盖。

## 常用命令

```powershell
# 全量测试（修改代码后必跑）
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0.0; Invoke-Pester -Path 'tests' -Output Minimal"

# 单文件测试（界面层最常改）
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0.0; Invoke-Pester -Path 'tests\Selector.Tests.ps1' -Output Detailed"

# 重载模块并运行（TUI 手测；改代码后须重开终端或加 -Force）
Import-Module "E:\个人\ClaudeCodeTask\ClaudeCodeTask.UI\ClaudeCodeTask.psm1" -Force
cct
```

## 架构（分层，ClaudeCodeTask.UI/ClaudeCodeTask.psm1 按序 dot-source 加载）

- `ClaudeCodeTask.Core/` 内核层：C# 预编译 dll（`CctScannerV6` 并行扫描器 + `CctSpinner` + `CctConsoleMode`），改内核跑其 `build.ps1` 重新编译，产物 `lib/ClaudeCodeTask.Core.dll`；ps1 用 `Add-Type -Path` 加载
- `Display.ps1` 显示工具：`Get-DisplayWidth`（中文/emoji 宽度按 East Asian Width 手判区间，.NET 无内置）、Pad/Truncate、`Get-CctSessionLabel`（标题（目录名）去重省略括号）、`Get-RelativeTime`、`Get-TailPaths`（路径尾部默认 3 级，冲突逐级加深）
- `Spinner.ps1` 动画：内核 `CctSpinner` + `Invoke-WithSpinner`（输出被重定向时直跑不启动画）
- `Config.ps1` 配置：读写 `~/.cct/config.json`（首次运行自动生成）
- `Data.ps1` 数据层：内核 dll `CctScannerV6`（Parallel.For 并发读盘）+ 增量缓存 `~/.cct/cache.json` + `Get-CctTasks`/`Filter-CctTasks`
- `Selector.ps1` 界面层：`New-CctFrame`（纯函数帧渲染）+ `New-CctConfirmFrame`（删除确认屏，同为纯函数）+ `Write-CctFrame`（行 diff 重绘）+ `Show-CctSelector`（主循环）
- `Clear.ps1` 清理层：`cct clear`（缓存/`-cc` 按行数清理）+ 选择器删除用的 `Get-CctDirDeletePlan`（按编码目录列清单，纯函数）与 `Remove-CctDirToRecycleBin`（走回收站）
- `Launcher.ps1` 执行层：`Invoke-CctClaude`（Start-Process 保 TTY）+ 降级链 `-r` → `-c` → prompt
- `Cct.ps1` 主入口：`Invoke-CctMain`（Tasks/SelectedTask/ConfigPath 均可注入测试）

## 关键设计约束（改代码前必读）

- **帧渲染是纯函数**：`New-CctFrame` 只返回行数组不写控制台；主循环 `Show-CctSelector` 用 `KeySource` 注入按键序列（`$null` 走真实控制台）。新增渲染逻辑先写 `New-CctFrame` 纯函数测试，再接入主循环。
- **固定栏位布局**：搜索行恒在行 0、帮助行恒在末行，帧高恒 = `WindowHeight`，行号稳定 → 终端永不滚屏。`MaxRows = floor((h-3)/5)`，余数行填帮助行上方。
- **resize 响应**：主循环轮询 `WindowWidth/Height`，变化时 `ESC[2J` 清屏 + 置空 `CctLastRows` 强制全量重绘并立即 `continue` 重绘，不要改成局部刷新。
- **行 diff 重绘**：`Write-CctFrame` 只重绘变化行；覆盖式写入（不清行），仅新行变短或被删时 `ESC[K]` 清尾/清行。
- **Add-Type 类型缓存陷阱**：C# 类（`CctScannerV*`、`CctSpinner`、`CctConsoleMode`）经 `Add-Type` 后进程内同名类缓存（内联编译与 `-Path` 加载 dll 同理），改类体必须换类名（V2→V3→V4→V5 惯例），否则旧类型生效。
- **C# 扫描器归组**：按 `firstCwd`（会话启动/存储目录）归组、`lastCwd` 作 resume 目标——幻影 Folder 根因在此，勿改回按末现目录归组。
- **续接分叉折叠与目录升格（第十九轮）**：`claude -c`/`--resume` 续接会话会在同一编码目录生成携带祖先历史的新 jsonl（历史行 message 层带蛇形 `session_id` 指向祖先，扫描器 V5 提取为 Ancestors 列）。同目录内「祖先被合格后代声明」→ 祖先折叠，只留对话链最新端点；组内无合格会话时「有标题且 ≥1 真实消息」的最新碎片升格为会话卡（豁免 MinUserMsgs 阈值，精确 --resume）。缓存 version 2（raw 7 列），旧缓存自动废弃重扫。
- **会话名继承（第二十二轮）**：目录内只有一个命名名、且存在「真实输入时间更晚」的合格未命名会话时，由该未命名会话顶替命名组出卡、沿用该名字（**只改展示，不写 jsonl**）。判定必须用 `LastUserMsgTime`（内核 V6 第 8 列 = 最后一条真实用户输入的 timestamp），**不能用 `LastTimestamp`**——会话文件被打开一次就会刷新末条时间戳，用 cct 进去看一眼再退出也会把它排成「最新」，卡片从此永远指向它。多命名名（不相干任务）或未命名会话不够格时不触发。缓存 version 3（raw 8 列）。内核 V6 同时把 `<` 开头（local-command-stdout 等终端回显）与 `Continue from where you left off.`（CC 恢复会话注入）排除出真实输入判定，否则新列照样被刷新。
- **选择器内删除（第二十三轮）**：选中卡片按 `d`（**搜索框为空时**）或 `Delete` 进确认屏，`y`/回车/`d` 都能执行（`d` 与进确认同键，连按两下即删）、`n`/`Esc` 取消、**其余键一律无效**（用户可能想滚动看完清单，误触不该有后果）。删除后的结果提示显示在**搜索框右侧的计数位**（不覆盖搜索框），按键时清除且**不吞该按键**——删完立刻处于正常操作状态，不必先按一下清提示；已输入搜索词时 `d` 照常进输入框，要删就用 `Delete`。一次删掉该卡片 `GroupKey` 对应的**整个编码目录**（`ProjectDir`，含 memory、agent 子会话、附属目录、孤立目录），走 Windows 回收站可还原——**不是** `cct clear -cc` 的永久删，两者刻意分离（clear 仍按行数判定）。卡片靠数据层的 `ProjectDir` 字段定位（`~/.claude/projects` 目录名编码不可逆，无法从 StartCwd 反推）。确认屏由 `New-CctConfirmFrame` 纯函数渲染：四列（短 id / 标题 / 时间 / 大小）**一律按显示宽算，禁止 `\t`**（终端制表位按字符数推进，中文占 2 列必然错位），窄窗逐级降级（去大小列 → 去时间列），每行显示宽恒 ≤ 窗宽。末行按键提示分两段着色——确认段亮红、取消段暗灰（与主界面按键提示同色），两段各自按剩余宽度截断（取消段吃确认段用剩的宽，不足则整段丢弃）。`Test-CctDirInUse` 靠独占打开 jsonl 探测占用，**挡不住「另一终端正开着该会话」**（CC 写 jsonl 是追加后关闭、不常驻句柄）——安全网是回收站，不是探测。
- **增量缓存**：文件数 ≥ 拐点 20 且缓存存在时按 mtime+size 复用；小于拐点走全量且不读写缓存；读/写失败静默回退全量。缓存结构 `{version, files:{path:{mt,sz,raw}}}`。
- **includeFolderFind 开关**：config 字段 `includeFolderFind`（0 = 默认，只输出含 sessionId 的会话；1 = 会话 + 「纯 folder」目录——同目录已有可恢复会话时 folder 头被 session 取代，folder 只在无会话组保留）。扫描始终含 folder（firstCwd 归组/排序依赖它），仅输出/查找层按此过滤。所有 config 消费点统一传 `($cfg.includeFolderFind -eq 1)` 给 `Get-CctTasks -IncludeFolderFind`（`Cct.ps1` 交互式、`Command.ps1` 的 list/find/run）。
- **TitleType 三层值**：jsonl 事件原文 `custom`/`ai`（内核/缓存层）→ 读取层枚举 `userCustom`/`aiGenerate`（`New-CctSessionRecord` 经 `$script:CctTitleKindMap` 映射，**分组比较逻辑用此层**）→ 展示层中文 `自定义命名`/`自动生成`（输出 Session 项，仅供人读、不可比较）。改动任一层须同步比较点与对应测试断言。
- **中文宽度**：终端列宽一律用 `Get-DisplayWidth`（勿用 `.Length`）；对齐用 `Pad-DisplayLeft/Right`、截断用 `Truncate-Display`。
- **帮助行版权**：右侧显示 `v<版本号> by github - hjkl950217`，版本号由 `Selector.ps1` 从 psd1 读取到 `$script:CctVersionLabel`（**不写死**，发版改 `build-metadata.json` 盖章后自动跟随）；分档按 `Get-DisplayWidth` **逐档实测宽度**而非写死阈值——版本号长度会变（0.3.3 → 0.10.0），写死阈值将来会算错。
- **入口路由（显式 ui）**：`cct`（无参，有 TTY 进交互式 / 无 TTY 降级 list）；`cct ui [词]`（显式交互式）；`cct list/find/run`（命令式，`-h` 出各自帮助）；`-` 开头为全局选项（`-h`/`-v`）；未注册词报「未知子命令」。简单函数 `$args` 收参（带 `[CmdletBinding()]` 会让 `-v` 被 `-Verbose` 吞掉）。

## 测试结构

- 每个 `ClaudeCodeTask.UI/*.ps1` 对应 `tests/*.Tests.ps1`；`RealData.Tests.ps1` 跑真实 `~/.claude/projects` 数据，勿改其断言语义；`fixtures/fake-claude.ps1` 是假 claude 启动器（Launcher 测试用）
- 界面层测试约定：`New-CctFrame` 直接传 `WindowWidth/Height/Now`，断言前用 ANSI 剥离正则取纯文本；`Show-CctSelector` 用 `New-KeySource` 注入按键队列测导航
- 改界面层必保留既有约束断言：帮助行贴底、帧高恒 = 窗高、每行宽 ≤ WindowWidth

## 进度追踪

`PROGRESS.md` 按轮记录「反馈 → 决策 → 验证」（决策编号顺延，含 Add-Type 换名等踩坑经验）。改代码前先查最近决策；完成一轮调整后按同样格式登记。

## 临时文件

任务执行完，把本次产生的临时文件直接删除（冒烟验证脚本、测试 fixture 残留、`sync-to-installed.ps1` 产生的空 `cct-sync-backup-*` 备份目录等），不逐次列清单等确认。被系统占用删不掉的（如 0 字节 `cct_err_*.txt`）跳过即可，不阻塞收尾。

## 集中元数据（版本号/域名/发版说明的唯一编辑点）

- `build-metadata.json`（仓库根）：`version` / `projectUri` / `licenseUri` / `releaseNotes` / `buildProxy`（内核构建 nuget 代理）。改版本号只编辑此文件。
- `StampMetadata.ps1`：`Read-CctBuildMetadata`（读取+校验）与 `Update-CctPsd1FromMetadata`（盖章 psd1 四字段，幂等）。psd1 是模块清单无法动态读外部文件，采用「单一编辑点 + 自动盖章」模式。
- 消费点：`sync-to-installed.ps1` 同步前自动盖章（失败降级用 psd1 现值）、`Core/build.ps1` 代理读 `buildProxy`、`tests/Metadata.Tests.ps1` 守卫 psd1 与元数据一致（单改 psd1 会红）。发版时 tag 版本仍由 release.yml 的 `Update-ModuleManifest` 机械改写。
