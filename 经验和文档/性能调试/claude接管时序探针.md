# claude 启动「接管屏幕」时序探针复盘（决策 88）

> 调试对象：cct 启动 claude 时 spinner 的熄灭时机。
> 结论速览：claude 切 raw 输入远早于真正渲染屏幕（实测超前 8.5s），
> 拿 raw 当接管信号必然「提前熄灯 → 空窗」；应以**屏幕光标离开 spinner
> 所在行**作为「claude 已接管」信号，spinner 恰好贴住渲染瞬间熄灭。

## 1. 要解决的问题

cct 选中会话后由 `Launcher.ps1` 的 `Invoke-CctClaude` 拉起 claude（`Start-Process -NoNewWindow`
保 TTY），期间显示 `正在启动会话…` spinner。接管前 spinner 应持续覆盖冷启动期，
接管后应立即熄灭把屏幕交给 claude。

两难（前一版失败史）：

| 版本 | 策略 | 实测结果 |
|---|---|---|
| autoStop 6s | 固定 6s 强停 | 熄灯太早，claude 冷启动远超 6s → 空白等待断档 |
| autoStop 30s | 固定 30s 强停 | 进入 CC 会话后 spinner 仍在残留写屏 |
| raw 检测（1版） | `stdin` mode 清 `ENABLE_LINE_INPUT` 即停 | spinner 转 1-2s 就熄灯，空窗到渲染——**仍早** |

固定时间方案无法覆盖冷启动的波动（实测 1s ~ 10s+），需要「渲染即停」的时序信号。

## 2. 探针方法

`Launcher.ps1` 内置探针（硬编码开关 `$script:CctProbeEnabled`，出厂 `$false`）：
把它改为 `$true` 后，`Invoke-CctClaude` 启动轮询期间每 ~50ms 向
`%TEMP%\cct_probe_<guid>.csv` 追加一行时间线：

```
elapsed_ms,mode_hex,cursor_y,cursor_x,title
```

- `elapsed_ms`：spinner 启动起的毫秒数
- `mode_hex`：`GetConsoleMode(STD_INPUT)`（`1f7`=cooked，`208`=raw，0x0002 位被清）
- `cursor_y/x`：`[Console]::CursorTop/Left`（conpty 下为共享屏幕光标，跨进程可见）
- `title`：`[Console]::Title`（claude 接管时窗口标题变为「✳ Claude Code」）

测试规程：真实终端跑 `Import-Module … -Force; cct` → 选中会话回车 →
等 claude 界面出现后正常使用片刻 → 退出 claude → 读 CSV 定位各事件时刻。

## 3. 实测数据（2026-09-02，Windows Terminal / conpty）

### 3.1 第一轮（raw-only 版，问题复现）

窗口 42 行内 spinner 在第 22 行。关键行：

| elapsed_ms | mode | cursor_y | raw | 事件 |
|---|---|---|---|---|
| 62 | 1f7 | 22 | False | spinner 归位，光标在 22 行 |
| 1305 | 208 | 22 | **True** | claude 切 raw（mode 1f7→208） | 
| STOP 1307 | – | – | – | 当时以 raw 为信号，在此熄灯 |

> 光标直到熄灯都未离开 22 行 → 渲染根本没开始，spinner 提前空窗。

### 3.2 第二轮（raw 仅记录不停止，追完渲染）

窗口更大，spinner 在第 42 行。关键转折行：

| elapsed_ms | mode_hex | cursor_y | title | 事件 |
|---|---|---|---|---|
| 51 | 1f7 | 42 | *(空)* | spinner 归位 |
| 1181 | 208 | 42 | *(空)* | claude 切 raw — 距渲染还差整 8.7s |
| 1682 | 208 | 42 | claude | 标题初变（claude 进程早期) |
| 9746 | 208 | 42 | **✳ Claude Code** | claude 接管标题（开始渲染 UI 的强信号） |
| **9872** | – | **39** | ✳ Claude Code | **光标离开 42 行 → 熄灯，恰是界面出现那一下** |

## 4. 结论

1. **raw（stdin console mode）完全不可用作接管信号**：claude 启动约 1.2s 就开 raw 输入，
   但渲染 TUI 到约 9.9s 才发生，超前 8.5s。任何 raw 阈值 / 延迟补偿都不可靠。
2. **标题「✳ Claude Code」可达但不稳**：比渲染提前约 126ms，可作为辅助旁证；
   但 claude 进程早期（约 1.7s）标题会先变一次「claude」，不能做「变化即停」。
3. **屏幕光标离开 spinner 所在行 = 渲染开始**：claude 绘制第一帧必移动共享光标，
   `[Console]::CursorTop` 在 conpty 下可读，与「界面出现」几乎同步 → 命中最佳停点，
   且自适应任何冷启动时长（不设固定时间）。

## 5. 落地（决策 88 定稿）

`ClaudeCodeTask.UI/Launcher.ps1` 真实终端分支：

```
[ CctSpinner ] Start(SpinnerText, 100, 25000)   # autoStop 25s 仅兜底
记录 $yBase = [Console]::CursorTop              # spinner 每帧归位行
Start-Process ... -PassThru（不 -Wait）
while (-not $p.HasExited 且 < 25s) {
    $cy = [Console]::CursorTop
    if ($cy -ne $yBase) { break }               # claude 已渲染 → 停
    Start-Sleep 50ms
}
[CctSpinner]::Stop；$p.WaitForExit()
```

重定向 / 测试环境（Pester）无 TTY 可检，保持 `Start-Process -Wait` 直跑不变。

异常安全网：`autoStopMs` 与循环上限各 25s，互不悬空。

## 6. 未来复用

- 非交互版调试子命令可直接置 `$script:CctProbeEnabled = $true`，用 CSV 时间线核查不同
  claude 版本 / 终端的接管时序（raw 时刻、标题时刻、光标时刻三者对照定位渲染起点）。
- 若想再减少抽样式竞态，可考虑在检测到光标离开后停写一帧再确认（防抖），当前实测
  50ms 轮询 + 100ms spinner 帧率下已可靠命中，未做。