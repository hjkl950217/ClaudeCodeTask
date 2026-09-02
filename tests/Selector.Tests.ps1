# 界面层测试：卡片式网格（决策 43/44/45 + 第八轮边框/固定栏位 + 第九轮精简 + 第十轮帮助行贴底/选中亮青/卡间距）
# - New-CctFrame 纯函数：搜索行 / 列数 / 选中亮青 / 时间右对齐 / 帮助行 / Session 前缀 / 帧高恒=窗高
# - Show-CctSelector：KeySource 注入按键序列测导航（←→↑↓ / 过滤 / Backspace / Esc / Ctrl+C / clamp）
# 第十轮布局行号（WindowHeight=13 → MaxRows=2）：行0 搜索 / 行1 空 / 行2-6 块0 / 行7-11 块1 / 行12 帮助
# 固定栏：搜索行恒为帧首行、帮助行恒为窗口末行（余数行填帮助行上方，帧高恒 = WindowHeight，反馈 2）

BeforeAll {
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Display.ps1"
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Data.ps1"
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Selector.ps1"
    $script:esc = [char]27
    $script:now = [datetime]'2026-08-27 12:00:00'

    # 网格渲染测试用任务（含一个 Session 项验证 └ 前缀）
    $script:gridTasks = @(
        [pscustomobject]@{ Kind='Folder'; Path='E:\t\a'; Name='alpha';   Subtitle=$null; LastActive=[datetime]'2026-08-27 11:00:00'; SessionId=$null; GroupKey='E:\t\a' }
        [pscustomobject]@{ Kind='Session'; Path='E:\t\a'; Name='sessA';   Subtitle=$null; LastActive=[datetime]'2026-08-27 10:00:00'; SessionId='s1'; GroupKey='E:\t\a' }
        [pscustomobject]@{ Kind='Folder'; Path='E:\t\c'; Name='charlie'; Subtitle=$null; LastActive=[datetime]'2026-08-27 09:00:00'; SessionId=$null; GroupKey='E:\t\c' }
        [pscustomobject]@{ Kind='Folder'; Path='E:\t\d'; Name='delta';   Subtitle=$null; LastActive=[datetime]'2026-08-27 08:00:00'; SessionId=$null; GroupKey='E:\t\d' }
        [pscustomobject]@{ Kind='Folder'; Path='E:\t\e'; Name='echo';    Subtitle=$null; LastActive=[datetime]'2026-08-27 07:00:00'; SessionId=$null; GroupKey='E:\t\e' }
    )
    # 导航测试用任务（6 个，便于 col 跳转 / clamp 测试）
    $script:navTasks = @(
        [pscustomobject]@{ Kind='Folder'; Path='E:\t\1'; Name='alphaA';  Subtitle=$null; LastActive=[datetime]'2026-08-27 11:00:00'; SessionId=$null; GroupKey='E:\t\1' }
        [pscustomobject]@{ Kind='Folder'; Path='E:\t\2'; Name='alphaB';  Subtitle=$null; LastActive=[datetime]'2026-08-27 10:00:00'; SessionId=$null; GroupKey='E:\t\2' }
        [pscustomobject]@{ Kind='Folder'; Path='E:\t\3'; Name='gammaC';  Subtitle=$null; LastActive=[datetime]'2026-08-27 09:00:00'; SessionId=$null; GroupKey='E:\t\3' }
        [pscustomobject]@{ Kind='Folder'; Path='E:\t\4'; Name='deltaD';  Subtitle=$null; LastActive=[datetime]'2026-08-27 08:00:00'; SessionId=$null; GroupKey='E:\t\4' }
        [pscustomobject]@{ Kind='Folder'; Path='E:\t\5'; Name='echoE';   Subtitle=$null; LastActive=[datetime]'2026-08-27 07:00:00'; SessionId=$null; GroupKey='E:\t\5' }
        [pscustomobject]@{ Kind='Folder'; Path='E:\t\6'; Name='foxtrotF';Subtitle=$null; LastActive=[datetime]'2026-08-27 06:00:00'; SessionId=$null; GroupKey='E:\t\6' }
    )
    # 测试环境 cols 与 Show-CctSelector 同口径（无交互控制台时 WindowWidth 抛异常 → 兜底 120）
    $script:w = 120
    try { $script:w = [Console]::WindowWidth } catch {}
    $script:testCols = [Math]::Min(3, [Math]::Max(1, [int][Math]::Floor($script:w / 36)))

    # ANSI 剥离
    function Get-Plain([string]$Text) { $Text -replace "$script:esc\[[0-9;?]*[a-zA-Z]", '' }

    # 按键工厂：注意 [ConsoleKey]::Enter 必须括号包成表达式传入（Pester 6 参数集绑定坑）
    function New-Key([char]$ch, [ConsoleKey]$key) {
        [System.ConsoleKeyInfo]::new($ch, $key, $false, $false, $false)
    }
    function New-Enter { New-Key ([char]13) ([ConsoleKey]::Enter) }
    function New-Esc    { New-Key ([char]27) ([ConsoleKey]::Escape) }
    function New-Down   { New-Key ([char]0)  ([ConsoleKey]::DownArrow) }
    function New-Left   { New-Key ([char]0)  ([ConsoleKey]::LeftArrow) }
    function New-Right  { New-Key ([char]0)  ([ConsoleKey]::RightArrow) }
    function New-BS     { New-Key ([char]8)  ([ConsoleKey]::Backspace) }
    function New-Char([char]$c) { New-Key $c ([ConsoleKey]::A) }

    # 按键序列枚举器：用 Queue 避免 GetNewClosure 的变量快照陷阱（闭包内 $i++ 不持久）
    # 协议：每次调用返回下一个 ConsoleKeyInfo，$null 表示序列结束
    function New-KeySource([System.ConsoleKeyInfo[]]$keys) {
        $q = [System.Collections.Generic.Queue[System.ConsoleKeyInfo]]::new()
        foreach ($k in $keys) { $q.Enqueue($k) }
        return { if ($q.Count -gt 0) { $q.Dequeue() } else { $null } }.GetNewClosure()
    }
}

