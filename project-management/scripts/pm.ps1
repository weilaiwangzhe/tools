param(
    [Parameter(Position = 0)]
    [ValidateSet('help','init-project','new-task','resume','status','record-attempt','detect-capture','capture','add-playbook','checkpoint','conversation-start','conversation-end','archive-conversation','graph','export-pdf','list-playbooks')]
    [string]$Command = 'help',
    [string]$Task,
    [string]$Title,
    [string]$ProjectPath,
    [string]$Conversation,
    [string]$MaxRootPath,
    [string]$Summary,
    [string]$OutputPath,
    [ValidateSet('failed','success','blocked','partial')]
    [string]$Result,
    [string]$Reason,
    [string]$Evidence,
    [string]$Next,
    [string]$Blocker = 'none',
    [ValidateSet('accept','reject','defer')]
    [string]$Decision,
    [ValidateSet('environment','debugging','build','deployment','research','data','automation','recovery','collaboration')]
    [string]$Category = 'collaboration',
    [string]$Type = 'workflow',
    [string[]]$Keywords,
    [switch]$Interactive,
    [switch]$ArchiveAll,
    [switch]$Commit
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$TargetRoot = $Root
if ($ProjectPath) { $TargetRoot = (Resolve-Path -LiteralPath $ProjectPath).Path }
$TaskDir = Join-Path $TargetRoot '.project/tasks'
$MaxRoot = $TargetRoot
if ($MaxRootPath) { $MaxRoot = (Resolve-Path -LiteralPath $MaxRootPath).Path }
else {
    $cursor = Get-Item -LiteralPath $TargetRoot
    while ($cursor) {
        if ($cursor.Name -ieq 'codex') { $MaxRoot = $cursor.FullName; break }
        $parent = $cursor.Parent
        if (-not $parent -or $parent.FullName -eq $cursor.FullName) { break }
        $cursor = $parent
    }
}

function Usage {
@'
通用项目管理 CLI

  new-task        创建任务文件
  init-project    在具体项目仓库初始化 .project 目录
  resume          只输出任务恢复摘要
  status          显示任务进度
  record-attempt  记录一次尝试
  detect-capture  检测经验候选，可加 -Interactive 询问
  capture         处理候选：-Decision accept|reject|defer
  add-playbook    创建方法卡草稿
  checkpoint      写入检查点，可加 -Commit 执行 Git 提交
  conversation-start  创建本次对话卡片，并读取上一级进度
  conversation-end    将对话卡片整理为项目经验卡
  archive-conversation  将经验卡归档到当前层或逐级归档
  graph           生成可点击的项目关系图谱 HTML
  export-pdf      生成图谱 HTML 并尝试导出 PDF
  list-playbooks  列出方法卡
'@
}

function TaskPath([string]$Id) {
    if (-not $Id) { throw '必须提供 -Task。' }
    $exact = Join-Path $TaskDir "$Id.md"
    if (Test-Path -LiteralPath $exact) { return $exact }
    $found = Get-ChildItem -LiteralPath $TaskDir -Filter "$Id-*.md" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    throw "找不到任务文件：$Id"
}

function Read-Task([string]$Id) { Get-Content -LiteralPath (TaskPath $Id) -Raw -Encoding UTF8 }
function Write-Task([string]$Id, [string]$Text) { Set-Content -LiteralPath (TaskPath $Id) -Value $Text -Encoding UTF8 }

function Meta([string]$Text) {
    $m = @{}
    if ($Text -notmatch '(?s)^---\r?\n(.*?)\r?\n---') { return $m }
    foreach ($line in ($Matches[1] -split "`r?`n")) {
        if ($line -match '^([A-Za-z0-9_]+):\s*(.*)$') { $m[$Matches[1]] = $Matches[2].Trim() }
        elseif ($line -match '^\s+status:\s*(.*)$') { $m.knowledge_status = $Matches[1].Trim() }
        elseif ($line -match '^\s+reason:\s*(.*)$') { $m.knowledge_reason = $Matches[1].Trim().Trim('"') }
    }
    return $m
}

function Set-TopValue([string]$Text, [string]$Key, [string]$Value) {
    $line = "$Key`: $Value"
    return [regex]::Replace($Text, "(?m)^$([regex]::Escape($Key)):\s*.*$", [System.Text.RegularExpressions.MatchEvaluator]{ param($x) $line }, 1)
}

function Set-Knowledge([string]$Text, [string]$Status, [string]$ReasonText = '') {
    $Text = [regex]::Replace($Text, '(?m)^(\s+status:)\s*(none|candidate|accepted|rejected|deferred)\s*$', "`$1 $Status", 1)
    if ($ReasonText) {
        $safe = $ReasonText.Replace('"','\"')
        $replacement = '$1 "' + $safe + '"'
        $Text = [regex]::Replace($Text, '(?m)^(\s+reason:)\s*.*$', $replacement, 1)
    }
    $today = Get-Date -Format 'yyyy-MM-dd'
    return Set-TopValue $Text 'updated' $today
}

function Progress([string]$Text) {
    $done = ([regex]::Matches($Text, '(?m)^\s*- \[[xX]\]')).Count
    $open = ([regex]::Matches($Text, '(?m)^\s*- \[ \]')).Count
    $total = $done + $open
    if ($total -eq 0 -and $Text -match '(?m)^\s+completed:\s*(\d+)') { $done = [int]$Matches[1] }
    if ($total -eq 0 -and $Text -match '(?m)^\s+total:\s*(\d+)') { $total = [int]$Matches[1] }
    if ($total -lt 1) { $total = 1 }
    [pscustomobject]@{ done = $done; total = $total; percent = [math]::Round(($done / $total) * 100) }
}

function Attempts([string]$Text) {
    $items = @()
    $section = $Text
    if ($Text -match '(?ms)^## 尝试记录\s*\r?\n(.*?)(?=^## |\z)') { $section = $Matches[1] }
    foreach ($line in ($section -split "`r?`n")) {
        if ($line -match '^\|\s*(ATT-\d+)\s*\|\s*([^|]+)\s*\|\s*(failed|success|blocked|partial)\s*\|\s*([^|]*)\|\s*([^|]*)\|') {
            $items += [pscustomobject]@{ id=$Matches[1]; date=$Matches[2].Trim(); result=$Matches[3]; summary=$Matches[4].Trim(); evidence=$Matches[5].Trim() }
        }
    }
    return $items
}

function Signals([string]$Text) {
    $a = @(Attempts $Text)
    $failures = @($a | Where-Object { $_.result -in @('failed','blocked') }).Count
    # Attempts are prepended to the task log, so index 0 is the newest entry.
    $successAfterFailure = $a.Count -gt 0 -and $a[0].result -eq 'success' -and $failures -gt 0
    $environment = $Text -match '(?i)environment|环境|依赖|版本|配置|工具链|sdk|jdk|gradle|docker|path'
    $special = $Text -match '(?i)workaround|绕过|特殊|非直觉|替代方案|换用|改成|最终'
    $reasons = @()
    if ($failures -ge 2) { $reasons += "检测到 $failures 次失败或阻塞尝试" }
    if ($successAfterFailure) { $reasons += '检测到失败后成功的解决路径' }
    if ($environment) { $reasons += '检测到环境、依赖、版本或配置排查' }
    if ($special) { $reasons += '检测到可能具有复用价值的特殊解决方案' }
    [pscustomobject]@{ candidate = (($failures -ge 2) -or $successAfterFailure -or $environment -or $special); attempts=$a.Count; reason=($reasons -join '；') }
}

function Slug([string]$Text) {
    $s = $Text.ToLowerInvariant() -replace '[^a-z0-9\u4e00-\u9fff]+','-'
    $s = $s.Trim('-')
    if (-not $s) { $s = 'method' }
    $s.Substring(0, [math]::Min(60, $s.Length))
}

function Register-Playbook([string]$Path, [string]$Title, [string]$CardType, [string[]]$CardKeywords) {
    $index = Join-Path $Root 'INDEX.md'
    if (-not (Test-Path -LiteralPath $index)) { return }
    $relative = (Resolve-Path -LiteralPath $Path).Path.Substring($Root.Length + 1).Replace('\','/')
    $link = "[$Title]($relative)"
    $current = Get-Content -LiteralPath $index -Raw -Encoding UTF8
    if ($current.Contains("($relative)")) { return }
    $keywordText = if ($CardKeywords) { $CardKeywords -join ', ' } else { '-' }
    $row = "| $link | $CardType | $keywordText | active |"
    $marker = '|---|---|---|---|'
    if ($current.Contains($marker)) {
        $updated = $current.Replace($marker, "$marker`r`n$row", 1)
        Set-Content -LiteralPath $index -Value $updated -Encoding UTF8
    } else { Add-Content -LiteralPath $index -Value $row -Encoding UTF8 }
}

function New-Task {
    if (-not $Task -or -not $Title) { throw 'new-task 需要 -Task 和 -Title。' }
    New-Item -ItemType Directory -Path $TaskDir -Force | Out-Null
    $path = Join-Path $TaskDir "$Task.md"
    if (Test-Path -LiteralPath $path) { throw "任务已存在：$Task" }
    $today = Get-Date -Format 'yyyy-MM-dd'
    $text = Get-Content -LiteralPath (Join-Path $Root 'templates/task.md') -Raw -Encoding UTF8
    $text = $text.Replace('PM-XXX',$Task).Replace('任务标题',$Title).Replace('YYYY-MM-DD',$today)
    Set-Content -LiteralPath $path -Value $text -Encoding UTF8
    Write-Output "已创建：$path"
}

function Init-Project {
    if (-not $ProjectPath) { throw 'init-project 需要 -ProjectPath。' }
    $pm = Join-Path $TargetRoot '.project'
    New-Item -ItemType Directory -Path (Join-Path $pm 'tasks') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $pm 'logs') -Force | Out-Null
    $status = Join-Path $pm 'STATUS.md'
    if (-not (Test-Path -LiteralPath $status)) {
        $name = if ($Title) { $Title } else { Split-Path $TargetRoot -Leaf }
        @"
# $name 状态

status: active
progress: 0/0
last_checkpoint: $(Get-Date -Format 'yyyy-MM-dd')
current_task: none
next_action: 创建第一个任务
blocker: none
"@ | Set-Content -LiteralPath $status -Encoding UTF8
    }
    $progressLog = Join-Path $pm 'logs/progress.md'
    if (-not (Test-Path -LiteralPath $progressLog)) { '# 进度时间线' | Set-Content -LiteralPath $progressLog -Encoding UTF8 }
    $ledger = Join-Path $pm 'logs/commit-ledger.ndjson'
    if (-not (Test-Path -LiteralPath $ledger)) { New-Item -ItemType File -Path $ledger | Out-Null }
    Write-Output "已初始化项目管理目录：$pm"
}

function Resume-Task {
    $path = TaskPath $Task
    $text = Read-Task $Task
    $m = Meta $text
    $p = Progress $text
    $s = Signals $text
    $nextAction = ''
    if ($text -match '(?ms)^## 下一步唯一动作[ \t]*\r?\n(.*?)(?=^## |\z)') {
        $candidateAction = $Matches[1].Trim()
        if ($candidateAction) { $nextAction = $candidateAction }
    }
    $linked = @()
    if ($text -match '(?ms)^## 关联资料[ \t]*\r?\n(.*?)(?=^## |\z)') {
        foreach ($line in ($Matches[1] -split "`r?`n")) {
            if ($line -match '^\s*-\s*\[[^\]]+\]\(([^)]+)\)') { $linked += $Matches[1] }
        }
    }
    $filled = [math]::Floor($p.percent / 10)
    [pscustomobject]@{
        task=$Task; file=$path; status=$m.status; progress="$($p.done)/$($p.total)";
        progress_bar=(('█' * $filled) + ('░' * (10-$filled)) + " $($p.percent)%");
        knowledge_capture=if ($m.knowledge_status) {$m.knowledge_status} else {'none'};
        attempts=$s.attempts; next_action=$nextAction; linked_files=$linked
    } | ConvertTo-Json -Depth 4
}

function Show-Status {
    if ($Task) { Resume-Task; return }
    Get-ChildItem -LiteralPath $TaskDir -Filter '*.md' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $text = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
        $m = Meta $text; $p = Progress $text
        '{0,-12} {1,-10} {2,3}%  {3}' -f $m.id,$m.status,$p.percent,$m.title
    }
}

