# Selector stdin 模式管理测试（第六轮根因修复：VT 输入模式下 ReadKey 拆 ESC 序列）
# 根因（探针实锤 fix_verify.txt）：
#   stdin 带 ENABLE_VIRTUAL_TERMINAL_INPUT(0x0200) 时，[Console]::ReadKey 把方向键拆成
#   ESC/'['/'C' 三个普通字符（Key=None）→ 方向键导航失效 + '[C[C[D' 污染 query；
#   ESC 单字符 Key=None → Esc 退出失灵。cct 自身不设 VT_INPUT，但用户终端可能带着进
#   （PSReadLine/其他 TUI 工具残留），必须防御性关闭。
BeforeAll {
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Selector.ps1"

    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CctModeTest {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr GetStdHandle(uint h);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetConsoleMode(IntPtr h, uint mode);
    public const uint STD_INPUT = 0xFFFFFFF6;
}
'@
    # 本测试跑在非交互宿主（stdin 重定向）——GetConsoleMode 会失败。
    # 只测「模式计算」纯逻辑；真实控制台的开关由真实窗口 E2E 验证。
}

Describe 'Enter/Ctl-VtInput 模式管理（第六轮修复）' {
    It 'Get-CctCleanInputMode：带 VT_INPUT 的 mode 清掉 0x0200 位' {
        Get-CctCleanInputMode 0x03F7 | Should -Be 0x01F7
    }
    It 'Get-CctCleanInputMode：无 VT_INPUT 的 mode 原样返回' {
        Get-CctCleanInputMode 0x01F7 | Should -Be 0x01F7
    }
    It 'Get-CctCleanInputMode：只清 0x0200，其他位保留（如 0x03F6 → 0x01F6）' {
        Get-CctCleanInputMode 0x03F6 | Should -Be 0x01F6
    }
}

