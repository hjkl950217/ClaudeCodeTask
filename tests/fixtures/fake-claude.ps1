# 测试夹具：模拟 claude 命令的降级链行为（Launcher 三级降级测试用）
# 通过环境变量 CCT_TEST_FAKE 控制退出码序列（逗号分隔，第 N 次调用取第 N 个 token）：
#   ok=退出0  fail=退出1  interrupt=退出130  stderrfail=stderr输出+退出1
# 无 CCT_TEST_FAKE 时按 -Mode 参数：ok/fail/interrupt/stderrfail
# 注意：调用命令里不要放 -xxx 形式的裸 token（PowerShell 参数绑定会吃掉），
#       命令拼接正确性由 Invoke-CctTask -DryRun 的 Command 字段断言覆盖
param(
    [string]$Mode = 'ok',
    [string]$Token = '',
    [Parameter(ValueFromRemainingArguments = $true)]$Rest
)
$dir = Join-Path $env:TEMP 'cct_fake'
New-Item -ItemType Directory -Force $dir | Out-Null
$n = 0
$countFile = Join-Path $dir 'count.txt'
$logFile = Join-Path $dir 'log.txt'
if (Test-Path $countFile) { $n = [int](Get-Content $countFile -Raw) }
$n++
Set-Content $countFile $n
Add-Content $logFile (@("-Mode:$Mode") + @($Token) + @($Rest | ForEach-Object { "$_" }) -join ' ')

if ($env:CCT_TEST_FAKE) {
    $seq = $env:CCT_TEST_FAKE -split ','
    $act = if ($n -le $seq.Count) { $seq[$n-1] } else { 'ok' }
    switch ($act) {
        'fail'       { exit 1 }
        'interrupt'  { exit 130 }
        'stderrfail' { [Console]::Error.WriteLine('模拟错误输出'); exit 1 }
        default      { exit 0 }
    }
}
switch ($Mode) {
    'interrupt'  { exit 130 }
    'stderrfail' { [Console]::Error.WriteLine('模拟错误输出'); exit 1 }
    'fail'       { exit 1 }
    default      { exit 0 }
}
