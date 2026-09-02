# 编译 ClaudeCodeTask.Core（net8.0，预编译 dll 入仓库）：
#   dotnet build → 拷贝产物到 lib/ClaudeCodeTask.Core.dll（PS 侧 Add-Type -Path 加载此路径）
# nuget restore 经本地代理 127.0.0.1:10193（环境变量仅本进程生效，不影响系统设置）
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$lib = Join-Path $root 'lib'

$env:HTTPS_PROXY = 'http://127.0.0.1:10193'
$env:HTTP_PROXY = 'http://127.0.0.1:10193'

dotnet build (Join-Path $root 'ClaudeCodeTask.Core.csproj') -c Release
if ($LASTEXITCODE -ne 0) { throw "dotnet build 失败 (exit $LASTEXITCODE)" }

New-Item -ItemType Directory -Force $lib | Out-Null
$src = Join-Path $root 'bin\Release\net8.0\ClaudeCodeTask.Core.dll'
Copy-Item $src (Join-Path $lib 'ClaudeCodeTask.Core.dll') -Force

Write-Host "OK -> $lib\ClaudeCodeTask.Core.dll"
