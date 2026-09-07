# 数据层：从 ~/.claude/projects 的 jsonl 提取会话记录
# 性能关键：行级处理走 ClaudeCodeTask.Core 内核 dll（PowerShell 逐行调用开销是 C# 的 24 倍，实测 17s → 0.7s）
# C# 部分只做字符串标记扫描；「真实用户消息」判定语义与设计一致：
#   非 isMeta、content 为字符串（非 / 开头）或含 text 块（排除 tool_result 回传）
# 第四轮修复（2026-09-01）：
#   - 去掉第 10 条用户消息早停——探针实测 27/27 样本标题行在文件尾部，早停导致
#     LastTimestamp 停在早停点（b8c4b9b3 显示 08-25 实际活动到 08-31），排序与 resume 目标失真
#   - 吸收 cc-switch 判定：<local-command-caveat> / <command-name> 是系统注入的伪用户消息，不计入 UserMsgs
# 第五轮修复（2026-09-01）：
#   - 类名版本化 CctScanner → CctScannerV2：Add-Type 类型缓存在进程 AppDomain，
#     Import-Module -Force 不会重编译内联 C#。第三轮旧签名（双参 ScanFile）缓存在常驻
#     终端的进程里，守卫看到旧类型存在就跳过编译 → 新代码调单参重载抛异常被 catch 吃掉
#     → 所有会话变空记录 → 「没有可显示的任务」。版本化类名让新旧类型共存，常驻终端立即可用。
# 第九轮修复（2026-09-01）：
#   - 类名版本化 CctScannerV2 → CctScannerV3：签名变更（返回 firstCwd+lastCwd 两列 cwd）。
#     根因：jsonl 物理存储目录 = 会话启动目录（cwd-first）编码目录；旧版只记 lastCwd（末现 cwd），
#     按它分组会造出「幻影文件夹」——指向无编码目录的路径（公益站签到/js/claude-code-zh-cn），
#     选中后 claude -c 找不到会话（第九轮反馈 1+2）。V3 同时记首现（存储目录，分组键）
#     与末现（resume 目标目录，决策 9 启动先 Set-Location）两列。
# 第十一轮优化（2026-09-01）：
#   - 类名版本化 CctScannerV3 → CctScannerV4：新增 ScanAll 并行全扫。剖析实测瓶颈在 C# 串行
#     逐文件扫描（298MB/133 文件占全程 ~87%，~2.3s）。文件间无共享状态 → Parallel.For 并发读盘
#     扫描，单文件异常返回空记录不中断。V3 只留单文件 ScanFile 给 Read-CctSessionFile 复用。
# 第十三轮优化（2026-09-01）：
#   - 融合增量缓存：会话文件 ≥ 拐点（$script:CctCacheMinFiles=20，实测 N≤20 全扫平缓 ~150ms，
#     N≥20 线性涨至 ~660ms）且缓存存在时，用 mtime+size 判定未变文件直接复用上次精确扫描结果，
#     只重扫变化文件；文件 < 拐点走原全量方案且不读写缓存（少量会话时原本方案足够快）。
#   - 用户提议「行数近似 UserMsgs」经 130 文件样本验证不可行（比例 0.001~0.208、阈值误判 79-92%），
#     故缓存仍存精确 userMsgs（只是避免重复全量扫描），正确性无损。
#   - 缓存存 ~/.cct/cache.json（与 config.json 同目录）；读/写失败均静默回退全量。
# 第十九轮修复（2026-09-07）：
#   - 类名版本化 CctScannerV4 → CctScannerV5：输出 6→7 列，新增 ancestors（文件内蛇形
#     session_id 指向的他者会话 id，';' 连接）。根因：claude -c/--resume 续接会话会在同一
#     编码目录生成携带祖先历史的新 jsonl（历史行 message 层带蛇形 session_id），旧扫描
#     无法识别血缘 → 祖先与后代各自列出（同题同名重复卡，用户反馈 bug 1）；
#     碎片目录全部 <阈值时只剩 folder 卡，folder 副标题与进入后标题不一致（用户反馈 bug 2）。
#   - 聚合层新增「续接分叉折叠」：同目录内后代达标时折叠祖先（对话链只留最新端点）；
#     「目录升格」：纯碎片目录（无任何合格会话）把「有标题且 ≥1 真实消息」的最新碎片
#     升格为会话卡（豁免阈值，精确 --resume），folder 头被既有逻辑滤除。

