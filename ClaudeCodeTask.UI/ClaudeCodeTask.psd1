@{
    RootModule           = 'ClaudeCodeTask.psm1'
    ModuleVersion        = '0.5.0'
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
            ReleaseNotes = '0.5.0：同一个会话不再显示成两张卡。分组键和恢复目录改为「项目根」——从会话启动目录向上找最近的含 CLAUDE.md 或 AGENTS.md 的目录（两个文件名都认），找不到就沿用原目录。在子目录启动、会话中又切回上级的同一对话链会归到同一组，祖先与后代不再各出一张同名卡。选中卡片后先切到项目根再启动 claude，下次恢复不会又停在子级。缓存结构未变，无需清理。 | v0.5.0: one conversation no longer shows up as two cards. Grouping and the resume target now use the project root — the nearest directory containing CLAUDE.md or AGENTS.md, walking up from the session start directory (both filenames are accepted), falling back to the original directory when none is found. A conversation chain that started in a subdirectory and moved back up is grouped under the same project, so an ancestor and its descendant no longer produce two identically named cards. cct also changes to the project root before launching claude, so the next resume does not land in a subdirectory again. The cache format is unchanged.'
        }
    }
}
