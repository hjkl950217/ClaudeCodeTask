BeforeAll {
    . "$PSScriptRoot\..\cct\Data.ps1"
    $script:tasks = @(
        [pscustomobject]@{ Kind='Folder'; Path='E:\个人\工具\管理_sub2api'; Name='管理_sub2api'; Subtitle='账号3244请求头覆写'; GroupKey='E:\个人\工具\管理_sub2api' }
        [pscustomobject]@{ Kind='Session'; Path='E:\个人\工具\管理_sub2api'; Name='账号调优'; GroupKey='E:\个人\工具\管理_sub2api' }
        [pscustomobject]@{ Kind='Folder'; Path='E:\个人\工作\写日志'; Name='写日志'; Subtitle='日志模板整理'; GroupKey='E:\个人\工作\写日志' }
    )
}

Describe 'Filter-CctTasks（决策 16：名+标题+全路径并集，子串，不区分大小写）' {
    It '空查询返回全部' {
        @(Filter-CctTasks $script:tasks '').Count | Should -Be 3
    }
    It '匹配文件夹名' {
        $r = @(Filter-CctTasks $script:tasks 'sub2api')
        $r.Count | Should -Be 2      # 文件夹 + 它的会话项
        $r[0].Kind | Should -Be 'Folder'
    }
    It '匹配会话标题（副标题也算）' {
        @(Filter-CctTasks $script:tasks '账号调优').Count | Should -Be 2   # 会话项 + 父文件夹上下文
    }
    It '匹配全路径（虽然不显示全路径）' {
        $r = @(Filter-CctTasks $script:tasks '工作')
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be '写日志'
    }
    It '不区分大小写' {
        @(Filter-CctTasks $script:tasks 'SUB2API').Count | Should -Be 2
    }
    It '中文子串' {
        @(Filter-CctTasks $script:tasks '日志').Count | Should -Be 1   # 命中写日志文件夹（Name 含「日志」，Subtitle 也含但同一项去重）
    }
    It '无命中返回空' {
        @(Filter-CctTasks $script:tasks 'zzzzz').Count | Should -Be 0
    }
}
