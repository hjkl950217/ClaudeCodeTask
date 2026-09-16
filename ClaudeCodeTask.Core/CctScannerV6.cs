// 数据层扫描器内核：从 ~/.claude/projects 的 jsonl 提取会话记录
// V6（2026-09-16）：输出 7→8 列，新增 lastUserMsgTs（最后一条「真实用户输入」的时间戳）。
//   动机：会话文件只要被打开一次就会刷新 mtime 与末条 timestamp——用 cct 进去看一眼再退出，
//   哪怕一个字没打，该会话也会被排成「最新」，卡片从此一直指向它，真正在用的新会话永远进不来。
//   判断「谁才是当前在用的会话」必须看你真正打字的时间，不能看文件被写过的时间。
//   同时收紧「真实用户输入」判定，堵住两类 CC 自己写入的漏网记录（原先只挡了 isMeta /
//   tool_result / local-command-caveat / command-name）：
//     - content 以 '<' 开头：<local-command-stdout> / <local-command-stderr> 等终端回显
//     - content 恰为 "Continue from where you left off."：CC 恢复会话时自动注入的续跑提示
//   不堵这两条，新列算出来仍是被刷新的当天时间（实测 b55a0b92 末条即 "See ya!" 回显）。
// 无 namespace：类型全名 CctScannerV6 与 PS 侧 [CctScannerV6] 引用、守卫
// if (-not ('CctScannerV6' -as [type])) 保持一致。类名版本化约定沿用：签名变更必须换名
// （V2→V3→V4→V5→V6），Add-Type 类型缓存在进程 AppDomain，改类体不换名则常驻终端加载旧类型。
using System;
using System.IO;
using System.Threading.Tasks;

public static class CctScannerV6 {
    // CC 恢复会话时自动注入的续跑提示原文（content 值为该句 → 非用户输入）。
    // 注意不带引号：content 值的起始字符就是 'C'（"content":" 已由 ccidx+11 跳过）
    private const string ResumeHintLiteral = "Continue from where you left off.";

    // 全量扫描单个 jsonl 会话文件：首现/末现 cwd / 最后时间戳 / 标题 / 用户消息数 / 祖先会话 id
    // 返回: [firstCwd, lastCwd, lastTimestamp, title, titleType, userMsgs, ancestors, lastUserMsgTs]
    // firstCwd = 会话启动/存储目录（jsonl 物理存放目录的编码依据，分组键）；
    // lastCwd  = 会话最后工作目录（resume 时 Set-Location 的目标）；
    // lastUserMsgTs = 最后一条真实用户输入的时间戳（空串 = 该会话无任何真实输入）。
    public static string[] ScanFile(string path) {
        // 自身会话 id = 文件名（jsonl 命名约定）；血缘收集时排除自身与非 GUID 形态
        // （工具输出里可能含任意 "session_id":"..." 字样，GUID 校验防误收）
        string selfId = System.IO.Path.GetFileNameWithoutExtension(path);
        string firstCwd = null;
        string lastCwd = null;
        string lastTs = null;
        string title = null;
        string titleType = null;
        string lastUserTs = null;
        int userMsgs = 0;
        var ancestors = new System.Collections.Generic.HashSet<string>();

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

                // 血缘提取：历史行的蛇形 session_id 指向祖先会话（≠ 自身，GUID 形态校验防误收）
                int sidx = line.IndexOf("\"session_id\":\"", StringComparison.Ordinal);
                if (sidx >= 0) {
                    int start = sidx + 14;
                    int end = line.IndexOf('"', start);
                    if (end > start) {
                        string sid = line.Substring(start, end - start);
                        if (sid != selfId && sid.Length == 36 && sid[8] == '-' && sid[13] == '-' && sid[18] == '-' && sid[23] == '-') {
                            ancestors.Add(sid);
                        }
                    }
                }

                if (line.Contains("\"type\":\"user\"")) {
                    if (line.Contains("\"isMeta\":true")) continue;
                    if (line.Contains("\"tool_use_id\"")) continue;   // tool_result 回传
                    // cc-switch 判定吸收：系统注入的伪用户消息不计
                    if (line.Contains("<local-command-caveat>")) continue;
                    int midx = line.IndexOf("\"message\":", StringComparison.Ordinal);
                    if (midx < 0) continue;
                    int ccidx = line.IndexOf("\"content\":\"", StringComparison.Ordinal);
                    int arridx = line.IndexOf("\"content\":[", StringComparison.Ordinal);
                    if (ccidx >= 0 && (arridx < 0 || ccidx < arridx)) {
                        // content 字符串形式：按值前缀排除系统注入
                        int valStart = ccidx + 11;
                        if (line.Length <= valStart) continue;                       // 空内容
                        char first = line[valStart];
                        if (first == '/') continue;                                  // slash command
                        if (first == '<') continue;                                  // <command-name> / <local-command-stdout> 等
                        if (line.IndexOf(ResumeHintLiteral, valStart, StringComparison.Ordinal) == valStart) continue;
                        userMsgs++;
                        if (tidx >= 0) lastUserTs = lastTs;   // 本行即最后一条真实输入
                    } else if (arridx >= 0) {
                        if (line.Contains("\"type\":\"text\"")) {                    // 数组含 text 块
                            userMsgs++;
                            if (tidx >= 0) lastUserTs = lastTs;
                        }
                    }
                }
            }
        }
        return new string[] { firstCwd ?? "", lastCwd ?? "", lastTs ?? "", title ?? "", titleType ?? "",
                              userMsgs.ToString(), string.Join(";", ancestors), lastUserTs ?? "" };
    }

    // 并行全扫。文件间无共享状态，Parallel.For 并发读盘+扫描；单文件失败
    // （被占用等）返回空记录不中断整体。298MB/133 文件串行 ~2.3s → 并行显著下降。
    public static string[][] ScanAll(string[] paths, int maxParallel) {
        string[][] results = new string[paths.Length][];
        ParallelOptions po = new ParallelOptions();
        po.MaxDegreeOfParallelism = Math.Max(1, maxParallel);
        Parallel.For(0, paths.Length, po, i => {
            try { results[i] = ScanFile(paths[i]); }
            catch { results[i] = new string[] { "", "", "", "", "", "0", "", "" }; }
        });
        return results;
    }
}
