@{
    RootModule           = 'ClaudeCodeTask.psm1'
    ModuleVersion        = '0.3.1'
    CompatiblePSEditions = @('Core')
    GUID                 = '185bb7d7-e410-451b-8300-db7dfcb1a244'
    Author               = '长空X'
    CompanyName          = ''
    Copyright            = '(c) 长空X. All rights reserved.'
    Description          = 'Claude Code Task Selector —— 一条命令列出所有 Claude Code 任务文件夹与历史会话，全屏卡片网格选择器，选中自动 cd 并启动 claude。'
    PowerShellVersion    = '7.6'
    FunctionsToExport    = @('cct', 'Get-CctTasks', 'Show-CctSelector', 'Invoke-CctTask', 'Get-CctConfig', 'Get-CctSpinnerText', 'Invoke-WithSpinner')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('ClaudeCode', 'claude', 'task-selector', 'TUI', 'PSEdition_Core', 'Windows')
            LicenseUri   = 'https://github.com/hjkl950217/ClaudeCodeTask/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/hjkl950217/ClaudeCodeTask'
            ReleaseNotes = '0.3.1：续接分叉折叠与目录升格——claude -c/--resume 续接产生的同目录分叉会话不再重复出卡（对话链只留最新端点）；纯碎片目录升格最新有标题会话为会话卡（标题与进入后一致，精确 --resume）；扫描器内核升级至 CctScannerV5；缓存格式升级（旧缓存自动重建）；sync-to-installed.ps1 全面加固（热加载冲突检测、子进程烟测、备份中止保护等）。'
        }
    }
}