# 文件数拐点：达到该值且缓存可用才走增量路径（测试可覆盖该 script 变量）
$script:CctCacheMinFiles = 20

# 标题类型枚举（读取层）：jsonl 标题事件原文 → 内部枚举。custom = 用户手动命名、
# ai = AI 自动生成。分组比较逻辑用此枚举；展示层另有中文值（见 Get-CctTasks 输出项）
$script:CctTitleKindMap = @{ 'custom' = 'userCustom'; 'ai' = 'aiGenerate' }

# C# 扫描器已独立到 ClaudeCodeTask.Core（预编译 dll，改动内核后跑该目录 build.ps1 重新编译）。
# 类名版本化约定保留：签名变更必须换名（V2→V3→V4→V5），Add-Type 类型缓存仍在进程 AppDomain。
if (-not ('CctScannerV5' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'lib\ClaudeCodeTask.Core.dll')
}

function Get-JsonProp {
    param([System.Text.Json.JsonElement]$Element, [string]$Name)
    if ($Element.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return $null }
    $v = [System.Text.Json.JsonElement]::new()
    if ($Element.TryGetProperty($Name, [ref]$v)) { return $v }
    return $null
}

# C# 扫描结果 string[] → 会话记录对象（Read-CctSessionFile 与 Get-CctTasks 并行路径共用）
function New-CctSessionRecord {
    param([string]$Path, [string[]]$Raw)

    $sessionId = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $lastTs = $null
    if ($Raw[2]) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($Raw[2], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed)) {
            $lastTs = $parsed
        }
    }
    $userMsgs = [int]$Raw[5]

    # 第十九轮：第 7 列 ancestors（';' 分隔的祖先会话 id；空串 → 空数组）
    $ancestors = if ($Raw.Length -gt 6 -and $Raw[6]) { $Raw[6].Split(';') } else { @() }

    return [pscustomobject]@{
        SessionId      = $sessionId
        StartCwd       = if ($Raw[0]) { $Raw[0] } else { $null }   # 首现 cwd = 启动/存储目录
        Cwd            = if ($Raw[1]) { $Raw[1] } else { $null }   # 末现 cwd = resume 目标
        LastTimestamp  = $lastTs
        Title          = if ($Raw[3]) { $Raw[3] } else { $null }
        TitleType      = if ($Raw[4] -and $script:CctTitleKindMap.ContainsKey([string]$Raw[4])) { $script:CctTitleKindMap[[string]$Raw[4]] } else { $null }
        UserMsgs       = $userMsgs
        HasRealUserMsg = ($userMsgs -ge 1)
        Ancestors      = @($ancestors)
    }
}

# 读取单个会话文件（C# 快扫 + PowerShell 只做类型转换）
function Read-CctSessionFile {
    param([string]$Path)

    $sessionId = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $raw = $null
    try {
        $raw = [CctScannerV5]::ScanFile($Path)
    } catch {
        # 读取失败（文件被占用等）：返回空记录
        return [pscustomobject]@{
            SessionId = $sessionId; StartCwd = $null; Cwd = $null; LastTimestamp = $null
            Title = $null; TitleType = $null; UserMsgs = 0; HasRealUserMsg = $false; Ancestors = @()
        }
    }

    return New-CctSessionRecord $Path $raw
}

