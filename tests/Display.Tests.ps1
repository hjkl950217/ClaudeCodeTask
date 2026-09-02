BeforeAll {
    . "$PSScriptRoot\..\ClaudeCodeTask\Display.ps1"
}

Describe 'Get-DisplayWidth' {
    It 'ASCII 字符每个计 1' {
        Get-DisplayWidth 'abc' | Should -Be 3
    }
    It '中文每个计 2（显示宽度，非字节数）' {
        Get-DisplayWidth '中文' | Should -Be 4
    }
    It '全角符号计 2' {
        Get-DisplayWidth '（全角）' | Should -Be 8
    }
    It 'emoji 代理对计 2' {
        Get-DisplayWidth '😀' | Should -Be 2
    }
    It 'emoji + 肤色修饰符整体计 2（修饰符零宽）' {
        Get-DisplayWidth '👍🏽' | Should -Be 2
    }
    It '组合重音符号零宽' {
        # 显式构造 e + U+0301，避免编辑器把 é 规范化成单字符
        $s = "e$([char]0x301)"
        Get-DisplayWidth $s | Should -Be 1
    }
    It '零宽空格不计宽' {
        Get-DisplayWidth "a$([char]0x200B)b" | Should -Be 2
    }
    It '混合文本' {
        Get-DisplayWidth 'ab中😀' | Should -Be 6   # 1+1+2+2
    }
    It '空字符串为 0' {
        Get-DisplayWidth '' | Should -Be 0
    }
}

Describe 'Pad-DisplayRight' {
    It '窄文本右侧补空格到目标宽' {
        (Pad-DisplayRight '中文' 8) | Should -Be '中文    '
    }
    It '超宽文本不截断不补' {
        (Pad-DisplayRight '中文中文' 4) | Should -Be '中文中文'
    }
    It '窄文本左侧补空格到目标宽（右对齐用，第八轮 5）' {
        (Pad-DisplayLeft '59分钟前' 10) | Should -Be '  59分钟前'
    }
    It '超宽文本不截断不补（左填充版）' {
        (Pad-DisplayLeft '中文中文' 4) | Should -Be '中文中文'
    }
}

Describe 'Truncate-Display' {
    It '不超宽原样返回' {
        Truncate-Display '中文' 10 | Should -Be '中文'
    }
    It '超宽截断加省略号' {
        Truncate-Display '中文中文中文' 6 | Should -Be '中文…'
    }
    It '截断按显示宽度不按字符数' {
        # 5 个中文宽 10，限 7 → 保留 2 个中文 + …（宽 2+2+1 = 5？不对——预算 = 7-1 = 6，两个中文 4 后第三个会到 6 ≤ 6）
        # 逐 rune：中(2)累计2 → 文(2)累计4 → 中(2)累计6 ≤ 6 → 文(2)累计8 > 6 停 → '中文中…' 宽 7
        Truncate-Display '中文中文中文中文中文' 7 | Should -Be '中文中…'
    }
}

Describe 'Get-CctSessionLabel（第八轮 bug1：括号与目录名重复时去噪）' {
    It '标题与目录名归一化后相同 → 省略括号（CC汉化 / CC_汉化）' {
        Get-CctSessionLabel 'CC汉化' 'E:\t\CC_汉化' | Should -Be 'CC汉化'
    }
    It '标题与目录名不同 → 保留括号（账号调优 / 管理_sub2api）' {
        Get-CctSessionLabel '账号调优' 'E:\t\管理_sub2api' | Should -Be '账号调优（管理_sub2api）'
    }
    It '忽略大小写差异 → 省略括号（Claude Code / claude-code）' {
        Get-CctSessionLabel 'Claude Code' 'E:\t\claude-code' | Should -Be 'Claude Code'
    }
    It '拼音与汉字不同 → 保留括号（Claude Code 汉化 / claude-code-hanhua）' {
        Get-CctSessionLabel 'Claude Code 汉化' 'E:\t\claude-code-hanhua' | Should -Be 'Claude Code 汉化（claude-code-hanhua）'
    }
    It '仅空格差异 → 省略括号' {
        Get-CctSessionLabel '写 日 志' 'E:\t\写日志' | Should -Be '写 日 志'
    }
    It '路径无父目录（如根路径）→ 原样返回标题' {
        Get-CctSessionLabel 'foo' 'E:\' | Should -Be 'foo'
    }
}
