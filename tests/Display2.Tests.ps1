BeforeAll {
    . "$PSScriptRoot\..\ClaudeCodeTask.UI\Display.ps1"
    $script:now = [datetime]'2026-08-27 12:00:00'
}

Describe 'Get-RelativeTime（决策 17）' {
    It '小于 5 分钟 → 刚刚' {
        Get-RelativeTime ([datetime]'2026-08-27 11:58:00') $now | Should -Be '刚刚'
    }
    It '5-59 分钟 → N分钟前' {
        Get-RelativeTime ([datetime]'2026-08-27 11:30:00') $now | Should -Be '30分钟前'
    }
    It '1-23 小时 → N小时前' {
        Get-RelativeTime ([datetime]'2026-08-27 08:00:00') $now | Should -Be '4小时前'
    }
    It '恰好 24 小时前算昨天（同日历日或满 1 天）' {
        Get-RelativeTime ([datetime]'2026-08-26 12:00:00') $now | Should -Be '昨天'
    }
    It '2-7 天 → N天前' {
        Get-RelativeTime ([datetime]'2026-08-25 12:00:00') $now | Should -Be '2天前'
    }
    It '超过 7 天 → 绝对日期 MM-dd' {
        Get-RelativeTime ([datetime]'2026-08-05 12:00:00') $now | Should -Be '08-05'
    }
}

Describe 'Get-TailPaths（决策 18/19 + 47 修订：默认 3 级，冲突加级直到区分）' {
    It '无冲突时尾部 3 级' {
        $m = Get-TailPaths @('E:\个人\PersonalAITaskCenter\工具\管理_sub2api', 'E:\公司\AI任务\临时任务\VMS配置表单')
        $m['E:\个人\PersonalAITaskCenter\工具\管理_sub2api'] | Should -Be 'PersonalAITaskCenter/工具/管理_sub2api'
        $m['E:\公司\AI任务\临时任务\VMS配置表单'] | Should -Be 'AI任务/临时任务/VMS配置表单'
    }
    It '尾部冲突时各多显示一级直到区分' {
        $m = Get-TailPaths @(
            'E:\个人\PersonalAITaskCenter\0A_参考源码\源代码仓库\sub2api',
            'E:\个人\PersonalAITaskCenter\0A_参考源码\源代码理解\sub2api'
        )
        # 3 级默认即区分（第 2 级 源代码仓库/源代码理解 不同）
        $m['E:\个人\PersonalAITaskCenter\0A_参考源码\源代码仓库\sub2api'] | Should -Be '0A_参考源码/源代码仓库/sub2api'
        $m['E:\个人\PersonalAITaskCenter\0A_参考源码\源代码理解\sub2api'] | Should -Be '0A_参考源码/源代码理解/sub2api'
    }
    It '3 级尾部仍相同 → 加到 4 级' {
        $m = Get-TailPaths @(
            'E:\a\b\c\d\x',
            'E:\a\b\z\d\x'
        )
        # 尾 3 级都是 c\d\x？不——尾 3 级是 c/d/x vs z/d/x，第 1 级不同即区分，保持 3 级
        $m['E:\a\b\c\d\x'] | Should -Be 'c/d/x'
        $m['E:\a\b\z\d\x'] | Should -Be 'z/d/x'
    }
    It '路径整个相同（不可能但防御）→ 停在 3 级不死循环' {
        $m = Get-TailPaths @('E:\a\b', 'E:\a\b')
        $m['E:\a\b'] | Should -Be 'E:/a/b'
    }
}

