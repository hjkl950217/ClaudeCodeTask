# 界面层测试：卡片式网格（决策 43/44/45 + 第八轮边框/固定栏位 + 第九轮精简 + 第十轮帮助行贴底/选中亮青/卡间距）
# - New-CctFrame 纯函数：搜索行 / 列数 / 选中亮青 / 时间右对齐 / 帮助行 / Session 前缀 / 帧高恒=窗高
# - Show-CctSelector：KeySource 注入按键序列测导航（←→↑↓ / 过滤 / Backspace / Esc / Ctrl+C / clamp）
# 第十轮布局行号（WindowHeight=13 → MaxRows=2）：行0 搜索 / 行1 空 / 行2-6 块0 / 行7-11 块1 / 行12 帮助
# 固定栏：搜索行恒为帧首行、帮助行恒为窗口末行（余数行填帮助行上方，帧高恒 = WindowHeight，反馈 2）

BeforeAll {
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Display.ps1"
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Data.ps1"
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Clear.ps1"    # 删除确认屏依赖 Get-CctDirDeletePlan / Format-CctBytes
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
    function New-Up     { New-Key ([char]0)  ([ConsoleKey]::UpArrow) }
    function New-Left   { New-Key ([char]0)  ([ConsoleKey]::LeftArrow) }
    function New-Right  { New-Key ([char]0)  ([ConsoleKey]::RightArrow) }
    function New-BS     { New-Key ([char]8)  ([ConsoleKey]::Backspace) }
    function New-Char([char]$c) { New-Key $c ([ConsoleKey]::A) }
    # 第二十三轮：删除相关按键
    function New-DKey   { New-Key ([char]'d') ([ConsoleKey]::D) }
    function New-DelKey { New-Key ([char]0)   ([ConsoleKey]::Delete) }
    function New-YKey   { New-Key ([char]'y') ([ConsoleKey]::Y) }
    function New-NKey   { New-Key ([char]'n') ([ConsoleKey]::N) }

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
    It '结果提示显示在搜索框右侧、不覆盖搜索框（删完立刻能继续操作）' {
        $ok = @(New-CctFrame $script:gridTasks 0 '' 100 13 $script:now 5 $null '删除成功' $false)
        $plain = Get-Plain $ok[0]
        $plain | Should -Match '^搜索: \['            # 搜索框仍在原处
        $plain | Should -Match '删除成功$'             # 提示在右侧计数位
        $plain | Should -Not -Match '共 5 项'          # 计数位让给提示
        $ok[0] | Should -Match '\[92m'                 # 成功样式 = 亮绿
        $err = @(New-CctFrame $script:gridTasks 0 '' 100 13 $script:now 5 $null '该目录有会话正在使用' $true)
        $err[0] | Should -Match '\[91m'                # 失败样式 = 亮红
        (Get-Plain $err[0]) | Should -Match '^搜索: \['
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
        $last | Should -Match 'Esc 取消\s+v[\d.]+ by github'    # 提示与版权之间隔有填充空格
    }
    It '帮助行：版权带版本号，且版本号是从 psd1 读的（不写死）' {
        $frame = @(New-CctFrame $script:gridTasks 0 '' 100 13 $script:now)
        $last = Get-Plain $frame[-1]
        $expect = "v$((Import-PowerShellDataFile -LiteralPath "$PSScriptRoot\..\ClaudeCodeTask.UI\ClaudeCodeTask.psd1").ModuleVersion)"
        $script:CctVersionLabel | Should -Be $expect
        $script:CctVersionLabel | Should -Not -BeNullOrEmpty
        $last | Should -Match ([regex]::Escape($expect))
    }
    # 宽度档位随帮助行长度与版权文字宽度走（帮助行提示宽 43；版权按显示宽逐档实测，
    # 版本号变长时阈值自动跟随，不需要同步改测试）
    It '帮助行：中宽窗口版权缩短为 vX.Y.Z by github' {
        $frame = @(New-CctFrame $script:gridTasks 0 '' 70 13 $script:now)
        $last = Get-Plain $frame[-1]
        $last | Should -Match 'v[\d.]+ by github$'
        $last | Should -Not -Match 'hjkl950217'
    }
    It '帮助行：窄窗口版权只剩版本号' {
        $frame = @(New-CctFrame $script:gridTasks 0 '' 55 13 $script:now)
        $last = Get-Plain $frame[-1]
        $last | Should -Match 'v[\d.]+$'
        $last | Should -Not -Match 'github'
    }
    It '帮助行：极窄窗口版权全省略，仅保留按键提示' {
        $frame = @(New-CctFrame $script:gridTasks 0 '' 44 13 $script:now)
        $last = Get-Plain $frame[-1]
        $last | Should -Match 'Esc 取消'
        $last | Should -Not -Match 'by'
    }
    It '帮助行：提示本身超宽时按窗宽截断（不越界）' {
        $frame = @(New-CctFrame $script:gridTasks 0 '' 30 13 $script:now)
        $last = Get-Plain $frame[-1]
        (Get-DisplayWidth $last) | Should -BeLessOrEqual 30
        $last | Should -Match '^  ↑↓←→ 选择'
    }
    It '帮助行：多档宽度下显示宽均不超过窗口宽' {
        foreach ($w in 20, 30, 36, 38, 42, 50, 57, 80, 100) {
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

Describe 'New-CctConfirmFrame 删除确认屏（第二十三轮）' {
    BeforeAll {
        $script:plan = [pscustomobject]@{
            Dir = 'C:\Users\gt\.claude\projects\E-----AI---CPM---CPM----'
            Exists = $true; InUse = $false
            Sessions = @(
                [pscustomobject]@{ Sid8='b55a0b92'; Title='CPM操作助手开发';        LastWrite=[datetime]'2026-09-16 10:45'; Size=37758295 }
                [pscustomobject]@{ Sid8='8290501c'; Title='任务恢复执行';            LastWrite=[datetime]'2026-09-15 21:43'; Size=14866432 }
                [pscustomobject]@{ Sid8='9fee8090'; Title='CPM操作助手开发';        LastWrite=[datetime]'2026-09-10 09:27'; Size=8890880 }
                [pscustomobject]@{ Sid8='3db15803'; Title='组件属性 Web 渲染校验';   LastWrite=[datetime]'2026-09-14 14:16'; Size=1754112 }
                [pscustomobject]@{ Sid8='c8b9fd1c'; Title='claude.md 反黑话规则失效'; LastWrite=[datetime]'2026-09-15 22:05'; Size=1570611 }
            )
            SessionCount = 5; OtherCount = 2; TotalSize = 57600000
        }
        $script:confirm = [pscustomobject]@{
            TaskPath = 'E:\公司\AI任务\CPM相关\CPM操作助手'; ProjectDir = $script:plan.Dir
            Plan = $script:plan; Scroll = 0
        }
    }
    It '帧高恒 = 窗高，末行是按键提示' {
        $rows = @(New-CctConfirmFrame -Confirm $script:confirm -WindowWidth 100 -WindowHeight 16 -Now $script:now)
        $rows.Count | Should -Be 16
        (Get-Plain $rows[15]) | Should -Match 'y/d/回车 确认删除'
        (Get-Plain $rows[15]) | Should -Match 'n/Esc 取消'
    }
    It '末行按键提示：确认段亮红、取消段暗灰（与主界面按键提示同色）' {
        $rows = @(New-CctConfirmFrame -Confirm $script:confirm -WindowWidth 100 -WindowHeight 16 -Now $script:now)
        # 颜色码与文字之间夹着 ESC，必须把 ESC 拼进模式里，否则 ['确认删除' 紧跟 '[90m'] 永远失配
        $rows[15] | Should -Match ("\[91m\s+y/d/回车 确认删除" + [char]27 + "\[90m\s+n/Esc 取消")
    }
    It '头部显示目录、编码位置、会话数与总体积（第二十二轮的 LastUserMsgTime 场景数据）' {
        $plain = (New-CctConfirmFrame -Confirm $script:confirm -WindowWidth 120 -WindowHeight 16 -Now $script:now) |
                 ForEach-Object { Get-Plain $_ }
        ($plain -join "`n") | Should -Match '删除会话历史'
        ($plain -join "`n") | Should -Match '目录：E:\\公司\\AI任务\\CPM相关\\CPM操作助手'
        ($plain -join "`n") | Should -Match 'E-----AI---CPM---CPM----'
        ($plain -join "`n") | Should -Match '全部 5 个会话'
        ($plain -join "`n") | Should -Match '54\.9 MB'
        ($plain -join "`n") | Should -Match '另含 2 个附属会话文件'
    }
    It '清单按显示宽对齐：各行时间列起始列一致（中文标题宽窄不同也不跑偏）' {
        $plain = (New-CctConfirmFrame -Confirm $script:confirm -WindowWidth 120 -WindowHeight 16 -Now $script:now) |
                 ForEach-Object { Get-Plain $_ }
        $cols = @()
        foreach ($l in $plain) {
            $i = $l.IndexOf('09-16'); if ($i -lt 0) { $i = $l.IndexOf('09-15') }
            if ($i -lt 0) { $i = $l.IndexOf('09-10') }
            if ($i -lt 0) { $i = $l.IndexOf('09-14') }
            if ($i -ge 0) { $cols += (Get-DisplayWidth $l.Substring(0, $i)) }
        }
        $cols.Count | Should -Be 5
        @($cols | Select-Object -Unique).Count | Should -Be 1     # 五行的起始显示列完全相同
    }
    It '每行显示宽 ≤ 窗宽（120/60/40/30 逐档收窄都不越界，帧高仍 = 窗高）' {
        foreach ($w in @(120, 60, 40, 30)) {
            $rows = @(New-CctConfirmFrame -Confirm $script:confirm -WindowWidth $w -WindowHeight 16 -Now $script:now)
            $rows.Count | Should -Be 16
            foreach ($r in $rows) {
                (Get-DisplayWidth (Get-Plain $r)) | Should -BeLessOrEqual $w
            }
        }
    }
    It '窄窗逐级降级：W=44 去掉大小列，W=31 只剩 id 与标题（全列固定部分 37 列）' {
        $w44 = (New-CctConfirmFrame -Confirm $script:confirm -WindowWidth 44 -WindowHeight 16 -Now $script:now) |
               ForEach-Object { Get-Plain $_ } | Where-Object { $_ -match 'b55a0b92' }
        $w44 | Should -Not -Match 'MB'
        $w44 | Should -Match '\d\d-\d\d \d\d:\d\d'                 # 时间列仍在
        $w31 = (New-CctConfirmFrame -Confirm $script:confirm -WindowWidth 31 -WindowHeight 16 -Now $script:now) |
               ForEach-Object { Get-Plain $_ } | Where-Object { $_ -match 'b55a0b92' }
        $w31 | Should -Not -Match '\d\d-\d\d \d\d:\d\d'            # 时间列也去掉
        $w31 | Should -Match 'b55a0b92'
    }
    It '清单超出可视高度：末尾显示「…还有 N 个」，↑↓ 滚动可看到后面的项' {
        $plain = (New-CctConfirmFrame -Confirm $script:confirm -WindowWidth 100 -WindowHeight 10 -Now (Get-Date)) |
                 ForEach-Object { Get-Plain $_ }
        ($plain -join "`n") | Should -Match '…还有 \d+ 个'
        $scrolled = [pscustomobject]@{
            TaskPath = $script:confirm.TaskPath; ProjectDir = $script:confirm.ProjectDir
            Plan = $script:plan; Scroll = 4
        }
        $p2 = (New-CctConfirmFrame -Confirm $scrolled -WindowWidth 100 -WindowHeight 10 -Now (Get-Date)) |
              ForEach-Object { Get-Plain $_ }
        ($p2 -join "`n") | Should -Match 'c8b9fd1c'      # 滚动后能看到最后一项
    }
    It '该目录没有会话文件时给出说明而不是空白' {
        $empty = [pscustomobject]@{
            TaskPath = 'E:\t\empty'; ProjectDir = 'C:\p\E---empty'
            Plan = [pscustomobject]@{ Dir='C:\p\E---empty'; Exists=$true; InUse=$false; Sessions=@()
                                      SessionCount=0; OtherCount=0; TotalSize=0 }
            Scroll = 0
        }
        $plain = (New-CctConfirmFrame -Confirm $empty -WindowWidth 100 -WindowHeight 16 -Now $script:now) |
                 ForEach-Object { Get-Plain $_ }
        ($plain -join "`n") | Should -Match '该目录下没有会话文件'
    }
}

Describe 'Show-CctSelector 删除流程（第二十三轮）' {
    BeforeAll {
        function New-DelFixtureJsonl {
            param([string]$Dir, [string]$SessionId, [string]$Title, [int]$Msgs = 12, [string]$Cwd = $null)
            if (-not $Cwd) { $Cwd = $script:caseTask }
            $cwdJson = $Cwd -replace '\\', '\\'
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add(('{"type":"custom-title","customTitle":"' + $Title + '","sessionId":"' + $SessionId + '"}'))
            for ($i = 1; $i -le $Msgs; $i++) {
                $lines.Add(('{"type":"user","cwd":"' + $cwdJson + '","timestamp":"2026-09-15T10:00:00.000Z","message":{"role":"user","content":"m' + $i + '"},"uuid":"u' + $i + '","parentUuid":null}'))
            }
            [System.IO.File]::WriteAllLines((Join-Path $Dir "$SessionId.jsonl"), $lines, [System.Text.UTF8Encoding]::new($false))
        }
    }
    BeforeEach {
        # 每个用例独立 fixture（删除是破坏性的，不能共用）
        $script:caseRoot = Join-Path $env:TEMP ("cct_del_" + [guid]::NewGuid().ToString('N'))
        $script:caseProj = Join-Path $script:caseRoot 'projects'
        $script:caseTask = Join-Path $script:caseRoot 'taskX'
        $script:caseEnc  = Join-Path $script:caseProj 'E---taskX---'
        New-Item -ItemType Directory -Force $script:caseEnc, $script:caseTask | Out-Null
        New-DelFixtureJsonl $script:caseEnc 'aaaa1111' '示例任务' 12
        $script:caseTasks = @(Get-CctTasks -Root $script:caseProj -MinUserMsgs 10 -ExcludePatterns @())
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:caseRoot) { Remove-Item -LiteralPath $script:caseRoot -Recurse -Force }
    }
    It 'fixture 前置：扫出一张指向该编码目录的卡' {
        $script:caseTasks.Count | Should -Be 1
        # 不比全路径字符串：CI 的 $env:TEMP 是 8.3 短名（C:\Users\RUNNER~1\...），数据层回的是长名
        [System.IO.Path]::GetFileName($script:caseTasks[0].ProjectDir) | Should -Be 'E---taskX---'
        (Test-Path -LiteralPath $script:caseTasks[0].ProjectDir) | Should -BeTrue
    }
    It '搜索框为空按 d → 进确认屏，按 y 执行删除（整目录进回收站）' {
        $src = New-KeySource @((New-DKey), (New-YKey), (New-Esc))
        $r = Show-CctSelector $script:caseTasks -KeySource $src
        $r | Should -BeNullOrEmpty
        (Test-Path -LiteralPath $script:caseEnc) | Should -BeFalse
    }
    It '确认屏按 n 取消：目录原封不动' {
        $src = New-KeySource @((New-DKey), (New-NKey), (New-Esc))
        $r = Show-CctSelector $script:caseTasks -KeySource $src
        (Test-Path -LiteralPath $script:caseEnc) | Should -BeTrue
    }
    It '确认屏按 Esc 取消：目录原封不动' {
        $src = New-KeySource @((New-DKey), (New-Esc), (New-Esc))
        $r = Show-CctSelector $script:caseTasks -KeySource $src
        (Test-Path -LiteralPath $script:caseEnc) | Should -BeTrue
    }
    It '确认屏里其他键无效（不会误取消也不会误删）：中间夹方向键后按 y 仍能删' {
        $src = New-KeySource @((New-DKey), (New-Down), (New-Up), (New-YKey), (New-Esc))
        $r = Show-CctSelector $script:caseTasks -KeySource $src
        (Test-Path -LiteralPath $script:caseEnc) | Should -BeFalse
    }
    It 'Delete 键同样进确认屏（搜索框有词时也可用）' {
        $src = New-KeySource @((New-DelKey), (New-YKey), (New-Esc))
        $r = Show-CctSelector $script:caseTasks -KeySource $src
        (Test-Path -LiteralPath $script:caseEnc) | Should -BeFalse
    }
    It '搜索框已有内容时 d 照常进输入框（不触发删除）' {
        # 先按 x 进搜索词，再按 d、y：三个字符都进搜索框 → 全程没进确认态 → 目录仍在
        $src = New-KeySource @((New-Char ([char]'x')), (New-DKey), (New-YKey), (New-Esc))
        $r = Show-CctSelector $script:caseTasks -KeySource $src
        (Test-Path -LiteralPath $script:caseEnc) | Should -BeTrue
    }
    It '确认屏按 d 也能删（与「d 进确认」同键，连按两下即删）' {
        $src = New-KeySource @((New-DKey), (New-DKey), (New-Esc))
        Show-CctSelector $script:caseTasks -KeySource $src | Out-Null
        (Test-Path -LiteralPath $script:caseEnc) | Should -BeFalse
    }
    It '删除后的提示不吞按键：删完立刻能接着删下一个' {
        $enc2 = Join-Path $script:caseProj 'E---taskY---'
        $task2 = Join-Path $script:caseRoot 'taskY'
        New-Item -ItemType Directory -Force $enc2, $task2 | Out-Null
        New-DelFixtureJsonl -Dir $enc2 -SessionId 'bbbb2222' -Title '第二个任务' -Cwd $task2
        $tasks2 = @(Get-CctTasks -Root $script:caseProj -MinUserMsgs 10 -ExcludePatterns @())
        $tasks2.Count | Should -Be 2
        # 连删两次：若删除后的提示把紧随其后的按键吞掉，第二次 d/y 会错位，第二个目录删不掉
        $src = New-KeySource @((New-DKey), (New-YKey), (New-DKey), (New-YKey), (New-Esc))
        Show-CctSelector $tasks2 -KeySource $src | Out-Null
        (Test-Path -LiteralPath $script:caseEnc) | Should -BeFalse
        (Test-Path -LiteralPath $enc2) | Should -BeFalse
    }
}

