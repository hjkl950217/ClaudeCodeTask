@{
    RootModule           = 'ClaudeCodeTask.psm1'
    ModuleVersion        = '0.6.0'
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
            ReleaseNotes = '0.6.0：命名会话现在是目录入口。只要给会话起过名字，哪怕只有一条消息也会出现在列表里；同名多段（比如 /clear 之后继续聊）合并成一张卡，卡片指向文件时间最新的那段。选中卡片后先切到该会话的启动目录，再执行配置里的启动命令，和你在目录下直接运行 claude-dc 效果一致。未命名的目录仍按原来的阈值逻辑出卡。缓存结构未变，无需清理。 | 0.6.0: named sessions are now the entry point for a directory. Once you have named a session, it shows up in the list even if it has only one message. Multiple segments sharing the same name (for example, after /clear) are merged into one card that points to the most recently written file. Selecting a card first changes to the session start directory, then runs the launch command from your config, exactly like running claude-dc in that directory. Directories without a named session keep the previous threshold behavior. The cache format is unchanged.'
        }
    }
}
