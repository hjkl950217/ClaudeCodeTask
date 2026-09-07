# 编译 ClaudeCodeTask.Core（net8.0，预编译 dll 入仓库）：
#   dotnet build → 拷贝产物到 lib/ClaudeCodeTask.Core.dll（PS 侧 Add-Type -Path 加载此路径）
# nuget restore 代理读仓库根 build-metadata.json 的 buildProxy 字段（集中元数据，仅本进程生效）
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$lib = Join-Path $root 'lib'

$metaPath = Join-Path (Split-Path $root -Parent) 'build-metadata.json'
if (Test-Path -LiteralPath $metaPath) {
    try {
        $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
        if ($meta.buildProxy) {
            $env:HTTPS_PROXY = [string]$meta.buildProxy
            $env:HTTP_PROXY  = [string]$meta.buildProxy
        }
    } catch {
        Write-Host "build-metadata.json 读取失败（$($_.Exception.Message)），代理跳过" -ForegroundColor Yellow
    }
}

dotnet build (Join-Path $root 'ClaudeCodeTask.Core.csproj') -c Release
if ($LASTEXITCODE -ne 0) { throw "dotnet build 失败 (exit $LASTEXITCODE)" }

New-Item -ItemType Directory -Force $lib | Out-Null
$src = Join-Path $root 'bin\Release\net8.0\ClaudeCodeTask.Core.dll'
Copy-Item $src (Join-Path $lib 'ClaudeCodeTask.Core.dll') -Force

# 同步拷贝到 UI 模块 lib/：gallery 安装布局下 Add-Type 走 $PSScriptRoot\lib 内嵌加载
$uiLib = Join-Path (Split-Path $root -Parent) 'ClaudeCodeTask.UI\lib'
New-Item -ItemType Directory -Force $uiLib | Out-Null
Copy-Item $src (Join-Path $uiLib 'ClaudeCodeTask.Core.dll') -Force

Write-Host "OK -> $lib\ClaudeCodeTask.Core.dll"
Write-Host "OK -> $uiLib\ClaudeCodeTask.Core.dll"