# 读取会话扫描缓存（结构: {version:2, files:{<path>:{mt:<ticks>, sz:<bytes>, raw:<string[7]>}}}）
# 第十九轮 version 1→2（raw 6→7 列，旧缓存无 ancestors 列）；损坏/版本不符/不存在 →
# 返回 $null（调用方回退全量扫描，旧缓存被新结构覆盖）
function Read-CctSessionCache {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $obj = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($null -eq $obj -or $obj.version -ne 2 -or $null -eq $obj.files) { return $null }
        $filesMap = @{}
        foreach ($prop in $obj.files.PSObject.Properties) { $filesMap[$prop.Name] = $prop.Value }
        return @{ version = 2; files = $filesMap }
    } catch {
        return $null
    }
}

# 写会话扫描缓存（失败静默：缓存只是加速手段，下次重建即可）
function Write-CctSessionCache {
    param([string]$Path, [hashtable]$Cache)

    try {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        $Cache | ConvertTo-Json -Depth 5 -Compress | Set-Content -LiteralPath $Path -Encoding utf8 -ErrorAction Stop
    } catch {
        # 缓存写失败不致命：下次无缓存走全量
    }
}

# 扫描 projects 目录并聚合成列表项（spec 3.3/3.5/3.6）
function Get-CctTasks {
    [CmdletBinding()]
    param(
        [string]$Root = (Join-Path $env:USERPROFILE '.claude\projects'),
        [int]$MinUserMsgs = 10,
        # 排除模式（默认值须与 Config.ps1 保持一致；ConfigBackup 不默认排除——用户决策 2026-08-31）：
        # Temp 排除开发探针残留会话（发现 9/22 调研产物）
        [string[]]$ExcludePatterns = @('AppData\Local\Temp'),
        # 第十三轮：扫描缓存路径（文件数 ≥ 拐点时用于增量复用；测试可注入独立路径）
        [string]$CachePath = (Join-Path $env:USERPROFILE '.cct\cache.json'),
        # 第十八轮：查找/列出时是否含「文件夹」条目。内部始终用 folder 做分组排序；仅返回前按此过滤。
        # 默认 true（扫描器原始产物）；交互式/list/find/run 等输出链路按 config.includeFolderFind 传值。
        [bool]$IncludeFolderFind = $true
    )

    # 1. 收集文件（排除 agent-/journal.jsonl/排除模式）
    $files = Get-ChildItem -LiteralPath $Root -Recurse -Filter *.jsonl -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -ne 'journal.jsonl' -and $_.Name -notlike 'agent-*'
    }
    if ($ExcludePatterns) {
        $files = $files | Where-Object {
            $p = $_.FullName
            -not ($ExcludePatterns | Where-Object { $p -like "*$_*" })
        }
    }

    # 2. 逐文件提取（第十一轮：C# 并行全扫；第十三轮：文件数 ≥ 拐点且缓存可用时增量复用）
    $paths = [string[]]@($files | ForEach-Object { $_.FullName })
    $degree = [Math]::Min($paths.Length, [Math]::Max(1, [Environment]::ProcessorCount))

    $rawAll = $null
    $cache = Read-CctSessionCache -Path $CachePath
    if ($paths.Count -ge $script:CctCacheMinFiles -and $null -ne $cache) {
        # 增量：mtime+size 命中的文件复用缓存精确结果，只重扫变化/新增的文件
        $fileByPath = @{}
        foreach ($f in $files) { $fileByPath[$f.FullName] = $f }
        $pathIndex = @{}
        for ($i = 0; $i -lt $paths.Length; $i++) { $pathIndex[$paths[$i]] = $i }
        $rawAll = [string[][]]::new($paths.Length)
        $dirty = [System.Collections.Generic.List[string]]::new()
        foreach ($f in $files) {
            $p = $f.FullName
            $entry = $cache.files[$p]
            if ($null -ne $entry -and $entry.mt -eq $f.LastWriteTimeUtc.Ticks -and $entry.sz -eq $f.Length) {
                $rawAll[$pathIndex[$p]] = [string[]]$entry.raw
            } else {
                $dirty.Add($p)
            }
        }
        if ($dirty.Count -gt 0) {
            $dirtyRaw = [CctScannerV5]::ScanAll([string[]]@($dirty), $degree)
            for ($d = 0; $d -lt $dirty.Count; $d++) {
                $p = $dirty[$d]
                $rawAll[$pathIndex[$p]] = $dirtyRaw[$d]
                $cf = $fileByPath[$p]
                $cache.files[$p] = [pscustomobject]@{ mt = $cf.LastWriteTimeUtc.Ticks; sz = $cf.Length; raw = $dirtyRaw[$d] }
            }
        }
        # 清理缓存中已不存在的文件（目录被删/会话清理）
        foreach ($key in @($cache.files.Keys)) {
            if (-not $pathIndex.ContainsKey($key)) { $cache.files.Remove($key) }
        }
        Write-CctSessionCache -Path $CachePath -Cache $cache
    } else {
        # 全量（无缓存或文件 < 拐点）；≥ 拐点且首次无缓存时写缓存供下次增量
        $rawAll = [CctScannerV5]::ScanAll($paths, $degree)
        if ($paths.Count -ge $script:CctCacheMinFiles) {
            $newCache = @{ version = 2; files = @{} }
            for ($i = 0; $i -lt $paths.Length; $i++) {
                $cf = $files[$i]
                $newCache.files[$paths[$i]] = [pscustomobject]@{ mt = $cf.LastWriteTimeUtc.Ticks; sz = $cf.Length; raw = $rawAll[$i] }
            }
            Write-CctSessionCache -Path $CachePath -Cache $newCache
        }
    }

    $sessions = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $paths.Length; $i++) {
        $r = New-CctSessionRecord $paths[$i] $rawAll[$i]
        if ($r.Cwd -and $r.LastTimestamp) { $sessions.Add($r) }
    }

    # 3. 过滤失效目录（worktree 残留 + 已删除）与排除模式的 cwd（Temp 探针残留会话的 cwd 指向 Temp）
    #    第九轮：StartCwd（存储目录，分组键）与 Cwd（resume 目标）都须存在且过排除模式
    #    第十一轮：Test-Path → Directory.Exists（纯 .NET 目录存在性判定，免 PowerShell 提供程序开销）
    $valid = @($sessions | Where-Object {
        $startCwd = $_.StartCwd
        $cwd = $_.Cwd
        $startCwd -and $cwd -and
        $startCwd -notmatch '\.claude[\\/]worktrees' -and [System.IO.Directory]::Exists($startCwd) -and
        -not ($ExcludePatterns | Where-Object { $startCwd -like "*$($_)*" }) -and
        $cwd -notmatch '\.claude[\\/]worktrees' -and [System.IO.Directory]::Exists($cwd) -and
        -not ($ExcludePatterns | Where-Object { $cwd -like "*$($_)*" })
    })

    # 4. 按 StartCwd 分组（第九轮：jsonl 物理存储于启动目录编码目录，按首现 cwd 分组，
    #    文件夹编码目录必有 jsonl → 幻影 Folder 天然消失；Session 项 Path 仍用末现 cwd）
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($g in ($valid | Group-Object StartCwd)) {
        $folderPath = $g.Name
        $folderName = Split-Path -Leaf $folderPath
        $byTime = @($g.Group | Sort-Object LastTimestamp -Descending)
        $latest = $byTime[0]

        # 会话项判定（spec 3.5）
        $manualGroups = @($g.Group | Where-Object TitleType -eq 'userCustom' | Group-Object Title)
        $sessionItems = [System.Collections.Generic.List[object]]::new()
        foreach ($mg in $manualGroups) {
            # 决策 34 修订（2026-08-27）：手动命名同样受 ≥MinUserMsgs 阈值约束——
            # <10 条的会话哪怕手动命名意义也不大。组内全部 <阈值 → 整组不保留。
            # 同名组内达标的会话各自列为独立条目（≥10 的多条同名不再只留最新，
            # 否则旧同名会话被静默隐藏、cct 进不去）；界面靠最近活动时间区分同名条目
            $qualified = @($mg.Group | Where-Object { $_.HasRealUserMsg -and $_.UserMsgs -ge $MinUserMsgs } | Sort-Object LastTimestamp -Descending)
            if ($qualified.Count -eq 0) { continue }   # 整组不保留（不再防御回退到 <阈值 文件）

            # 第十九轮分叉折叠：同组内「祖先被本组合格后代声明」→ 祖先不单独列出。
            # 判据：后代 jsonl 历史行携带蛇形 session_id 指向祖先（扫描器 V5 ancestors 列），
            # 该字段只在续接分叉复制祖先历史时出现。只折叠同目录的祖先（血缘是目录内的对话链）。
            $qualifiedIds = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($q in $qualified) { [void]$qualifiedIds.Add($q.SessionId) }
            $supersededIds = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($q in $qualified) {
                foreach ($a in $q.Ancestors) {
                    if ($qualifiedIds.Contains($a) -and $a -ne $q.SessionId) { [void]$supersededIds.Add($a) }
                }
            }
            foreach ($q in $qualified) {
                if ($supersededIds.Contains($q.SessionId)) { continue }   # 被合格后代折叠，对话链只留最新端点
                $sessionItems.Add([pscustomobject]@{
                    Kind = 'Session'; Path = $q.Cwd; Name = $mg.Name   # Path=末现 cwd（resume 目标）
                    Subtitle = $null
                    LastActive = $q.LastTimestamp.ToLocalTime()
                    SessionId = $q.SessionId
                    GroupKey = $folderPath; TitleType = '自定义命名'   # GroupKey=StartCwd（挂到存储目录文件夹下）
                })
            }
        }
        if ($manualGroups.Count -eq 0) {
            # 保底自动项：目录无任何手动命名项（决策 36 原语义不变——手动项被阈值过滤不触发自动项顶替），
            # ≥MinUserMsgs 的 ai-title 里最新一个（决策 35/37；口径与决策 32 一致：≥）
            $aiBig = @($g.Group | Where-Object { $_.TitleType -eq 'aiGenerate' -and $_.UserMsgs -ge $MinUserMsgs -and $_.HasRealUserMsg } | Sort-Object LastTimestamp -Descending)
            if ($aiBig.Count -gt 0) {
                $sessionItems.Add([pscustomobject]@{
                    Kind = 'Session'; Path = $aiBig[0].Cwd; Name = $aiBig[0].Title   # Path=末现 cwd（resume 目标）
                    Subtitle = $null
                    LastActive = $aiBig[0].LastTimestamp.ToLocalTime()
                    SessionId = $aiBig[0].SessionId
                    GroupKey = $folderPath; TitleType = '自动生成'
                })
            }
        }

        # 第十九轮目录升格：组内无任何会话项（手动组全 <阈值 或无手动项且无达标 ai 项）时，
        # 把「有标题且 ≥1 条真实消息」的最新碎片升格为会话卡（豁免阈值）——碎片目录此前只剩
        # folder 卡，副标题（标题）与进入后 `claude -c` 恢复会话的标题不一致（用户反馈 bug 2）；
        # 升格后卡片标题 = 进入后标题，且用精确 --resume 而非 -c 猜测最新。folder 头被既有
        # includeFolderFind 逻辑滤除（同组已有会话项）。
        if ($sessionItems.Count -eq 0) {
            $promote = @($g.Group | Where-Object { $_.Title -and $_.HasRealUserMsg } | Sort-Object LastTimestamp -Descending)
            if ($promote.Count -gt 0) {
                $p = $promote[0]
                $sessionItems.Add([pscustomobject]@{
                    Kind = 'Session'; Path = $p.Cwd; Name = $p.Title
                    Subtitle = $null
                    LastActive = $p.LastTimestamp.ToLocalTime()
                    SessionId = $p.SessionId
                    GroupKey = $folderPath; TitleType = if ($p.TitleType -eq 'userCustom') { '自定义命名' } else { '自动生成' }
                })
            }
        }

        # 文件夹项（副标题 = 最近会话标题，无标题留空，决策 30/38）
        $folderItem = [pscustomobject]@{
            Kind = 'Folder'; Path = $folderPath; Name = $folderName
            Subtitle = $latest.Title
            LastActive = $latest.LastTimestamp.ToLocalTime()
            SessionId = $null; GroupKey = $folderPath; TitleType = $null
        }
        $items.Add($folderItem)
        foreach ($s in ($sessionItems | Sort-Object LastActive -Descending)) { $items.Add($s) }
    }

    # 5. 文件夹间按最近活动降序，会话项紧跟所属文件夹（两步法：先排序文件夹，再挂会话项）
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($f in ($items | Where-Object Kind -eq 'Folder' | Sort-Object LastActive -Descending)) {
        $result.Add($f)
        foreach ($s in ($items | Where-Object { $_.Kind -eq 'Session' -and $_.GroupKey -eq $f.GroupKey } | Sort-Object LastActive -Descending)) {
            $result.Add($s)
        }
    }
    # 第十八轮：includeFolderFind=0 时去掉 folder 行；session 顺序不变（仍按目录分组、组内按最近活动降序）
    if (-not $IncludeFolderFind) {
        return @($result | Where-Object { $_.Kind -eq 'Session' })
    }
    # includeFolderFind=1 时 folder 头仅在「组内无任何 Session 项」的纯目录保留——
    # 同目录已有可 resume 的会话时 folder 头是冗余入口（session 优先），滤除之；顺序不受影响
    $sessionKeys = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($s in $result) {
        if ($s.Kind -eq 'Session' -and $s.GroupKey) { [void]$sessionKeys.Add([string]$s.GroupKey) }
    }
    return @($result | Where-Object { -not ($_.Kind -eq 'Folder' -and $sessionKeys.Contains([string]$_.GroupKey)) })
}

