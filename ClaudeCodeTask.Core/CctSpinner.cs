// 加载动画内核：后台线程旋转字符指示器（winget 风格 |/-\ 青色）
// 原内联 C# 移植（Spinner.ps1）。spinner 用 System.Threading.Timer 后台线程回调写屏，
// 回调必须是纯 .NET 代码（PS scriptblock 跨线程不安全）；Console.Write 内部自带锁，跨线程安全。
// 重定向判断放在 PS 层（Invoke-WithSpinner），C# 只负责真实终端下的写屏。
using System;
using System.Threading;

public static class CctSpinner {
    private static readonly char[] Frames = new char[] { '|', '/', '-', '\\' };
    private static volatile int _idx;
    private static volatile bool _stopped;
    private static string _currentText;

    // 启动后台 spinner：每 intervalMs 毫秒重写一行（不换行）。
    // autoStopMs 后自动停止，防止长时间交互式程序期间后台线程持续写屏。
    // 返回 Timer 供 Stop 停止。
    public static Timer Start(string text, int intervalMs, int autoStopMs) {
        _idx = 0;
        _stopped = false;
        _currentText = text;
        var t = new Timer(Tick, null, 0, intervalMs);
        if (autoStopMs > 0) {
            // 独立停止定时器；线程池保持引用直到触发，不必显式存
            new Timer(AutoStop, t, autoStopMs, Timeout.Infinite);
        }
        return t;
    }

    private static void Tick(object state) {
        if (_stopped) return;
        try {
            char c = Frames[_idx & 3];
            _idx++;
            // 每帧先 ESC[2K 擦整行再写：中文显示宽 2 列，按 Length 算宽度清不干净（实测残留「史 /」）
            Console.Write("\r\x1b[2K\x1b[37m" + _currentText + " \x1b[36m" + c + "\x1b[0m");
        } catch { }
    }

    private static void AutoStop(object state) {
        Stop((Timer)state);
    }

    // 停止并清行（\r + ESC[2K 擦整行 + \r 归位）；幂等安全
    public static void Stop(Timer t) {
        if (_stopped) return;
        _stopped = true;
        try {
            if (t != null) t.Dispose();
            Console.Write("\r\x1b[2K");
            _currentText = null;
        } catch { }
    }
}