Describe 'New-CctFrame 卡片网格渲染' {
    It '搜索行：空查询显示淡色占位「直接输入即可按关键词实时过滤，支持中文」+ 共 N 项' {
        $frame = @(New-CctFrame $script:gridTasks 0 '' 100 13 $script:now)
        $plain = Get-Plain $frame[0]
        $plain | Should -Match '搜索: \[直接输入即可按关键词实时过滤，支持中文\]'
        $plain | Should -Match '共 5 项'
    }
    It '搜索行：有查询显示查询词 + M/N 计数' {
        $two = @($script:gridTasks[0], $script:gridTasks[1])
        $frame = @(New-CctFrame $two 0 'al' 100 13 $script:now 5)
        $plain = Get-Plain $frame[0]
        $plain | Should -Match '搜索: \[al\]'
        $plain | Should -Match '2/5'
    }
    It '列数计算：W=100 → 2 列（块 0 标题行含两个卡标题）' {
        $frame = @(New-CctFrame $script:gridTasks 0 '' 100 13 $script:now)
        $plain = Get-Plain $frame[3]
        $plain | Should -Match 'alpha'
        $plain | Should -Match 'sessA'
    }
    It '列数计算：W=120 → 3 列（块 0 标题行含三个卡标题）' {
        $frame = @(New-CctFrame $script:gridTasks 0 '' 120 13 $script:now)
        $plain = Get-Plain $frame[3]
        $plain | Should -Match 'alpha'
        $plain | Should -Match 'sessA'
        $plain | Should -Match 'charlie'
    }
    It '列数计算：W=60 → 1 列（块 0 标题行只有一个卡标题）' {
        $frame = @(New-CctFrame $script:gridTasks 0 '' 60 13 $script:now)
        $plain = Get-Plain $frame[3]
        $plain | Should -Match 'alpha'
        $plain | Should -Not -Match 'sessA'
    }
    It '卡片带上边框行（第八轮 4）：块 0 行 2 是 ┌─┐ 行' {
        $frame = @(New-CctFrame $script:gridTasks 0 '' 100 13 $script:now)
        $plain = Get-Plain $frame[2]
        $plain | Should -Match '^┌'
        $plain | Should -Match '┐'
    }
    It 'Session 项卡片标题行带目录括号（决策 48：多级平铺；第八轮去重后不同名保留）' {
        $frame = @(New-CctFrame $script:gridTasks 0 '' 100 13 $script:now)
        $plain = Get-Plain $frame[3]
        $plain | Should -Match 'sessA（a）'
    }
    It 'Session 项标题与目录名归一化相同 → 无括号（第八轮 bug1）' {
        $tasks = @(
            [pscustomobject]@{ Kind='Session'; Path='E:\t\CC_汉化'; Name='CC汉化'; Subtitle=$null; LastActive=$script:now.AddHours(-1); SessionId='s1'; GroupKey='E:\t\CC_汉化' }
        )
        $frame = @(New-CctFrame $tasks 0 '' 100 13 $script:now)
        $plain = Get-Plain $frame[3]
        $plain | Should -Match 'CC汉化'
        $plain | Should -Not -Match '（CC_汉化）'
    }
    It '选中卡：含边框 5 行整卡亮青（ESC[96m），未选中块无亮青（反馈 4）' {
        # selected=1（sessA，位于块 0 右列）；同一行左列 alpha 未选中
        $frame = @(New-CctFrame $script:gridTasks 1 '' 100 13 $script:now)
        $selPat = [regex]::Escape("$script:esc" + '[96m')
        $frame[2] | Should -Match $selPat      # 选中卡上边框亮青
        $frame[3] | Should -Match $selPat      # 选中卡标题行亮青
        $frame[4] | Should -Match $selPat      # 选中卡路径行 1 亮青
        $frame[5] | Should -Match $selPat      # 选中卡路径行 2 亮青
        $frame[6] | Should -Match $selPat      # 选中卡下边框亮青
        $frame[9] | Should -Not -Match $selPat # 未选中块路径行 1 无亮青
    }
    It '时间列右对齐（第八轮 5）：标题行内时间文本贴右 │ 边界' {
        $t = [pscustomobject]@{ Kind='Folder'; Path='E:\t\x'; Name='t0'; Subtitle=$null; LastActive=$script:now.AddMinutes(-59); SessionId=$null; GroupKey='E:\t\x' }
        $frame = @(New-CctFrame @($t) 0 '' 60 8 $script:now)
        $plain = Get-Plain $frame[3]
        # 时间右对齐到内容区右端：时间文本后紧跟「 │」（1 空格 + 右边框）
        $plain | Should -Match '59分钟前\s+│$'
        $plain | Should -Not -Match '│\s+59分钟前'   # 时间不在左边界
    }
    It '时间右对齐：名称段与时间段在标题行内不重叠（总显示宽不超卡框）' {
        $t = [pscustomobject]@{ Kind='Folder'; Path='E:\t\x'; Name='很长的任务名称占满整个卡片宽度测试用'; Subtitle=$null; LastActive=$script:now.AddMinutes(-59); SessionId=$null; GroupKey='E:\t\x' }
        $frame = @(New-CctFrame @($t) 0 '' 60 8 $script:now)
        $plain = Get-Plain $frame[3]
        $plain | Should -Match '59分钟前 +│$'
    }
    It '帮助行含 ↑↓←→ 选择 / 回车 启动 / Esc 取消' {
        $frame = @(New-CctFrame $script:gridTasks 0 '' 100 13 $script:now)
        $last = Get-Plain $frame[-1]
        $last | Should -Match '↑↓←→ 选择'
        $last | Should -Match '回车 启动'
        $last | Should -Match 'Esc 取消'
    }
    It '帮助行：宽窗口右侧居右显示完整版权 by github - hjkl950217' {
        $frame = @(New-CctFrame $script:gridTasks 0 '' 100 13 $script:now)
        $last = Get-Plain $frame[-1]
        $last | Should -Match '^  ↑↓←→ 选择'           # 按键提示保持原样开头
        $last | Should -Match 'by github - hjkl950217$' # 版权贴行尾（居右）
        $last | Should -Match 'Esc 取消\s+by github'    # 提示与版权之间隔有填充空格
    }
    It '帮助行：中宽窗口版权缩短为 by github' {
        $frame = @(New-CctFrame $script:gridTasks 0 '' 50 13 $script:now)
        $last = Get-Plain $frame[-1]
        $last | Should -Match 'by github$'
        $last | Should -Not -Match 'hjkl950217'
    }
    It '帮助行：窄窗口版权仅显示 by' {
        $frame = @(New-CctFrame $script:gridTasks 0 '' 42 13 $script:now)
        $last = Get-Plain $frame[-1]
        $last | Should -Match 'by$'
        $last | Should -Not -Match 'github'
    }
    It '帮助行：极窄窗口版权全省略，仅保留按键提示' {
        $frame = @(New-CctFrame $script:gridTasks 0 '' 36 13 $script:now)
        $last = Get-Plain $frame[-1]
        $last | Should -Match 'Esc 取消'
        $last | Should -Not -Match 'by'
    }
    It '帮助行：多档宽度下显示宽均不超过窗口宽' {
        foreach ($w in 36, 38, 42, 50, 57, 80, 100) {
            $frame = @(New-CctFrame $script:gridTasks 0 '' $w 13 $script:now)
            $width = Get-DisplayWidth (Get-Plain $frame[-1])
            $width | Should -BeLessThan ($w + 1) -Because "宽度 $w"
        }
    }
    It '帧高恒 = WindowHeight：卡片数变化时帧行数恒 = 窗高（第十轮反馈 2：帮助行贴底）' {
        # 5 任务（2 块）vs 1 任务（1 块不足）vs 0 任务——帧高都应相同 = WindowHeight=13
        $f5 = @(New-CctFrame $script:gridTasks 0 '' 100 13 $script:now)
        $f1 = @(New-CctFrame @($script:gridTasks[0]) 0 '' 100 13 $script:now)
        $f0 = @(New-CctFrame @() 0 '' 100 13 $script:now)
        $f5.Count | Should -Be 13   # 固定栏 3 行 + 2 块×5
        $f1.Count | Should -Be 13
        $f0.Count | Should -Be 13
        # 搜索行恒在帧首、帮助行恒在帧尾（行 diff 不重绘 → 固定栏位效果）
        (Get-Plain $f1[0]) | Should -Match '^搜索: \['
        (Get-Plain $f1[-1]) | Should -Match 'Esc 取消'
        (Get-Plain $f0[-1]) | Should -Match 'Esc 取消'
    }
    It 'WindowHeight 不可整除 5 时余数行填帮助行上方，帮助行恒在末行（反馈 2）' {
        $frame = @(New-CctFrame $script:gridTasks 0 '' 100 14 $script:now)
        $frame.Count | Should -Be 14             # 帧高恒 = WindowHeight
        (Get-Plain $frame[12]) | Should -Be ''   # 余数空行在帮助行上方
        (Get-Plain $frame[13]) | Should -Match 'Esc 取消'   # 帮助行贴底（窗口末行）
    }
    It '卡间距 1 空格：相邻卡边框间单空格（反馈 4）' {
        $frame = @(New-CctFrame $script:gridTasks 0 '' 100 13 $script:now)
        $plain = Get-Plain $frame[2]   # 块 0 上边框行
        $plain | Should -Match '┐ ┌'       # 1 空格卡间距
        $plain | Should -Not -Match '┐  ┌' # 不再是 2 空格
    }
    It '滚动时固定栏位不动：选中最后一项的帧与选中第一项的帧，行 0 与末行完全相同（第八轮 2）' {
        # 6 任务 W=100 → 2 列×3 块；WindowHeight=8（MaxRows=1）→ 选中 index5（第 3 块）滚动到底
        $six = @($script:navTasks[0..5])
        $fTop = @(New-CctFrame $six 0 '' 100 8 $script:now)
        $fBot = @(New-CctFrame $six 5 '' 100 8 $script:now)
        $fTop[0] | Should -Be $fBot[0]        # 搜索行不变
        $fTop[-1] | Should -Be $fBot[-1]      # 帮助行不变
        (Get-Plain $fBot[3]) | Should -Match 'foxtrotF'   # 滚到底：第 3 块标题可见
        (Get-Plain $fTop[3]) | Should -Not -Match 'foxtrotF'
    }
    It '每行显示宽度不超过 WindowWidth（含中文）' {
        $frame = @(New-CctFrame $script:gridTasks 0 '' 100 13 $script:now)
        $widths = foreach ($line in $frame) { Get-DisplayWidth (Get-Plain $line) }
        $maxW = ($widths | Measure-Object -Maximum).Maximum
        $maxW | Should -BeLessThan 101
    }
}