# 搜索过滤（决策 16：文件夹名+会话标题+全路径并集，不区分大小写子串；会话命中带出父文件夹）
function Filter-CctTasks {
    param([pscustomobject[]]$Tasks, [string]$Query)
    if ([string]::IsNullOrWhiteSpace($Query)) { return $Tasks }
    $q = $Query.ToLowerInvariant()

    $hits = @($Tasks | Where-Object {
        $t = $_
        ($t.Name -and $t.Name.ToLowerInvariant().Contains($q)) -or
        ($t.Subtitle -and $t.Subtitle.ToLowerInvariant().Contains($q)) -or
        ($t.Path -and $t.Path.ToLowerInvariant().Contains($q))
    })
    # 会话项命中 → 父文件夹（同 GroupKey 的 Folder 项）一起显示
    $groupKeys = @($hits | Where-Object Kind -eq 'Session' | ForEach-Object GroupKey)
    $withContext = @($hits) + @($Tasks | Where-Object { $_.Kind -eq 'Folder' -and $groupKeys -contains $_.GroupKey })
    # 保持原顺序去重；Session 同名且同 cwd 可有多条（同名会话各自列出），去重键并入 SessionId
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $result = foreach ($it in $withContext) {
        $key = if ($it.Kind -eq 'Session') { "Session|$($it.SessionId)" } else { "$($it.Kind)|$($it.Path)|$($it.Name)" }
        if ($seen.Add($key)) { $it }
    }
    return @($result)
}
