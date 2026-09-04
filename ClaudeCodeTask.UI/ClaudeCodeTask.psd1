@{
    RootModule           = 'ClaudeCodeTask.psm1'
    ModuleVersion        = '0.3.0'
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
            ReleaseNotes = '0.3.0：新增 cct clear 命令——无参清 cct 扫描缓存（cache.json）；cct clear -cc 清理多余 Claude Code 会话（每目录仅保留最新且行数 ≥ 阈值的一个，先打印过滤规则与待删清单、确认后删除）。'
        }
    }
}