Describe 'Show-CctSelector 卡片网格导航（KeySource 注入）' {
    It '回车直接确认第一项' {
        $src = New-KeySource @((New-Enter))
        $r = Show-CctSelector $script:navTasks -KeySource $src
        $r | Should -Not -BeNullOrEmpty
        $r.Name | Should -Be 'alphaA'
    }
    It '→ → 回车：返回第 3 项' {
        $src = New-KeySource @((New-Right), (New-Right), (New-Enter))
        $r = Show-CctSelector $script:navTasks -KeySource $src
        $r.Name | Should -Be 'gammaC'
    }
    It '↓ 回车：按列跳转（cols 与当前终端一致）' {
        $src = New-KeySource @((New-Down), (New-Enter))
        $r = Show-CctSelector $script:navTasks -KeySource $src
        $r.Name | Should -Be $script:navTasks[$script:testCols].Name
    }
    It '← 在边界 clamp 到第一项' {
        $src = New-KeySource @((New-Left), (New-Enter))
        $r = Show-CctSelector $script:navTasks -KeySource $src
        $r.Name | Should -Be 'alphaA'
    }
    It '输入过滤字符后回车：返回过滤后第一项' {
        $src = New-KeySource @((New-Char 'a'), (New-Char 'l'), (New-Enter))
        $r = Show-CctSelector $script:navTasks -KeySource $src
        $r.Name | Should -Be 'alphaA'
    }
    It 'Backspace 删除查询字符后过滤恢复' {
        # al + x（无匹配 0 项）+ Backspace → al → 返回过滤后第一项
        $src = New-KeySource @((New-Char 'a'), (New-Char 'l'), (New-Char 'x'), (New-BS), (New-Enter))
        $r = Show-CctSelector $script:navTasks -KeySource $src
        $r.Name | Should -Be 'alphaA'
    }
    It '过滤后 0 项时回车返回 null' {
        $src = New-KeySource @((New-Char 'z'), (New-Enter))
        $r = Show-CctSelector $script:navTasks -KeySource $src
        $r | Should -BeNullOrEmpty
    }
    It '过滤后 selected 越界自动 clamp（选第 5 项后过滤缩到 2 项）' {
        # 4 次 → 选中 index 4（echoE），输入 alpha 过滤 → 2 项，selected clamp 到 1 → 返回 alphaB
        $src = New-KeySource @((New-Right), (New-Right), (New-Right), (New-Right), (New-Char 'a'), (New-Char 'l'), (New-Char 'p'), (New-Char 'h'), (New-Char 'a'), (New-Enter))
        $r = Show-CctSelector $script:navTasks -KeySource $src
        $r | Should -Not -BeNullOrEmpty
        $r.Name | Should -Be 'alphaB'
    }
    It 'Esc 返回 null' {
        $src = New-KeySource @((New-Esc))
        $r = Show-CctSelector $script:navTasks -KeySource $src
        $r | Should -BeNullOrEmpty
    }
    It 'Ctrl+C 返回 null' {
        $cc = [System.ConsoleKeyInfo]::new([char]3, [ConsoleKey]::C, $false, $false, $true)
        $src = New-KeySource @($cc)
        $r = Show-CctSelector $script:navTasks -KeySource $src
        $r | Should -BeNullOrEmpty
    }
    It 'KeySource 序列耗尽视为取消（返回 null，不死循环）' {
        $src = New-KeySource @()
        $r = Show-CctSelector $script:navTasks -KeySource $src
        $r | Should -BeNullOrEmpty
    }
}

