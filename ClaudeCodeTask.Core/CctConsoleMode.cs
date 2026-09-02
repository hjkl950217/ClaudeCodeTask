// 控制台模式内核：stdin 的 ENABLE_VIRTUAL_TERMINAL_INPUT 开关（kernel32 P/Invoke）
// 原内联 C# 移植（Selector.ps1）。stdin 带 0x0200 时 [Console]::ReadKey 把方向键拆成
// ESC/'['/'C' 三个普通字符（Key=None）→ 方向键导航失效 + '[C[C[D' 污染 query、ESC/ctrl+C
// 退出全失灵。cct 进入时防御性关闭（Enter-CctInputMode），退出时恢复原样。
using System;
using System.Runtime.InteropServices;

public static class CctConsoleMode {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(uint h);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleMode(IntPtr h, uint mode);
    public const uint STD_INPUT = 0xFFFFFFF6;
    public const uint ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;
}