function Record-Attempt {
    if (-not $Task -or -not $Result -or -not $Reason) { throw 'record-attempt 需要 -Task、-Result 和 -Reason。' }
    $text = Read-Task $Task
    $number = @(Attempts $text).Count + 1
    $id = 'ATT-{0:D3}' -f $number
    $row = "| $id | $(Get-Date -Format 'yyyy-MM-dd') | $Result | $Reason | $(if($Evidence){$Evidence}else{'待补充'}) |"
    $pattern = '(?ms)(^## 尝试记录\s*\r?\n.*?^\|---\|---\|---\|---\|---\|\s*\r?\n)'
    if ($text -notmatch $pattern) { throw '任务文件缺少尝试记录表格。' }
    $text = [regex]::Replace($text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Value + $row + "`r`n" }, 1)
    if ((Signals $text).candidate) { $text = Set-Knowledge $text 'candidate' (Signals $text).reason }
    Write-Task $Task $text
    Write-Output "已记录 $id；经验状态：$((Meta $text).knowledge_status)"
}

function Detect-Capture {
    $text = Read-Task $Task
    $m = Meta $text; $s = Signals $text
    if (-not $s.candidate) { [pscustomobject]@{task=$Task;candidate=$false;attempts=$s.attempts;reason='目前没有达到候选阈值'} | ConvertTo-Json; return }
    if ($m.knowledge_status -eq 'rejected') { [pscustomobject]@{task=$Task;candidate=$true;suppressed=$true;reason='当前候选已被拒绝，等待新的成功路径'} | ConvertTo-Json; return }
    Write-Task $Task (Set-Knowledge $text 'candidate' $s.reason)
    [pscustomobject]@{task=$Task;candidate=$true;attempts=$s.attempts;reason=$s.reason;prompt='这次过程中出现了多次尝试，并最终形成了一条可复用的解决路径。是否将它整理为方法卡？'} | ConvertTo-Json
    if ($Interactive) {
        Write-Host '1. 记录为通用方法  2. 只保留在当前任务  3. 稍后再决定'
        switch (Read-Host '请选择 1/2/3') {
            '1' { & $PSCommandPath capture -Task $Task -Decision accept -Category $Category -Type $Type -Keywords $Keywords }
            '2' { & $PSCommandPath capture -Task $Task -Decision reject }
            '3' { & $PSCommandPath capture -Task $Task -Decision defer }
            default { Write-Warning '未识别选择，保留 candidate 状态。' }
        }
    }
}

