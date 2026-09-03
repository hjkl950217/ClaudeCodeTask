# 加载动画：后台线程旋转字符指示器（winget 风格 |/-\ 青色）
# 权限解释：spinner 用 System.Threading.Timer 后台线程回调写屏，
#   PowerShell scriptblock 跨线程调用不安全，回调必须是纯 .NET 代码；Console.Write 内部自带锁，跨线程安全。
#   重定向判断放在 PS 层（Invoke-WithSpinner），C# 只负责真实终端下的写屏，不判断重定向。

# 后台 spinner 已独立到 ClaudeCodeTask.Core（预编译 dll）；Timer 后台线程回调需纯 .NET 代码
if (-not ('CctSpinner' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'lib\ClaudeCodeTask.Core.dll')
}

# PS 封装：控制台未重定向时启动 spinner，否则直接跑脚本（零输出）
# ScriptBlock 的返回值（含管道输出）原样透传
function Invoke-WithSpinner {
    param(
        [string]$Text,
        [scriptblock]$ScriptBlock,
        [int]$AutoStopMs = 8000
    )
    if ([Console]::IsOutputRedirected) {
        return & $ScriptBlock
    }
    $timer = [CctSpinner]::Start($Text, 100, $AutoStopMs)
    try {
        return & $ScriptBlock
    } finally {
        [CctSpinner]::Stop($timer)
    }
}
