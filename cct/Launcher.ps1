# 执行层（spec 5）：先切目录再启动 claude（顺序不可颠倒，发现 9）
# 降级链（决策 23 + 三轮反馈修正）：-r 失败 → -c 接续最近会话 → 带 prompt 兜底
# 第四轮根因修复（2026-09-01 探针矩阵实锤）：
#   旧形态 $null = Invoke-WithSpinner { Invoke-Expression ... } 中 PowerShell 一旦捕获子进程输出
#   就给它挂 stdout 管道 → claude（Node）检测 stdout 非 TTY → 进 headless print 模式 →
#   无 prompt 启动报 "No deferred tool marker found"（L1 -r 与 L2 -c 同报此错的根因）。
#   探针矩阵：$null= / 管道 / 上层赋值捕获全管道化（B/C/G/I 形态）；Start-Process -NoNewWindow
#   子进程继承控制台（TTY 保持），ExitCode 是 Int32 本尊，绝无污染可能。
# 最终形态：Start-Process 直启 + -RedirectStandardError 分流（stderr 不与 TUI 输出竞争时序）

# 运行一条 claude 命令：旋转 spinner + stderr 分流；返回退出码（Int32 本尊，绝不被输出污染）
function Invoke-CctClaude {
    param([string]$Command, [string]$SpinnerText)

    # 命令拆分：首 token 为可执行文件（含引号形态），其余为参数行
    $m = [regex]::Match($Command, '^\s*("[^"]+"|\S+)\s*(.*)$')
    $exe = $m.Groups[1].Value.Trim('"')
    $argLine = $m.Groups[2].Value

    $errFile = Join-Path ([System.IO.Path]::GetTempPath()) ("cct_err_" + [guid]::NewGuid().ToString('N') + '.txt')

    try {
        # 旋转 spinner（反馈 3-1：恢复 |/-\ 动画）。决策 55 的「后台线程与 claude 输出并发写屏撕裂」
        # 根因已被第四轮 Start-Process 保 TTY 根治消除——claude 打开真实 TUI 接管屏幕后 spinner
        # 自然被覆盖，残留风险仅在 TUI 接管前 1-2s（claude 冷启动期）。autoStop 6s 兜底：
        # 长时间交互式会话期间后台线程不持续写屏。测试/重定向环境不启动 spinner（Invoke-WithSpinner 直跑）。
        # -NoNewWindow：继承当前控制台（TTY 保持，claude 开 TUI 而非 headless）
        # stdout 不重定向：交互式 TUI 直接渲染；stderr 分流到文件，结束后统一回放
        $code = Invoke-WithSpinner -Text $SpinnerText -AutoStopMs 6000 -ScriptBlock {
            $p = Start-Process -FilePath $exe -ArgumentList $argLine -RedirectStandardError $errFile -NoNewWindow -Wait -PassThru
            return [int]$p.ExitCode
        }
    } catch {
        # Start-Process 失败（命令不存在等）：清理临时 errFile 后报错
        if ($errFile -and (Test-Path -LiteralPath $errFile)) {
            Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
        }
        Write-Host ""
        Write-Error "启动命令失败: $($_.Exception.Message)"
        return 1
    }

    # stderr 回放（无后台线程写屏，时序干净）
    if (Test-Path -LiteralPath $errFile) {
        $err = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
        if ($err) { [Console]::Error.WriteLine($err.TrimEnd()) }
        Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
    }
    return $code
}

# spinner 文本（反馈 3-2）：正在启动会话：[账号调优（管理_sub2api）]——会话项带父目录括号，与卡片显示一致
function Get-CctSpinnerText {
    param([pscustomobject]$Item)
    $display = if ($Item.Kind -eq 'Session') {
        $parent = Split-Path -Leaf $Item.Path
        "$($Item.Name)（$parent）"
    } else { [string]$Item.Name }
    return "正在启动会话：[$display]"
}

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

    # spinner 文本带卡片名（反馈 3-2）
    $spinnerText = Get-CctSpinnerText $Item

    # 3. 启动（交互式 claude，直接调用透传错误——决策 27）
    try {
        $exit = Invoke-CctClaude $cmd $spinnerText
        if ($exit -eq 0) { return [pscustomobject]@{ Started = $true; Command = $cmd; Location = $Item.Path } }

        # 用户 Ctrl+C 主动中断（exit 130/143）：不降级不报错，静默收尾
        if (130, 143 -contains $exit) { return [pscustomobject]@{ Started = $true; Command = $cmd; Location = $Item.Path; Interrupted = $true } }

        # 降级 L2：接续最近会话（反馈 3-3：降级也要 spinner，接续会话启动也要时间）
        Write-Host "该会话无法恢复（退出码 $exit），已改为接续最近会话" -ForegroundColor Yellow
        $exit2 = Invoke-CctClaude $Config.launchCommand "$spinnerText（接续）"
        if ($exit2 -eq 0) { return [pscustomobject]@{ Started = $true; Command = $Config.launchCommand; Location = $Item.Path } }
        if ($exit2 -in 130, 143) { return [pscustomobject]@{ Started = $true; Command = $Config.launchCommand; Location = $Item.Path; Interrupted = $true } }
        # （-in 对 int 安全；Invoke-CctClaude 返回值已 [int] 强转，不可能再是数组）

        # 降级 L3：带 prompt 兜底（绕过 CC 无 prompt 空输入判定，实测退出码 0）
        Write-Host "接续最近会话也失败（退出码 $exit2），改为带提示词恢复" -ForegroundColor Yellow
        $fallbackCmd = if ($Item.Kind -eq 'Session' -and $Item.SessionId) {
            "$($Config.resumeCommand -replace '\{sessionId\}', $Item.SessionId) `"继续`""
        } else {
            "$($Config.launchCommand) `"继续`""
        }
        $exit3 = Invoke-CctClaude $fallbackCmd "$spinnerText（兜底）"
        if ($exit3 -eq 0) { return [pscustomobject]@{ Started = $true; Command = $fallbackCmd; Location = $Item.Path } }
        if ($exit3 -in 130, 143) { return [pscustomobject]@{ Started = $true; Command = $fallbackCmd; Location = $Item.Path; Interrupted = $true } }

        # 全失败：诊断块（反馈 3-4：输出任务完整地址 + 会话 ID，方便排错）
        Write-Host "带提示词恢复也失败（退出码 $exit3）" -ForegroundColor Red
        Write-Host ""
        Write-Host "===== 诊断信息 =====" -ForegroundColor Red
        Write-Host "任务路径: $($Item.Path)"
        if ($Item.SessionId) { Write-Host "会话 ID:  $($Item.SessionId)" }
        Write-Host "目录存在: $(Test-Path -LiteralPath $Item.Path)"
        Write-Host "退出码链: L1(-r)=$exit → L2(-c)=$exit2 → L3(prompt)=$exit3"
        return [pscustomobject]@{ Started = $false; Command = $fallbackCmd; Location = $Item.Path }
    } catch {
        Write-Error "启动失败: $_"
        return [pscustomobject]@{ Started = $false; Command = $cmd; Location = $Item.Path }
    }
}