function Capture-Decision {
    if (-not $Task -or $Decision -notin @('accept','reject','defer')) { throw 'capture 需要 -Task 和 -Decision accept|reject|defer。' }
    $text = Read-Task $Task
    if ($Decision -eq 'reject') { Write-Task $Task (Set-Knowledge $text 'rejected'); Write-Output '已保留在当前任务日志。'; return }
    if ($Decision -eq 'defer') { Write-Task $Task (Set-Knowledge $text 'deferred'); Write-Output '已延后处理。'; return }
    $m = Meta $text
    $cardTitle = if ($m.proposed_title) { $m.proposed_title } else { "来自 $Task 的可复用方法" }
    $existing = Get-ChildItem -LiteralPath (Join-Path $Root 'playbooks') -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
        (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match "(?m)^source_task:\s*$([regex]::Escape($Task))\s*$"
    } | Select-Object -First 1
    if ($existing) {
        Write-Task $Task (Set-Knowledge $text 'accepted')
        Write-Output "该任务已存在方法卡：$($existing.FullName)"
        return
    }
    if (-not $Keywords) { $Keywords = @('reusable',$Category) }
    $dir = Join-Path $Root "playbooks/$Category"; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir "$(Slug $cardTitle).md"
    if (Test-Path -LiteralPath $path) { $path = Join-Path $dir "$(Slug $cardTitle)-$Task.md" }
    $card = Get-Content -LiteralPath (Join-Path $Root 'templates/playbook.md') -Raw -Encoding UTF8
    $yaml = (($Keywords | ForEach-Object { "  - $_" }) -join "`r`n")
    $card = $card.Replace('方法卡标题',$cardTitle).Replace('workflow',$Type).Replace('  - keyword',$yaml).Replace('PM-XXX',$Task).Replace('YYYY-MM-DD',(Get-Date -Format 'yyyy-MM-dd'))
    $sourceProject = $TargetRoot.Replace('\','/')
    $card = $card.Replace("source_task: $Task", "source_task: $Task`r`nsource_project: $sourceProject")
    $rows = @(Attempts $text) | ForEach-Object { "| $($_.id) | $($_.result) | $($_.summary) | $($_.evidence) |" }
    if ($rows.Count -gt 0) { $card = $card.Replace('|---|---|---|---|',"|---|---|---|---|`r`n$($rows -join "`r`n")",1) }
    Set-Content -LiteralPath $path -Value $card -Encoding UTF8
    Register-Playbook $path $cardTitle $Type $Keywords
    $updated = Set-Knowledge $text 'accepted'
    $relative = (Resolve-Path -LiteralPath $path).Path.Substring($Root.Length + 1).Replace('\','/')
    $link = "- [方法卡](../../$relative)"
    if ($updated -match '(?ms)^## 关联资料\s*\r?\n') {
        $updated = [regex]::Replace($updated, '(?ms)(^## 关联资料\s*\r?\n)', "`$1`r`n$link`r`n", 1)
    } else { $updated += "`r`n`r`n## 关联资料`r`n`r`n$link`r`n" }
    Write-Task $Task $updated
    Write-Output "已创建方法卡：$path"
}

function Add-Playbook {
    if (-not $Title) { throw 'add-playbook 需要 -Title。' }
    $dir = Join-Path $Root "playbooks/$Category"; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir "$(Slug $Title).md"
    if (Test-Path -LiteralPath $path) { throw "方法卡已存在：$path" }
    $card = Get-Content -LiteralPath (Join-Path $Root 'templates/playbook.md') -Raw -Encoding UTF8
    $yaml = if ($Keywords) { (($Keywords | ForEach-Object { "  - $_" }) -join "`r`n") } else { '  - reusable' }
    $card = $card.Replace('方法卡标题',$Title).Replace('workflow',$Type).Replace('  - keyword',$yaml).Replace('YYYY-MM-DD',(Get-Date -Format 'yyyy-MM-dd'))
    Set-Content -LiteralPath $path -Value $card -Encoding UTF8
    Register-Playbook $path $Title $Type $Keywords
    Write-Output "已创建方法卡草稿：$path"
}

function Checkpoint {
    if (-not $Task) { throw 'checkpoint 需要 -Task。' }
    $text = Read-Task $Task; $p = Progress $text; $now = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $summary = if ($Reason) {$Reason} else {'检查点更新'}
    $nextAction = if ($Next) {$Next} else {'继续任务文件中的下一步唯一动作'}
    $capture = (Meta $text).knowledge_status
    $row = "| $now | $($p.done)/$($p.total) | $summary | $nextAction | $Blocker | $capture |"
    $pattern = '(?ms)(^## 检查点\s*\r?\n.*?^\|---\|---\|---\|---\|---\|\s*\r?\n)'
    $text = [regex]::Replace($text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Value + $row + "`r`n" }, 1)
    Write-Task $Task $text
    Add-Content -LiteralPath (Join-Path $TargetRoot '.project/logs/progress.md') -Value "| $now | $Task | $($p.done)/$($p.total) | $summary | $nextAction |" -Encoding UTF8
    if ($Commit) {
        git -C $TargetRoot add -A
        git -C $TargetRoot commit -m "chore(pm): checkpoint $Task"
        $hash = (git -C $TargetRoot rev-parse HEAD).Trim()
        $entry = [pscustomobject]@{hash=$hash;date=$now;task=$Task;progress="$($p.done)/$($p.total)";summary=$summary;next=$nextAction;blocker=$Blocker;knowledge_capture=$capture} | ConvertTo-Json -Compress
        Add-Content -LiteralPath (Join-Path $TargetRoot '.project/logs/commit-ledger.ndjson') -Value $entry -Encoding UTF8
        Write-Output "已提交 $hash；账本记录将在下一次提交中固化。"
    } else { Write-Output "已写入检查点：$Task" }
}

function Archive-Path([string]$Directory, [string]$Name) {
    $pm = Join-Path $Directory '.project'
    if (Test-Path -LiteralPath $pm) { return (Join-Path $pm $Name) }
    return (Join-Path $Directory $Name)
}

function Parent-Directory([string]$Directory) {
    $item = Get-Item -LiteralPath $Directory
    if ($item.Parent) { return $item.Parent.FullName }
    return $null
}

function Conversation-Path([string]$Value) {
    if ($Value -and (Test-Path -LiteralPath $Value)) { return (Resolve-Path -LiteralPath $Value).Path }
    $dir = Join-Path $TargetRoot '.project/conversations'
    if ($Value) {
        $match = Get-ChildItem -LiteralPath $dir -Filter "*$Value*" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($match) { return $match.FullName }
    }
    $latest = Get-ChildItem -LiteralPath $dir -Filter '*-对话卡片.md' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { return $latest.FullName }
    throw '找不到对话卡片。'
}

function Parent-Snapshot([string]$Directory) {
    $progress = Archive-Path $Directory '项目进度.md'
    $status = Join-Path $Directory '.project/STATUS.md'
    $experience = Archive-Path $Directory '项目经验.md'
    $path = if (Test-Path -LiteralPath $progress) { $progress } elseif (Test-Path -LiteralPath $status) { $status } elseif (Test-Path -LiteralPath $experience) { $experience } else { $null }
    if (-not $path) { return '上一级目录暂无项目状态文件。' }
    $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ($content.Length -gt 2400) { $content = $content.Substring(0,2400) + "`r`n..." }
    return "来源：$path`r`n`r`n$content"
}

function Conversation-Start {
    $dir = Join-Path $TargetRoot '.project/conversations'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $id = 'CONV-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $conversationTitle = if ($Title) { $Title } else { '未命名对话' }
    $parent = Parent-Directory $TargetRoot
    $template = Get-Content -LiteralPath (Join-Path $Root 'templates/conversation-card.md') -Raw -Encoding UTF8
    $card = $template.Replace('CONV-YYYYMMDD-HHMMSS',$id).Replace('对话标题',$conversationTitle).Replace('PROJECT_ROOT',$TargetRoot.Replace('\','/')).Replace('PARENT_ROOT',$(if($parent){$parent.Replace('\','/')}else{$TargetRoot.Replace('\','/')})).Replace('MAX_ROOT',$MaxRoot.Replace('\','/')).Replace('YYYY-MM-DD HH:mm:ss',(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $snapshot = if ($parent) { Parent-Snapshot $parent } else { '没有上一级目录。' }
    $card = $card.Replace('开始对话时读取的上一级目录状态：', "开始对话时读取的上一级目录状态：`r`n`r`n$snapshot")
    $path = Join-Path $dir "$id-对话卡片.md"
    Set-Content -LiteralPath $path -Value $card -Encoding UTF8
    [pscustomobject]@{conversation_id=$id; card=$path; project_root=$TargetRoot; parent_root=$parent; max_root=$MaxRoot} | ConvertTo-Json
}

function Conversation-End {
    $path = Conversation-Path $Conversation
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $summaryText = if ($Summary) { $Summary } elseif ($Reason) { $Reason } else { '本次对话完成了阶段性工作，详情见对话卡片。' }
    $nextText = if ($Next) { $Next } else { '根据项目状态文件继续下一步。' }
    $text = [regex]::Replace($text, '(?m)^ended:\s*.*$', "ended: $now", 1)
    $text = [regex]::Replace($text, '(?m)^status:\s*active\s*$', 'status: completed', 1)
    $text = [regex]::Replace($text, '(?ms)^## 本次完成内容\s*\r?\n.*?(?=^## )', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) "## 本次完成内容`r`n`r`n$summaryText`r`n`r`n" }, 1)
    $text = [regex]::Replace($text, '(?ms)^## 下一步唯一动作\s*\r?\n.*?(?=^## )', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) "## 下一步唯一动作`r`n`r`n$nextText`r`n`r`n" }, 1)
    Set-Content -LiteralPath $path -Value $text -Encoding UTF8
    $experiencePath = $path.Replace('-对话卡片.md','-项目经验.md')
    $experience = $text.Replace('# 对话卡片：','# 项目经验：')
    $experience = $experience.Replace('archive_status: pending','archive_status: ready')
    Set-Content -LiteralPath $experiencePath -Value $experience -Encoding UTF8
    [pscustomobject]@{conversation_card=$path; experience_card=$experiencePath; archive_status='ready'; prompt='本次对话已经生成项目经验卡。是否归档到上一级目录的项目进度和项目经验中？'} | ConvertTo-Json
}

