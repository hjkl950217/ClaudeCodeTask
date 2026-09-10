@{
    RootModule           = 'ClaudeCodeTask.psm1'
    ModuleVersion        = '0.3.2'
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
            ReleaseNotes = '0.3.2：模块对外介绍全面双语化——PowerShell Gallery 模块简介、README 与 GitHub 仓库简介均改为中英双语（中文在前、英文在后）；模块简介扩充为完整功能概述并补充搜索标签；README 每段中文下附英文说明，标题、列表项与代码注释中英分行。 | v0.3.2: all external docs are now bilingual — the PSGallery module description, README and GitHub repo description ship Chinese first, English second; the module description is expanded into a full feature overview with extra search tags; every README paragraph carries an English explanation below it, with titles, list items and code comments split into separate Chinese and English lines.'
        }
    }
}
