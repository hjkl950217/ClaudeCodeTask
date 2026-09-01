# cct — Claude Code Task Selector

[![PowerShell 7.6+](https://img.shields.io/badge/PowerShell-7.6%2B-blue)](https://github.com/PowerShell/PowerShell)
[![Pester 6](https://img.shields.io/badge/tested%20with-Pester%206-brightgreen)](https://pester.dev)

一条命令列出所有 Claude Code 任务文件夹，选中自动 `cd` 并启动 `claude`。

> 主要测试平台：Windows（Windows 11 / PowerShell 7.6）。其他平台理论上可运行，但未系统验证。

## 功能

- 全屏卡片网格选择器，键盘导航、实时搜索过滤
- 自动聚合同一任务目录的会话：手动命名项优先，AI 自动标题保底
- 支持会话中途 `cd` 到子目录——列表按存储目录分组，恢复目标指向子目录
- 退出 claude 后终端留在任务目录
- 增量缓存：热启动扫描加速 ~65-73%

## 技术亮点

- **内联 C# 编译**：性能关键路径用 `Add-Type` 内联 C# 代码，运行时自动编译（Roslyn），性能提升约 24 倍
- **并行扫描**：C# `Parallel.For` 并发读盘，无共享状态，单文件异常不中断整体
- **增量缓存**：文件数 ≥ 20 且缓存存在时，按 mtime+size 复用精确结果，热启动快 ~65-73%
- **纯 .NET 目录判定**：`Directory.Exists` 替代 `Test-Path`，免 PowerShell 提供程序开销

## 安装

### 前置条件

- [PowerShell 7.6+](https://github.com/PowerShell/PowerShell)
- [Claude Code](https://claude.ai/code) 已安装
- [Pester 6](https://pester.dev)（仅开发测试需要）

### 安装

```powershell
# 下载到本地
git clone https://github.com/hjkl950217/ClaudeCodeTask.git
cd ClaudeCodeTask

# 将模块加载追加到 PowerShell profile
Add-Content -LiteralPath $PROFILE -Value "`nImport-Module `"$PWD\cct\cct.psm1`""
```

重开终端即生效。改代码后重开终端加载新版。

## 使用

```powershell
cct                    # 弹出任务列表，空白输入 = 全部
cct <关键词>           # 带初始过滤词
```

选择器操作：

| 操作 | 效果 |
|------|------|
| ↑ / ↓ | 向上 / 向下移动一行 |
| ← / → | 向左 / 向右移动一列 |
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
  "minUserMessages":    10
}
```

| 字段 | 默认 | 说明 |
|------|------|------|
| `launchCommand` | `claude -c` | 文件夹项启动命令 |
| `resumeCommand` | `claude --resume {sessionId}` | 会话项恢复命令，`{sessionId}` 自动替换 |
| `excludePathPatterns` | worktrees + Temp | 排除路径模式 |
| `maxVisibleRows` | 0 (自适应) | 卡片网格最大行数 |
| `minUserMessages` | 10 | 会话显示阈值（≥ 此条数才显示） |

> **关于 `--dangerously-skip-permissions`**：默认启动命令**不带**该参数。它会跳过 Claude Code 的所有权限确认（工具调用、文件写入、命令执行等直接放行），有安全风险。除非你明确需要完全无人值守，否则不要添加。

## 数据来源

只读 `~/.claude/projects/` 目录下的会话历史文件（`.jsonl`），按首现工作目录自动分组，零配置。

## 开发

```powershell
# 跑全部测试（Pester 6）
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0.0; Invoke-Pester -Path 'tests' -Output Minimal"

# 测试覆盖
# 13 个测试文件，136 个测试用例
# 涵盖：数据提取、聚合、搜索、选择器渲染、配置、启动执行、缓存
```

### 项目结构

```
├── cct/           # 模块
│   ├── Data.ps1     数据层（含内联 C# 扫描器，并行 + 增量缓存）
│   ├── Selector.ps1 界面层（全屏卡片网格）
│   ├── Launcher.ps1 执行层（启动/恢复 claude）
│   ├── Cct.ps1      主入口
│   ├── Config.ps1   配置读写
│   ├── Display.ps1  显示工具
│   ├── Spinner.ps1  加载动画
│   └── cct.psm1     模块声明
├── tests/         # Pester 测试（13 文件）
│   └── fixtures/     测试夹具
├── docs/          # 设计文档
│   ├── specs/        规格说明
│   └── plans/        实现计划
├── PROGRESS.md    # 开发决策日志
└── README.md
```

## 许可

本项目以 [MIT](LICENSE) 许可发布。