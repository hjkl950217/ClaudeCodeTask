// 数据层扫描器内核：从 ~/.claude/projects 的 jsonl 提取会话记录
// 原内联 C# 移植（Data.ps1）。无 namespace：类型全名 CctScannerV4 与 PS 侧
// [CctScannerV4] 引用、守卫 if (-not ('CctScannerV4' -as [type])) 保持一致。
// 类名版本化约定沿用：签名变更必须换名（V2→V3→V4），Add-Type 类型缓存在
// 进程 AppDomain，改类体不换名则常驻终端加载旧类型。
using System;
using System.IO;
using System.Threading.Tasks;

public static class CctScannerV4 {
    // 全量扫描单个 jsonl 会话文件：首现/末现 cwd / 最后时间戳 / 标题 / 用户消息数
    // 返回: [firstCwd, lastCwd, lastTimestamp, title, titleType, userMsgs]
    // firstCwd = 会话启动/存储目录（jsonl 物理存放目录的编码依据，分组键）；
    // lastCwd  = 会话最后工作目录（resume 时 Set-Location 的目标）。
    public static string[] ScanFile(string path) {
        string firstCwd = null;
        string lastCwd = null;
        string lastTs = null;
        string title = null;
        string titleType = null;
        int userMsgs = 0;

        string line;
        using (var sr = new StreamReader(path)) {
            while ((line = sr.ReadLine()) != null) {
                if (string.IsNullOrWhiteSpace(line)) continue;

                int idx = line.IndexOf("\"cwd\":\"", StringComparison.Ordinal);
                if (idx >= 0) {
                    int start = idx + 7;
                    int end = line.IndexOf('"', start);
                    if (end > start) {
                        string val = line.Substring(start, end - start).Replace("\\\\", "\\");
                        if (firstCwd == null) firstCwd = val;   // 首次命中 = 启动/存储目录
                        lastCwd = val;                          // 每次覆盖 = 末现目录
                    }
                }
                int tidx = line.IndexOf("\"timestamp\":\"", StringComparison.Ordinal);
                if (tidx >= 0) {
                    lastTs = line.Substring(tidx + 13, 24);
                }
                int cidx = line.IndexOf("\"customTitle\":\"", StringComparison.Ordinal);
                if (cidx >= 0) {
                    int start = cidx + 15;
                    int end = line.IndexOf('"', start);
                    if (end > start) { title = line.Substring(start, end - start); titleType = "custom"; }
                }
                int aidx = line.IndexOf("\"aiTitle\":\"", StringComparison.Ordinal);
                if (aidx >= 0 && titleType != "custom") {
                    int start = aidx + 11;
                    int end = line.IndexOf('"', start);
                    if (end > start) { title = line.Substring(start, end - start); titleType = "ai"; }
                }

                if (line.Contains("\"type\":\"user\"")) {
                    if (line.Contains("\"isMeta\":true")) continue;
                    if (line.Contains("\"tool_use_id\"")) continue;   // tool_result 回传
                    // cc-switch 判定吸收：系统注入的伪用户消息不计
                    if (line.Contains("<local-command-caveat>")) continue;
                    if (line.Contains("\"<command-name>")) continue;
                    int midx = line.IndexOf("\"message\":", StringComparison.Ordinal);
                    if (midx < 0) continue;
                    int ccidx = line.IndexOf("\"content\":\"", StringComparison.Ordinal);
                    int arridx = line.IndexOf("\"content\":[", StringComparison.Ordinal);
                    if (ccidx >= 0 && (arridx < 0 || ccidx < arridx)) {
                        // content 字符串形式：取前缀判断 slash command
                        if (line.Length > ccidx + 11 && line[ccidx + 11] == '/') continue;
                        userMsgs++;
                    } else if (arridx >= 0) {
                        if (line.Contains("\"type\":\"text\"")) userMsgs++;   // 数组含 text 块
                    }
                }
            }
        }
        return new string[] { firstCwd ?? "", lastCwd ?? "", lastTs ?? "", title ?? "", titleType ?? "", userMsgs.ToString() };
    }

    // 并行全扫。文件间无共享状态，Parallel.For 并发读盘+扫描；单文件失败
    // （被占用等）返回空记录不中断整体。298MB/133 文件串行 ~2.3s → 并行显著下降。
    public static string[][] ScanAll(string[] paths, int maxParallel) {
        string[][] results = new string[paths.Length][];
        ParallelOptions po = new ParallelOptions();
        po.MaxDegreeOfParallelism = Math.Max(1, maxParallel);
        Parallel.For(0, paths.Length, po, i => {
            try { results[i] = ScanFile(paths[i]); }
            catch { results[i] = new string[] { "", "", "", "", "", "0" }; }
        });
        return results;
    }
}
