@{
    RootModule           = 'ClaudeCodeTask.psm1'
    ModuleVersion        = '0.3.3'
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
            ReleaseNotes = '0.3.3：修复 claude 以脚本形态安装（npm 的 .cmd/.ps1 或无扩展名）时 cct 启动失败的问题——此前直启脚本类命令报「%1 不是有效的 Win32 应用程序」。启动器现在按 claude 的实际安装形态自动选对启动方式：.cmd/.bat 经 cmd.exe 包装、.ps1 经 pwsh 执行、.exe 直接启动。 | v0.3.3: fixes cct failing to launch when claude is installed as a script (npm .cmd/.ps1 or an extensionless shim) — launching a script directly used to fail with "%1 is not a valid Win32 application". The launcher now detects the claude install shape and picks the right runner: .cmd/.bat via cmd.exe, .ps1 via pwsh, and .exe launched directly.'
        }
    }
}
