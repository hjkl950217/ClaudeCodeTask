# cct — Claude Code Task

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows-0078D6?logo=windows&logoColor=white)](https://github.com/hjkl950217/ClaudeCodeTask)
[![PowerShell 7.6+](https://img.shields.io/badge/PowerShell-7.6%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![.NET 8](https://img.shields.io/badge/.NET-8-512BD4?logo=dotnet&logoColor=white)](https://dotnet.microsoft.com/)
[![C#](https://img.shields.io/badge/C%23-8.0-239120?logo=csharp&logoColor=white)](https://learn.microsoft.com/dotnet/csharp/)
[![Pester 6](https://img.shields.io/badge/tested%20with-Pester%206-brightgreen)](https://pester.dev)
[![GitHub stars](https://img.shields.io/github/stars/hjkl950217/ClaudeCodeTask?style=social)](https://github.com/hjkl950217/ClaudeCodeTask)
[![GitHub top language](https://img.shields.io/github/languages/top/hjkl950217/ClaudeCodeTask)](https://github.com/hjkl950217/ClaudeCodeTask)
[![PSGallery](https://img.shields.io/powershellgallery/v/ClaudeCodeTask?label=PSGallery&logo=powershell&logoColor=white)](https://www.powershellgallery.com/packages/ClaudeCodeTask)
[![Downloads](https://img.shields.io/powershellgallery/dt/ClaudeCodeTask?label=Downloads)](https://www.powershellgallery.com/packages/ClaudeCodeTask)

一条命令列出所有 [Claude Code](https://claude.ai/code) 任务文件夹，选中自动 `cd` 并启动 `claude`。

> 主要测试平台：Windows（Windows 11 / PowerShell 7.6）。其他平台理论上可运行，但未系统验证。

## 效果预览

![交互式模式截图](image/interactive-mode.png)

![命令式模式截图](image/command-mode.png)

## 功能

- 全屏卡片网格选择器，键盘导航、实时搜索过滤
- 自动聚合同一任务目录的会话：手动命名项优先，AI 自动标题保底
- 支持会话中途 `cd` 到子目录——列表按存储目录分组，恢复目标指向子目录
- 退出 claude 后终端留在任务目录
- 增量缓存：热启动扫描加速 ~65-73%
- `cct clear` 清理：无参清 cct 扫描缓存（下次扫描全量重建）；`-cc` 按行数判定清理多余 Claude Code 会话（每目录保留最新 ≥ 阈值会话，先预览过滤规则与待删清单、确认后删除）

## 技术亮点

- **预编译 C# 内核（ClaudeCodeTask.Core）**：性能关键路径由 C# 内核 dll 承担（`CctScannerV4` 并行读盘 + 增量缓存），PowerShell 只做类型转换，扫描提速约 24 倍
- **并行扫描**：C# `Parallel.For` 并发读盘，无共享状态，单文件异常不中断整体
- **增量缓存**：文件数 ≥ 20 且缓存存在时，按 mtime+size 复用精确结果，热启动快 ~65-73%
- **纯 .NET 目录判定**：`Directory.Exists` 替代 `Test-Path`，免 PowerShell 提供程序开销
- **行 diff 重绘**：选择器仅重绘变化行，覆盖式写入不清行，无闪烁

## 安装

### 前置条件

- [PowerShell 7.6+](https://github.com/PowerShell/PowerShell)
- [Claude Code](https://claude.ai/code)
- [Pester 6](https://pester.dev)（仅开发测试需要）

### 方式一：从 PowerShell Gallery 安装（推荐）

```powershell
# 安装模块（命令为 cct）
Install-Module -Name ClaudeCodeTask -Scope CurrentUser
```

- 安装后命令为 **`cct`**（模块名 `ClaudeCodeTask`、命令 `cct`），重开终端即可使用
- **无需手动导入**：PowerShell 会在你首次输入 `cct` 时自动从 `$env:PSModulePath` 找到并加载模块，不需要 `Import-Module`

**更新模块**

```powershell
# 更新到最新版
Update-Module -Name ClaudeCodeTask

# 若上一命令因权限报错，显式指定用户级作用域重试
Update-Module -Name ClaudeCodeTask -Scope CurrentUser -Force
```

- 更新前先确认当前版本：`Get-Module -Name ClaudeCodeTask -ListAvailable`
- 若模块已在本会话加载，更新后需**重开终端**（或先 `Remove-Module ClaudeCodeTask` 再重新输入 `cct`）才会生效

**卸载模块**

```powershell
Uninstall-Module -Name ClaudeCodeTask
```

### 方式二：从代码仓库安装（体验源码 / 开发调试）

```powershell
git clone https://github.com/hjkl950217/ClaudeCodeTask.git
cd ClaudeCodeTask

# 将模块加载追加到 PowerShell profile
Add-Content -LiteralPath $PROFILE -Value "`nImport-Module `"$PWD\ClaudeCodeTask.UI\ClaudeCodeTask.psm1`""
```

重开终端即生效。改代码后重开终端加载新版。

### 中国大陆网络访问说明

`Install-Module` 默认从官方源 `https://www.powershellgallery.com/api/v2` 拉取，**无需额外添加或切换源**。该端点**没有官方中国镜像**，在大陆跨网环境下可能偶发连接超时或 DNS 解析失败（与本仓库无关，任何 PSGallery 模块都会遇到）。

若遇到超时 / 无法解析，按以下顺序处理：

**1. 配置代理**（推荐，最通用）

PowerShell 的 NuGet 提供程序遵循系统代理设置，设置后即可正常访问：

```powershell
# 临时设置（当前终端生效）
$env:HTTP_PROXY  = 'http://127.0.0.1:7890'
$env:HTTPS_PROXY = 'http://127.0.0.1:7890'

# 或用系统「设置 → 网络和 Internet → 代理」开启代理后重开终端
Install-Module -Name ClaudeCodeTask -Scope CurrentUser
```

> **有代理软件（Clash / v2rayN 等）的用户**：无需全局代理，直接在代理软件的「分流规则」里把 `powershellgallery.com` 加入走代理即可。这样只代理这一个域名，其余流量不受影响；地址 `api/v2` 与网页同域名，只加主域 `powershellgallery.com` 即覆盖安装请求。

**2. 离线安装**（无代理时的兜底）

从 [PowerShell Gallery 页面](https://www.powershellgallery.com/packages/ClaudeCodeTask) 手动下载 `.nupkg` 文件，然后：

```powershell
# 下载 ClaudeCodeTask.0.1.0.nupkg 到当前目录后执行（版本号以 PSGallery 页面最新版为准）：
Install-Module -Name .\ClaudeCodeTask.0.1.0.nupkg -SkipPublisherCheck -Force
```

安装后同样以 `cct` 命令使用。

## 使用

```powershell
cct                    # 弹出任务列表，空白输入 = 全部
cct <关键词>           # 带初始过滤词
cct clear              # 清理 cct 扫描缓存（cache.json），下次扫描全量重建
cct clear -cc          # 清理多余 Claude Code 会话（先预览过滤规则与待删清单，确认后删除）
```

`cct clear` 选项：

| 选项 | 说明 |
|------|------|
| `-cc` | 清理多余会话（不与清缓存同用；用此参数时不动 cct 缓存） |
| `-y, --yes` | 跳过交互确认直接删除（非交互环境不加 --yes 时只预览不删） |
| `--keep <数>` | 每目录保留的最新会话个数（默认 1） |
| `--min <行数>` | 会话有效行数阈值，「对话次数」按 .jsonl 行数近似（默认 20） |
| `--dry-run` | 只打印预览，不删除 |

选择器操作：

| 操作 | 效果 |
|------|------|
| ↑↓←→ | 上下左右移动 |
| Enter | 确认选择 |
| Esc | 取消退出 |
| 输入文字 | 实时过滤（中文需输入法提交后过滤） |
| Backspace | 删除上一个过滤字符 |

## 配置

以下配置在首次运行时**自动生成**到 `~/.cct/config.json`，**无需手动创建**；需要自定义时再编辑该文件，改后重启终端生效：

```json
{
  "launchCommand":      "claude -c",
  "resumeCommand":      "claude --resume {sessionId}",
  "excludePathPatterns":[".claude/worktrees/", "AppData\\Local\\Temp"],
  "maxVisibleRows":     0,
  "minUserMessages":    10,
  "includeFolderFind":  0
}
```

| 字段 | 默认 | 说明 |
|------|------|------|
| `launchCommand` | `claude -c` | 文件夹项启动命令 |
| `resumeCommand` | `claude --resume {sessionId}` | 会话项恢复命令，`{sessionId}` 自动替换 |
| `excludePathPatterns` | worktrees + Temp | 排除路径模式 |
| `maxVisibleRows` | 0 (自适应) | 卡片网格最大行数 |
| `minUserMessages` | 10 | 会话显示阈值（≥ 此条数才显示） |
| `includeFolderFind` | 0 (仅会话) | 0 = 只列出会话（默认）；1 = 额外列出没有任何会话的目录（同目录已有会话时不重复列出） |

> **关于 `--dangerously-skip-permissions`**：默认启动命令**不带**该参数。它会跳过 [Claude Code](https://claude.ai/code) 的所有权限确认（工具调用、文件写入、命令执行等直接放行），有安全风险。除非你明确需要完全无人值守，否则不要添加。

## 数据来源

只读 `~/.claude/projects/` 目录下的会话历史文件（`.jsonl`），按首现工作目录自动分组，零配置。

## 开发

### 手动加载本地运行（临时终端，不改 profile）

```powershell
# 从仓库检出目录直接加载模块并启动选择器（无需安装）
Import-Module "$PWD\ClaudeCodeTask.UI\ClaudeCodeTask.psm1" -Force
cct

# 改过 UI 代码后重新加载再试（-Force 强制重连）
Import-Module "$PWD\ClaudeCodeTask.UI\ClaudeCodeTask.psm1" -Force
cct
```

- `-Force` 覆盖已加载的旧版本模块，改代码后不必重开终端
- UI 层为 PowerShell 源码，改动即时生效；**内核层（`ClaudeCodeTask.Core/*.cs`）是预编译 dll**，改 C# 后需先跑 `ClaudeCodeTask.Core\build.ps1` 重新编译（且因 `Add-Type` 类型缓存约束，换类体必须换类名，如 V2→V3→V4），再重新加载模块
- 手动运行占用当前终端（全屏），退出后回到原 shell

### 跑测试（Pester 6）

```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0.0; Invoke-Pester -Path 'tests' -Output Minimal"

# 单文件测试（界面层最常改）
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0.0; Invoke-Pester -Path 'tests\Selector.Tests.ps1' -Output Detailed"
```

- 测试覆盖：15 个测试文件，225 个测试用例
- 涵盖：数据提取、聚合、搜索、选择器渲染、配置、启动执行、缓存、清理（clear）

### 项目结构

```
├── .github/           # GitHub 集成（CI 测试 + PSGallery 发布工作流 + issue 模板）
│   └── workflows/     ci.yml（push/PR 跑 Pester）+ publish.yml（release 发布到 PSGallery）
├── ClaudeCodeTask.Core/ # C# 内核（预编译 dll，改动内核后跑该目录 build.ps1 重新编译）
│   ├── CctScannerV4.cs        并行读盘扫描 + 增量缓存支持
│   ├── CctSpinner.cs          加载动画
│   ├── CctConsoleMode.cs      控制台模式（TTY 保持）
│   ├── build.ps1              内核编译脚本（产物 lib/ClaudeCodeTask.Core.dll）
│   ├── ClaudeCodeTask.Core.csproj   net8.0（PowerShell 7.6 可直接加载）
│   └── lib/ClaudeCodeTask.Core.dll   编译产物（随仓库提交）
├── ClaudeCodeTask.UI/ # UI 外壳（模块名 = 包名 = ClaudeCodeTask，命令 = cct）
│   ├── Data.ps1           数据层（调用 Core dll，并行 + 增量缓存）
│   ├── Selector.ps1       界面层（全屏卡片网格，行 diff 重绘）
│   ├── Launcher.ps1       执行层（启动/恢复 claude）
│   ├── Clear.ps1          清理层（cct clear：清缓存 / 清理多余会话）
│   ├── Cct.ps1            主入口
│   ├── Config.ps1         配置读写
│   ├── Display.ps1        显示工具（中文/emoji 宽度按 East Asian Width 判定）
│   ├── Spinner.ps1        加载动画
│   ├── ClaudeCodeTask.psd1  模块清单
│   └── ClaudeCodeTask.psm1  模块声明（导出 cct 命令）
├── tests/           # Pester 测试（15 文件）
│   └── fixtures/     测试夹具（fake-claude.ps1 等）
├── 经验和文档/       # 长期保存的排查复盘、决策记录（随仓库推送）
│   └── 性能调试/      性能探针复盘（claude 接管时序）
└── README.md
```

## 友情链接

- [Claude Code](https://github.com/anthropics/claude-code) —— Anthropic 官方命令行工具
- [LINUX DO](https://linux.do) —— 新的理想型技术社区

## 许可

本项目以 [MIT](LICENSE) 许可发布。