function Append-Archive([string]$Directory, [string]$ExperiencePath, [string]$ExperienceText) {
    $experienceFile = Archive-Path $Directory '项目经验.md'
    $progressFile = Archive-Path $Directory '项目进度.md'
    New-Item -ItemType Directory -Path (Split-Path $experienceFile -Parent) -Force | Out-Null
    $id = if ($ExperienceText -match '(?m)^conversation_id:\s*(.+)$') { $Matches[1].Trim() } else { Split-Path $ExperiencePath -Leaf }
    if ((Test-Path -LiteralPath $experienceFile) -and (Get-Content -LiteralPath $experienceFile -Raw -Encoding UTF8).Contains($id)) { return $false }
    $title = if ($ExperienceText -match '(?m)^title:\s*(.+)$') { $Matches[1].Trim() } else { $id }
    $summary = if ($ExperienceText -match '(?ms)^## 本次完成内容\s*\r?\n(.*?)(?=^## |\z)') { $Matches[1].Trim() } else { '详见来源经验卡。' }
    $nextText = if ($ExperienceText -match '(?ms)^## 下一步唯一动作\s*\r?\n(.*?)(?=^## |\z)') { $Matches[1].Trim() } else { '待确定' }
    $relative = $ExperiencePath.Replace($Directory,'').TrimStart('\','/').Replace('\','/')
    $entry = "`r`n## $title`r`n`r`n- 对话：$id`r`n- 来源：$relative`r`n- 完成：$summary`r`n- 下一步：$nextText`r`n"
    if (Test-Path -LiteralPath $experienceFile) { Add-Content -LiteralPath $experienceFile -Value $entry -Encoding UTF8 } else { Set-Content -LiteralPath $experienceFile -Value ("# 项目经验`r`n$entry") -Encoding UTF8 }
    $progressEntry = "`r`n- $(Get-Date -Format 'yyyy-MM-dd') [$title]：$summary；下一步：$nextText"
    if (Test-Path -LiteralPath $progressFile) { Add-Content -LiteralPath $progressFile -Value $progressEntry -Encoding UTF8 } else { Set-Content -LiteralPath $progressFile -Value ("# 项目进度`r`n$progressEntry") -Encoding UTF8 }
    return $true
}

function Archive-Conversation {
    $path = Conversation-Path $Conversation
    if ($path -notmatch '-项目经验\.md$') { $path = $path.Replace('-对话卡片.md','-项目经验.md') }
    if (-not (Test-Path -LiteralPath $path)) { throw "找不到项目经验卡：$path" }
    $experience = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $level = $TargetRoot
    $archived = @()
    do {
        if (Append-Archive $level $path $experience) { $archived += $level }
        if (-not $ArchiveAll) { break }
        if ($level -eq $MaxRoot) { break }
        $nextLevel = Parent-Directory $level
        if (-not $nextLevel) { break }
        $level = $nextLevel
    } while ($true)
    $nextParent = if ($level -ne $MaxRoot) { Parent-Directory $level } else { $null }
    [pscustomobject]@{experience_card=$path; archived_to=$archived; next_parent=$nextParent} | ConvertTo-Json -Depth 4
}

function Xml-Escape([string]$Value) {
    if ($null -eq $Value) { return '' }
    return $Value.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function Graph-Data([string]$ScanRoot = $MaxRoot) {
    $ScanRoot = (Resolve-Path -LiteralPath $ScanRoot).Path.TrimEnd('\')
    $excludedNames = @('.git','node_modules','bin','obj','.vs','.idea','.gradle','build','dist','target','vendor','packages','tmp','temp')
    $allDirs = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $depths = @{}
    $maximumScanDepth = 5
    $depths[$ScanRoot.ToLowerInvariant()] = 0
    $stack.Push($ScanRoot)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        $allDirs.Add($current)
        if ($depths[$current.ToLowerInvariant()] -ge $maximumScanDepth) { continue }
        foreach ($child in @(Get-ChildItem -LiteralPath $current -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($excludedNames -contains $child.Name -or ($child.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            $depths[$child.FullName.ToLowerInvariant()] = $depths[$current.ToLowerInvariant()] + 1
            $stack.Push($child.FullName)
        }
    }

    $folderPaths = @($ScanRoot)
    foreach ($directory in $allDirs) {
        if ($directory -eq $ScanRoot) { continue }
        $parent = Split-Path $directory -Parent
        $isDirectChild = $parent.TrimEnd('\') -ieq $ScanRoot
        $hasProjectData = (Test-Path -LiteralPath (Join-Path $directory '.project')) -or
            (Test-Path -LiteralPath (Join-Path $directory '项目进度.md')) -or
            (Test-Path -LiteralPath (Join-Path $directory '项目经验.md'))
        if ($isDirectChild -or $hasProjectData) { $folderPaths += $directory }
    }
    $folderPaths = @($folderPaths | Sort-Object Length)
    $nodes = New-Object System.Collections.Generic.List[object]
    $folderIds = @{}
    $sourceIds = @{}
    $counter = 0
    foreach ($directory in $folderPaths) {
        $id = "n$counter"; $counter++
        $title = if ($directory -ieq $ScanRoot) { Split-Path $ScanRoot -Leaf } else { Split-Path $directory -Leaf }
        $relative = if ($directory -ieq $ScanRoot) { '.' } else { $directory.Substring($ScanRoot.Length).TrimStart('\').Replace('\','/') }
        $candidates = @(
            (Join-Path $directory '项目经验.md'),
            (Join-Path $directory '.project/项目经验.md'),
            (Join-Path $directory '项目进度.md'),
            (Join-Path $directory '.project/项目进度.md'),
            (Join-Path $directory '.project/STATUS.md'),
            (Join-Path $directory 'INDEX.md')
        )
        $source = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        $content = if ($source) { Get-Content -LiteralPath $source -Raw -Encoding UTF8 } else { "文件夹：$directory`r`n`r`n此文件夹还没有项目进度或项目经验 Markdown。" }
        $nodes.Add([pscustomobject]@{id=$id; path=$directory; source=$source; relative=$relative; title=$title; kind='folder'; content=$content; parent=$null; level=0; x=0; y=0})
        $folderIds[$directory.ToLowerInvariant()] = $id
        if ($source) { $sourceIds[[System.IO.Path]::GetFullPath($source).ToLowerInvariant()] = $id }
    }

    foreach ($directory in $folderPaths) {
        $conversationDir = Join-Path $directory '.project/conversations'
        if (-not (Test-Path -LiteralPath $conversationDir -PathType Container)) { continue }
        foreach ($card in @(Get-ChildItem -LiteralPath $conversationDir -Filter '*-对话卡片.md' -File -ErrorAction SilentlyContinue)) {
            $experiencePath = $card.FullName.Replace('-对话卡片.md','-项目经验.md')
            $source = if (Test-Path -LiteralPath $experiencePath -PathType Leaf) { $experiencePath } else { $card.FullName }
            $experienceText = Get-Content -LiteralPath $source -Raw -Encoding UTF8
            $cardText = if ($source -ne $card.FullName) { Get-Content -LiteralPath $card.FullName -Raw -Encoding UTF8 } else { $experienceText }
            $title = if ($cardText -match '(?m)^title:\s*(.+)$') { $Matches[1].Trim().Trim('"') } else { $card.BaseName }
            $id = "n$counter"; $counter++
            $relative = $source.Substring($ScanRoot.Length).TrimStart('\').Replace('\','/')
            $nodes.Add([pscustomobject]@{id=$id; path=$card.Directory.Parent.Parent.FullName; source=$source; relative=$relative; title=$title; kind='conversation'; content=$experienceText; parent=$folderIds[$directory.ToLowerInvariant()]; level=0; x=0; y=0})
            $sourceIds[[System.IO.Path]::GetFullPath($source).ToLowerInvariant()] = $id
        }
    }

    $edges = New-Object System.Collections.Generic.List[object]
    foreach ($node in $nodes) {
        if ($node.kind -eq 'folder' -and $node.path -ine $ScanRoot) {
            $parentPath = Split-Path $node.path -Parent
            while ($parentPath -and -not $folderIds.ContainsKey($parentPath.ToLowerInvariant())) { $parentPath = Split-Path $parentPath -Parent }
            if ($parentPath -and $folderIds.ContainsKey($parentPath.ToLowerInvariant())) { $node.parent = $folderIds[$parentPath.ToLowerInvariant()] }
        }
        if ($node.parent) { $edges.Add([pscustomobject]@{from=$node.parent;to=$node.id;type='contains'}) }
    }
    foreach ($node in $nodes) {
        if (-not $node.source) { continue }
        foreach ($match in [regex]::Matches($node.content, '\[[^\]]+\]\(([^)#]+)\)')) {
            $link = $match.Groups[1].Value
            if ($link -match '^(https?:|mailto:|#)') { continue }
            try {
                $target = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $node.source -Parent) $link)).ToLowerInvariant()
                $targetId = $sourceIds[$target]
                if ($targetId -and $targetId -ne $node.id -and -not ($edges | Where-Object { $_.from -eq $node.id -and $_.to -eq $targetId })) {
                    $edges.Add([pscustomobject]@{from=$node.id;to=$targetId;type='link'})
                }
            } catch { }
        }
    }
    return [pscustomobject]@{nodes=$nodes.ToArray(); edges=$edges.ToArray(); root=$ScanRoot}
}

function Graph-Generate {
    $data = Graph-Data
    $requestedOutput = if ($OutputPath) { if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $TargetRoot $OutputPath } } else { $null }
    $dir = if ($requestedOutput) { Split-Path -Parent $requestedOutput } else { Join-Path $TargetRoot '.project/exports' }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $htmlPath = if ($requestedOutput -and $requestedOutput.ToLowerInvariant().EndsWith('.html')) { $requestedOutput } else { Join-Path $dir '项目图谱.html' }
    $json = ($data | ConvertTo-Json -Depth 8 -Compress).Replace('</','<\\/')
    $maxX = [math]::Max(900, (($data.nodes | Measure-Object -Property x -Maximum).Maximum + 330))
    $maxY = [math]::Max(650, (($data.nodes | Measure-Object -Property y -Maximum).Maximum + 140))
    $lines = @(); $nodeMap = @{}
    foreach ($node in $data.nodes) { $nodeMap[$node.id] = $node }
    foreach ($edge in $data.edges) {
        $from = $nodeMap[$edge.from]; $to = $nodeMap[$edge.to]
        $class = if ($edge.type -eq 'link') { 'link-edge' } else { 'tree-edge' }
        $lines += "<line class='$class' x1='$($from.x + 220)' y1='$($from.y + 24)' x2='$($to.x)' y2='$($to.y + 24)' />"
    }
    $nodeSvg = @()
    foreach ($node in $data.nodes) {
        $fill = if ($node.kind -eq 'project') { '#2563eb' } else { '#475569' }
        $label = Xml-Escape $node.title
        $nodeSvg += "<g class='node' onclick=`"showNode('$($node.id)')`"><rect x='$($node.x)' y='$($node.y)' width='220' height='48' rx='8' fill='$fill' /><text x='$($node.x + 12)' y='$($node.y + 21)'>$label</text><text class='kind' x='$($node.x + 12)' y='$($node.y + 38)'>$($node.kind)</text></g>"
    }
    $html = @"
<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>项目图谱</title>
<style>
body{margin:0;font-family:Segoe UI,Microsoft YaHei,sans-serif;color:#172033;background:#f8fafc;display:flex;height:100vh;overflow:hidden}
#map{flex:1;overflow:auto;padding:20px}#detail{width:360px;background:#fff;border-left:1px solid #dbe3ef;padding:22px;overflow:auto}
svg{background:#fff;border:1px solid #dbe3ef;border-radius:12px;min-width:${maxX}px;min-height:${maxY}px}.node{cursor:pointer}.node text{fill:#fff;font-size:14px}.node .kind{font-size:11px;opacity:.75}.tree-edge{stroke:#94a3b8;stroke-width:2}.link-edge{stroke:#f59e0b;stroke-width:1.5;stroke-dasharray:6 5}
pre{white-space:pre-wrap;word-break:break-word;background:#f1f5f9;padding:12px;border-radius:8px;font-size:12px}a{color:#2563eb}h1{font-size:22px}h2{font-size:18px}
@media print{@page{size:landscape;margin:.25in}body{display:block}#detail{display:none}#map{overflow:visible;padding:0;width:100vw;height:100vh}#map h1,#map p{display:none}svg{border:0;width:100%;height:100%;min-width:0;min-height:0;max-width:none;display:block}}
</style></head><body><main id="map"><h1>项目关系图谱</h1><p>蓝色为项目，灰色为 Markdown，橙色虚线为文档链接。点击节点查看内容。</p><svg viewBox="0 0 ${maxX} ${maxY}">$($lines -join '')$($nodeSvg -join '')</svg></main><aside id="detail"><h2>选择一个节点</h2><p>点击图中的项目、任务、对话卡片或方法卡。</p></aside>
<script>const graph=$json;const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));function showNode(id){const n=graph.nodes.find(x=>x.id===id);if(!n)return;document.getElementById('detail').innerHTML='<h2>'+esc(n.title)+'</h2><p>'+esc(n.relative)+'</p><pre>'+esc(n.content)+'</pre>';}</script>
</body></html>
"@
    Set-Content -LiteralPath $htmlPath -Value $html -Encoding UTF8
    return $htmlPath
}

function Graph-Generate-Network {
    $data = Graph-Data
    $nodeIndex = 0
    foreach ($node in $data.nodes) {
        $angle = $nodeIndex * 2.399963
        $node.x = 450 + [math]::Cos($angle) * (145 + ($nodeIndex % 4) * 58)
        $node.y = 350 + [math]::Sin($angle) * (105 + ($nodeIndex % 5) * 38)
        $degree = @($data.edges | Where-Object { $_.from -eq $node.id -or $_.to -eq $node.id }).Count
        $node | Add-Member -NotePropertyName r -NotePropertyValue ([math]::Min(25,10 + $degree * 2)) -Force
        $nodeIndex++
    }
    $requestedOutput = if ($OutputPath) { if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $TargetRoot $OutputPath } } else { $null }
    $dir = if ($requestedOutput) { Split-Path -Parent $requestedOutput } else { Join-Path $TargetRoot '.project/exports' }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $htmlPath = if ($requestedOutput -and $requestedOutput.ToLowerInvariant().EndsWith('.html')) { $requestedOutput } else { Join-Path $dir '项目图谱.html' }
    $htmlDir = (Resolve-Path -LiteralPath $dir).Path
    $graphNodes = @($data.nodes | ForEach-Object {
        $filePath = if ($_.source -and (Test-Path -LiteralPath $_.source)) { [System.IO.Path]::GetFullPath($_.source) } else { '' }
        [pscustomobject]@{id=$_.id; title=$_.title; kind=$_.kind; relative=$_.relative; content=$_.content; filePath=$filePath; x=$_.x; y=$_.y; r=$_.r}
    })
    $graphJson = [pscustomobject]@{nodes=$graphNodes; edges=$data.edges}
    $json = ($graphJson | ConvertTo-Json -Depth 8 -Compress).Replace('</','<\/')
    $nodeMap = @{}
    foreach ($node in $data.nodes) { $nodeMap[$node.id] = $node }
    $staticEdges = @()
    foreach ($edge in $data.edges) {
        $from = $nodeMap[$edge.from]; $to = $nodeMap[$edge.to]
        $edgeClass = if ($edge.type -eq 'link') { 'edge link' } else { 'edge' }
        $staticEdges += "<line class='$edgeClass' x1='$($from.x)' y1='$($from.y)' x2='$($to.x)' y2='$($to.y)' />"
    }
    $staticNodes = @()
    foreach ($node in $data.nodes) {
        $label = Xml-Escape $node.title
        $color = if ($node.kind -eq 'folder') { '#c084fc' } else { '#a3a3a3' }
        $staticNodes += "<g class='node' data-id='$($node.id)' onclick=`"showNode('$($node.id)')`"><circle cx='$($node.x)' cy='$($node.y)' r='$($node.r)' fill='$color' /><text x='$($node.x)' y='$($node.y + $node.r + 17)'>$label</text></g>"
    }
    $html = @"
<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>项目网络图</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#171717;color:#d4d4d4;font-family:Segoe UI,Microsoft YaHei,sans-serif;display:flex;width:100vw;height:100vh;overflow:hidden}.toolbar{position:fixed;z-index:5;top:16px;left:18px;display:flex;gap:8px;align-items:center}.toolbar button,.toolbar input{background:#262626;color:#ddd;border:1px solid #404040;border-radius:6px;padding:8px 10px}.toolbar input{width:min(220px,34vw)}.stage{flex:1;min-width:0;min-height:0;position:relative;overflow:hidden}svg{display:block;width:100%;height:100%;cursor:grab;background:#171717}.stage.dragging svg{cursor:grabbing}.edge{stroke:#4b5563;stroke-width:1.2;opacity:.72;vector-effect:non-scaling-stroke}.edge.link{stroke:#a855f7;stroke-dasharray:5 5;opacity:.9}.node{cursor:pointer}.node circle{stroke:#171717;stroke-width:3;vector-effect:non-scaling-stroke}.node text{fill:#e5e5e5;font-size:13px;text-anchor:middle;pointer-events:none;paint-order:stroke;stroke:#171717;stroke-width:3px;stroke-linejoin:round}.node.dim{opacity:.12}.node.selected circle{stroke:#fff;stroke-width:3}.legend{position:fixed;z-index:2;bottom:18px;left:18px;color:#a3a3a3;font-size:12px;pointer-events:none}.detail{flex:0 0 420px;min-width:280px;max-width:42vw;background:#202020;border-left:1px solid #383838;padding:20px;overflow:auto}.detail h2{margin-top:0;color:#f5f5f5}.detail p{color:#a3a3a3;font-size:12px}.detail button{background:#7e22ce;color:#fff;border:0;border-radius:5px;padding:8px 12px;cursor:pointer}.detail code{display:block;word-break:break-all;color:#a3a3a3;font-size:11px;margin-top:8px}.detail pre{white-space:pre-wrap;word-break:break-word;background:#111;padding:14px;border-radius:8px;font-size:12px;line-height:1.5}.hint{color:#737373;font-size:13px;line-height:1.6}
@media(max-width:760px){.detail{flex-basis:300px;padding:14px}.toolbar{left:10px;top:10px}.toolbar input{width:30vw}.legend{left:10px;bottom:10px}}
@media print{@page{size:landscape;margin:0}body{display:block;background:#171717}.toolbar,.detail,.legend{display:none}.stage{width:100vw;height:100vh}.stage svg{width:100%;height:100%}}
@media print{@page{size:landscape;margin:0}body{display:block;background:#171717}.toolbar,.detail,.legend{display:none}.stage{width:100vw;height:100vh}.stage svg{width:100%;height:100%}}
</style></head><body><div class="toolbar"><input id="search" placeholder="搜索项目或对话..."><button id="fit">重置视图</button><button id="print">导出 PDF</button></div><main class="stage" id="stage"><svg id="graph" viewBox="0 0 900 700" preserveAspectRatio="xMidYMid meet" aria-label="项目网络图"><g id="viewport"><g id="edges">$($staticEdges -join '')</g><g id="nodes">$($staticNodes -join '')</g></g></svg><div class="legend">紫色为文件夹 · 灰色为对话；滚轮缩放 · 拖动画布/节点 · 点击查看进度或经验 Markdown</div></main><aside class="detail" id="detail"><h2>Codex 项目网络</h2><p class="hint">显示当前项目根目录下的项目文件夹和对话。点击文件夹查看进度/经验，点击对话查看本次沉淀的项目经验 Markdown。</p></aside>
<script>window.requestAnimationFrame=function(){return 0};</script><script>
const graph=$json,svg=document.getElementById('graph'),viewport=document.getElementById('viewport'),edgesLayer=document.getElementById('edges'),nodesLayer=document.getElementById('nodes'),detail=document.getElementById('detail'),stage=document.getElementById('stage'),search=document.getElementById('search');const ns='http://www.w3.org/2000/svg';let w=Math.max(320,stage.clientWidth),h=Math.max(320,stage.clientHeight),view={x:0,y:0,scale:1},pan=null,drag=null,selected=null;const printMode=new URLSearchParams(location.search).has('print');svg.setAttribute('viewBox','0 0 '+w+' '+h);const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));function labelWidth(n){return Math.min(260,Math.max(54,[...n.title].length*13))}function degree(n){return graph.edges.filter(e=>e.from===n.id||e.to===n.id).length}function transform(){viewport.setAttribute('transform','translate('+view.x+' '+view.y+') scale('+view.scale+')')}function fit(){if(!graph.nodes.length)return;let minX=Infinity,minY=Infinity,maxX=-Infinity,maxY=-Infinity;for(const n of graph.nodes){const hw=labelWidth(n)/2;minX=Math.min(minX,n.x-hw);maxX=Math.max(maxX,n.x+hw);minY=Math.min(minY,n.y-n.r);maxY=Math.max(maxY,n.y+n.r+24)}const pad=56,bw=Math.max(1,maxX-minX),bh=Math.max(1,maxY-minY),s=Math.max(.25,Math.min(1.25,(w-pad*2)/bw,(h-pad*2)/bh));view={scale:s,x:(w-(minX+maxX)*s)/2,y:(h-(minY+maxY)*s)/2};transform()}function render(){edgesLayer.innerHTML='';nodesLayer.innerHTML='';for(const e of graph.edges){const a=graph.nodes.find(n=>n.id===e.from),b=graph.nodes.find(n=>n.id===e.to);if(!a||!b)continue;const l=document.createElementNS(ns,'line');l.setAttribute('x1',a.x);l.setAttribute('y1',a.y);l.setAttribute('x2',b.x);l.setAttribute('y2',b.y);l.setAttribute('class','edge '+(e.type==='link'?'link':''));edgesLayer.appendChild(l)}for(const n of graph.nodes){const g=document.createElementNS(ns,'g');g.setAttribute('class','node '+(selected===n.id?'selected':''));g.dataset.id=n.id;const c=document.createElementNS(ns,'circle');c.setAttribute('cx',n.x);c.setAttribute('cy',n.y);c.setAttribute('r',n.r);c.setAttribute('fill',n.kind==='folder'?'#c084fc':'#a3a3a3');const t=document.createElementNS(ns,'text');t.setAttribute('x',n.x);t.setAttribute('y',n.y+n.r+17);t.textContent=n.title.length>28?n.title.slice(0,27)+'…':n.title;g.append(c,t);g.addEventListener('pointerdown',e=>startNode(e,n));g.addEventListener('click',()=>showNode(n.id));nodesLayer.appendChild(g)}}function showNode(id){selected=id;const n=graph.nodes.find(x=>x.id===id);if(!n)return;const action=n.filePath?'<p><button onclick="openMarkdown(\''+encodeURIComponent(n.filePath)+'\')">打开对应 Markdown 文件</button></p><code>'+esc(n.filePath)+'</code>':'';detail.innerHTML='<h2>'+esc(n.title)+'</h2><p>'+(n.kind==='conversation'?'对话经验':'项目文件夹')+' · '+esc(n.relative)+'</p>'+action+'<pre>'+esc(n.content)+'</pre>';render()}function openMarkdown(encodedPath){fetch('/open?path='+encodedPath).then(r=>{if(!r.ok)throw new Error('无法打开文件');return r.text()}).catch(e=>alert(e.message))}function startNode(e,n){e.stopPropagation();drag={node:n,lastX:e.clientX,lastY:e.clientY};svg.setPointerCapture(e.pointerId)}function pointerDelta(dx,dy){const rect=svg.getBoundingClientRect();return{x:dx*w/Math.max(1,rect.width),y:dy*h/Math.max(1,rect.height)}}svg.addEventListener('pointermove',e=>{if(drag){const d=pointerDelta(e.clientX-drag.lastX,e.clientY-drag.lastY);drag.node.x+=d.x/view.scale;drag.node.y+=d.y/view.scale;drag.lastX=e.clientX;drag.lastY=e.clientY;render()}else if(pan){const d=pointerDelta(e.clientX-pan.x,e.clientY-pan.y);view.x+=d.x;view.y+=d.y;pan={x:e.clientX,y:e.clientY};transform()}});svg.addEventListener('pointerup',()=>{drag=null;pan=null;stage.classList.remove('dragging')});svg.addEventListener('pointercancel',()=>{drag=null;pan=null;stage.classList.remove('dragging')});svg.addEventListener('pointerdown',e=>{if(e.target===svg){pan={x:e.clientX,y:e.clientY};stage.classList.add('dragging')}});svg.addEventListener('wheel',e=>{e.preventDefault();const old=view.scale,next=Math.max(.25,Math.min(3,old*(e.deltaY<0?1.1:.9))),rect=svg.getBoundingClientRect(),px=(e.clientX-rect.left)*w/Math.max(1,rect.width),py=(e.clientY-rect.top)*h/Math.max(1,rect.height);view.x=px-(px-view.x)*next/old;view.y=py-(py-view.y)*next/old;view.scale=next;transform()},{passive:false});search.oninput=()=>{const q=search.value.toLowerCase();document.querySelectorAll('.node').forEach(el=>{const n=graph.nodes.find(x=>x.id===el.dataset.id);el.classList.toggle('dim',q&&!n.title.toLowerCase().includes(q)&&!n.relative.toLowerCase().includes(q))})};document.getElementById('fit').onclick=fit;document.getElementById('print').onclick=()=>window.print();window.addEventListener('beforeunload',()=>navigator.sendBeacon('/shutdown',''));function simulate(step){const edgeLength=Math.max(125,Math.min(215,Math.min(w,h)*.23));for(const n of graph.nodes){let fx=(w/2-n.x)*.0008,fy=(h/2-n.y)*.0008;for(const o of graph.nodes){if(n===o)continue;let dx=n.x-o.x,dy=n.y-o.y,d=Math.max(1,Math.hypot(dx,dy)),minD=n.r+o.r+Math.max(44,(labelWidth(n)+labelWidth(o))*.42);if(d<minD){const f=(minD-d)*.035;fx+=dx/d*f;fy+=dy/d*f}else{const f=9000/(d*d);fx+=dx/d*f;fy+=dy/d*f}}for(const e of graph.edges){const o=e.from===n.id?graph.nodes.find(x=>x.id===e.to):e.to===n.id?graph.nodes.find(x=>x.id===e.from):null;if(!o)continue;let dx=o.x-n.x,dy=o.y-n.y,d=Math.max(1,Math.hypot(dx,dy)),f=(d-edgeLength)*.0022;fx+=dx*f;fy+=dy*f}if(!drag||drag.node!==n){n.vx=(n.vx+fx)*.84;n.vy=(n.vy+fy)*.84;n.x=Math.max(48,Math.min(w-48,n.x+n.vx));n.y=Math.max(48,Math.min(h-48,n.y+n.vy))}}render();if(step===359){fit();render()}else if(!printMode&&step<360)requestAnimationFrame(()=>simulate(step+1))}graph.nodes.forEach((n,i)=>{const a=i*2.399963,ratio=Math.sqrt((i+.5)/Math.max(1,graph.nodes.length)),rx=Math.max(100,Math.min(w*.38,h*.34)),ry=Math.max(100,Math.min(h*.34,w*.50));n.x=w/2+Math.cos(a)*rx*ratio;n.y=h/2+Math.sin(a)*ry*ratio;n.vx=0;n.vy=0;n.r=Math.min(25,10+degree(n)*2)});fit();if(printMode){for(let i=0;i<360;i++)simulate(i)}else{simulate(0)}const resizeObserver=new ResizeObserver(()=>{const nw=Math.max(320,stage.clientWidth),nh=Math.max(320,stage.clientHeight);if(Math.abs(nw-w)<2&&Math.abs(nh-h)<2)return;const sx=nw/w,sy=nh/h;for(const n of graph.nodes){n.x*=sx;n.y*=sy;n.vx*=sx;n.vy*=sy}w=nw;h=nh;svg.setAttribute('viewBox','0 0 '+w+' '+h);fit();render()});resizeObserver.observe(stage);
</script><script>
let clickCandidate=null;svg.addEventListener('pointerdown',e=>{const node=e.target.closest?e.target.closest('.node'):null;if(node)clickCandidate={id:node.dataset.id,x:e.clientX,y:e.clientY,moved:false};else clickCandidate=null},true);svg.addEventListener('pointermove',e=>{if(clickCandidate&&Math.hypot(e.clientX-clickCandidate.x,e.clientY-clickCandidate.y)>5)clickCandidate.moved=true},true);svg.addEventListener('pointerup',()=>{const candidate=clickCandidate;clickCandidate=null;if(candidate&&!candidate.moved)showNode(candidate.id)},true);svg.addEventListener('pointercancel',()=>{clickCandidate=null},true);
function stableLayout(){const root=graph.nodes.find(n=>n.kind==='folder'&&n.relative==='.')||graph.nodes[0];if(!root)return;const children=new Map();for(const e of graph.edges){if(e.type!=='contains')continue;if(!children.has(e.from))children.set(e.from,[]);children.get(e.from).push(graph.nodes.find(n=>n.id===e.to))}const cx=w/2,cy=h/2,ring=Math.max(140,Math.min(w,h)*.34),step=Math.max(140,Math.min(w,h)*.24);root.x=cx;root.y=cy;root.vx=0;root.vy=0;root.r=Math.min(25,10+degree(root)*2);const first=children.get(root.id)||[];first.forEach((n,i)=>{const a=-Math.PI/2+2*Math.PI*i/Math.max(1,first.length);n.x=cx+Math.cos(a)*ring;n.y=cy+Math.sin(a)*ring;n.vx=0;n.vy=0});let frontier=first,seen=new Set([root.id,...first.map(n=>n.id)]);while(frontier.length){const next=[];for(const parent of frontier){const descendants=(children.get(parent.id)||[]).filter(n=>n&&!seen.has(n.id));if(!descendants.length)continue;const base=Math.atan2(parent.y-cy,parent.x-cx),spread=Math.min(1.15,descendants.length*.28);descendants.forEach((n,i)=>{const offset=descendants.length===1?0:(i/(descendants.length-1)-.5)*spread,a=base+offset;n.x=parent.x+Math.cos(a)*step;n.y=parent.y+Math.sin(a)*step;n.vx=0;n.vy=0;next.push(n);seen.add(n.id)})}frontier=next}const extras=graph.nodes.filter(n=>!seen.has(n.id));extras.forEach((n,i)=>{const a=2*Math.PI*i/Math.max(1,extras.length);n.x=cx+Math.cos(a)*(ring+step);n.y=cy+Math.sin(a)*(ring+step)});for(const n of graph.nodes)n.r=Math.min(25,10+degree(n)*2);fit();render()}
stableLayout();new ResizeObserver(()=>{stableLayout()}).observe(stage);
</script></body></html>
"@
    Set-Content -LiteralPath $htmlPath -Value $html -Encoding UTF8
    return $htmlPath
}

function Export-Pdf {
    $html = Graph-Generate-Network
    $pdfRequested = if ($OutputPath -and $OutputPath.ToLowerInvariant().EndsWith('.pdf')) { if ([System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $TargetRoot $OutputPath } } else { Join-Path (Split-Path $html -Parent) '项目图谱.pdf' }
    $pdf = [System.IO.Path]::GetFullPath($pdfRequested)
    $edgeCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    )
    $edge = $edgeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $edge) { Write-Output "已生成 HTML：$html`r`n未找到 Microsoft Edge，请打开 HTML 后使用打印功能导出 PDF。"; return }
    $uri = ([System.Uri]$html).AbsoluteUri + '?print=1'
    $profile = Join-Path $env:TEMP ("pm-edge-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $profile -Force | Out-Null
    & $edge --headless=new --disable-gpu --disable-gpu-compositing --disable-software-rasterizer --disable-features=UseSkiaRenderer --no-sandbox --user-data-dir=$profile --no-pdf-header-footer --print-to-pdf=$pdf $uri | Out-Null
    if (Test-Path -LiteralPath $pdf) { Write-Output "已生成：$pdf`r`n图谱源文件：$html" } else { Write-Output "已生成 HTML：$html`r`nPDF 导出失败，请打开 HTML 后使用打印功能。" }
}

function List-Playbooks {
    Get-ChildItem -LiteralPath (Join-Path $Root 'playbooks') -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue | Where-Object {$_.Name -ne 'README.md'} | ForEach-Object {
        $m = Meta (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8)
        "{0}`t{1}`t{2}" -f $_.FullName,$m.type,$m.title
    }
}

switch ($Command) {
    'help' { Usage }
    'init-project' { Init-Project }
    'new-task' { New-Task }
    'resume' { Resume-Task }
    'status' { Show-Status }
    'record-attempt' { Record-Attempt }
    'detect-capture' { Detect-Capture }
    'capture' { Capture-Decision }
    'add-playbook' { Add-Playbook }
    'checkpoint' { Checkpoint }
    'conversation-start' { Conversation-Start }
    'conversation-end' { Conversation-End }
    'archive-conversation' { Archive-Conversation }
    'graph' { Graph-Generate-Network }
    'export-pdf' { Export-Pdf }
    'list-playbooks' { List-Playbooks }
}
