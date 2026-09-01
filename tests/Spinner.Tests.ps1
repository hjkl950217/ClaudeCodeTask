# Invoke-WithSpinner / CctSpinner 测试
# 注意：spinner 的视觉效果（真终端动画）无法自动化测试；测试环境天然重定向，故只验函数契约：
#   结果透传、异常透传（finally 正常走）、带参数 scriptblock。

BeforeAll {
    . "$PSScriptRoot\..\cct\Spinner.ps1"
}

Describe 'Invoke-WithSpinner 契约（重定向下）' {
    It '结果原样透传（含管道）' {
        $r = Invoke-WithSpinner -Text 'test' -ScriptBlock { 42 }
        $r | Should -Be 42
    }
    It '管道输出透传' {
        $r = @(Invoke-WithSpinner -Text 'test' -ScriptBlock { 1; 2; 3 })
        $r | Should -Be @(1, 2, 3)
    }
    It 'ScriptBlock 抛异常时异常透传，finally 不吞异常' {
        { Invoke-WithSpinner -Text 'test' -ScriptBlock { throw 'boom' } } | Should -Throw 'boom'
    }
    It '带参数 scriptblock 正常工作（默认参数）' {
        $r = Invoke-WithSpinner -Text 'test' -ScriptBlock { param([int]$x = 5) $x * 2 }
        $r | Should -Be 10
    }
}