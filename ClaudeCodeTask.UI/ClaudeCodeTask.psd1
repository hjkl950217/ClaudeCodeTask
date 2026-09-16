@{
    RootModule           = 'ClaudeCodeTask.psm1'
    ModuleVersion        = '0.4.0'
    CompatiblePSEditions = @('Core')
    GUID                 = '185bb7d7-e410-451b-8300-db7dfcb1a244'
    Author               = '长空X'
    CompanyName          = ''
    Copyright            = '(c) 长空X. All rights reserved.'
    Description          = 'Claude Code Task Selector —— Claude Code 任务文件夹选择器：一条命令列出所有 Claude Code 任务文件夹与历史会话。全屏卡片网格选择器，支持键盘导航与实时搜索，选中后自动 cd 进入任务目录并启动 claude。会话按目录自动聚合，手动命名优先、AI 标题保底，支持精确恢复中途切换到子目录的会话。内置增量缓存与并行扫描，热启动提速约 65-73%；cct clear 可一键清理扫描缓存或多余会话。预编译 C# 内核承担性能关键路径，PowerShell TUI 外壳。 | Claude Code Task Selector: one command lists all Claude Code task folders and session history. A full-screen card-grid picker with keyboard navigation and real-time search; selecting one cds into the task folder and launches claude. Sessions are auto-grouped by folder (manually named items win, AI titles as fallback), with precise resume for sessions that moved into subdirectories. Incremental cache plus parallel scanning make warm starts about 65-73% faster; cct clear cleans the scan cache or surplus sessions in one command. A pre-compiled C# kernel handles performance-critical paths under a PowerShell TUI shell.'
    PowerShellVersion    = '7.6'
    FunctionsToExport    = @('cct', 'Get-CctTasks', 'Show-CctSelector', 'Invoke-CctTask', 'Get-CctConfig', 'Get-CctSpinnerText', 'Invoke-WithSpinner')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('ClaudeCode', 'claude', 'claude-code', 'task-selector', 'selector', 'sessions', 'launcher', 'TUI', 'productivity', 'PSEdition_Core', 'Windows')
            LicenseUri   = 'https://github.com/hjkl950217/ClaudeCodeTask/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/hjkl950217/ClaudeCodeTask'
            ReleaseNotes = '0.4.0：新增选择器内删除——选中卡片按 d 或 Delete 进确认屏，一次删掉该卡片对应的整个编码目录（含记忆文件夹与附属会话），走 Windows 回收站可还原。确认屏按显示宽对齐四列、窄窗逐级降级，y/回车/d 执行、n/Esc 取消、其余键一律无效，删除结果提示显示在搜索框右侧，不覆盖搜索框也不吞按键。修复同一目录换了新会话后卡片永远指向命名旧会话的问题：根因是会话文件被打开一次就刷新末条时间戳，现在按「最后一条真实用户输入的时间」判定，并在目录内只有一个命名名时，由真实输入更晚的合格未命名会话顶替出卡、沿用该名字（只改展示，不写会话文件）。帮助行版权补上版本号。 | v0.4.0: adds in-selector deletion — press d or Delete on a card to open a confirmation screen and delete the whole encoded directory behind that card (including the memory folder and sub-sessions) in one go; deleted items go to the Windows Recycle Bin and can be restored. The confirmation screen aligns four columns by display width and degrades step by step on narrow windows; y/Enter/d confirms, n/Esc cancels, any other key does nothing, and the result notice appears to the right of the search box without hiding it or swallowing the keypress. Fixes cards pointing forever at an old named session after a directory moved on to a new one: the root cause was that opening a session file once refreshes its last timestamp. The rule now uses the last real user input time, and when a directory has a single manual title, the newer qualified unnamed session takes the card and keeps that title (display only, never written back to the session file). The help line copyright now carries the version.'
        }
    }
}
