# 集中元数据读写与 psd1 盖章：版本号、仓库/许可证地址、发版说明、构建代理只编辑
# 仓库根的 build-metadata.json，盖章函数把其中版本相关字段派生进 ClaudeCodeTask.psd1。
# psd1 是 PowerShell 模块清单（Import-Module 按 RestrictedLanguage 解析，无法动态读
# 外部文件），所以采用「单一编辑点（元数据）+ 自动盖章（psd1）」模式——本文件提供：
#   Read-CctBuildMetadata   读元数据并校验必填字段/形态
#   Update-CctPsd1FromMetadata  把元数据盖章进 psd1（幂等：无变化不写）
# sync-to-installed.ps1 同步前、发布流程打 tag 前均可调用盖章，保证 psd1 不漂移。

function Read-CctBuildMetadata {
    param([string]$MetadataPath)
    if (-not (Test-Path -LiteralPath $MetadataPath)) {
        throw "找不到集中元数据文件：$MetadataPath"
    }
    try {
        $meta = Get-Content -LiteralPath $MetadataPath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        throw "集中元数据文件不是合法 JSON：$MetadataPath（$($_.Exception.Message)）"
    }
    foreach ($k in @('version', 'projectUri', 'licenseUri', 'releaseNotes', 'buildProxy')) {
        if ([string]::IsNullOrWhiteSpace([string]$meta.$k)) {
            throw "集中元数据缺必填字段：$k（$MetadataPath）"
        }
    }
    if ($meta.version -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') {
        throw "集中元数据 version 形态非法：'$($meta.version)'（应为 x.y.z 或 x.y.z.w）"
    }
    foreach ($k in @('projectUri', 'licenseUri')) {
        if ([string]$meta.$k -match "'") {
            throw "集中元数据 $k 含单引号，psd1 盖章无法安全转义（$MetadataPath）"
        }
    }
    return $meta
}

# 把元数据的版本相关字段盖章进 psd1。返回 [Changed, Version, Updated[]]。
# 按行正则替换（锚定字段名 + 单引号值），未涉字段与换行形态原样保留；无变化不写文件。
function Update-CctPsd1FromMetadata {
    param(
        [string]$MetadataPath,
        [string]$Psd1Path
    )
    $meta = Read-CctBuildMetadata -MetadataPath $MetadataPath
    if (-not (Test-Path -LiteralPath $Psd1Path)) {
        throw "找不到模块清单：$Psd1Path"
    }
    $text = [System.IO.File]::ReadAllText($Psd1Path, [System.Text.UTF8Encoding]::new($false))

    # 字段名 → 元数据值。锚定 psd1 实际字段名（ModuleVersion / ProjectUri / LicenseUri / ReleaseNotes）
    $stamps = [ordered]@{
        'ModuleVersion' = $meta.version
        'ProjectUri'    = $meta.projectUri
        'LicenseUri'    = $meta.licenseUri
        'ReleaseNotes'  = $meta.releaseNotes
    }
    $updated = [System.Collections.Generic.List[string]]::new()
    $newText = $text
    foreach ($field in $stamps.Keys) {
        $val = [string]$stamps[$field]
        # 跨行兜底：ReleaseNotes 等可能被手动折行，用 (?s) 允许旧值跨行
        $pattern = "(?s)(\b$field\b\s*=\s*')[^']*(')"
        if ($newText -notmatch $pattern) {
            throw "psd1 缺字段行：$field（$Psd1Path）"
        }
        if ($Matches[1] + $val + $Matches[2] -ne $Matches[0]) {
            $newText = [regex]::Replace($newText, $pattern, ('${1}' + $val.Replace('$', '$$') + '${2}'))
            [void]$updated.Add($field)
        }
    }
    if ($updated.Count -eq 0) {
        return [pscustomobject]@{ Changed = $false; Version = [string]$meta.version; Updated = @() }
    }
    [System.IO.File]::WriteAllText($Psd1Path, $newText, [System.Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ Changed = $true; Version = [string]$meta.version; Updated = @($updated) }
}
