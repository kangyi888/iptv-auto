<#
script3.ps1
功能：TVbox #genre# 多txt源下载 + 分组重命名 + 同名分组合并 + 黑名单过滤 + 频道去重
全部源为 xxx,#genre# 格式，不解析M3U
【重点】分组内频道保留原始读取顺序，后续源同分组频道追加到尾部，不再乱序
#>
# 极简SSL 忽略证书，适配PowerShell7
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::Tls12
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
# ========== 配置区（在这里修改）==========
# 基于脚本自身目录，固定输出路径
$scriptRoot = $PSScriptRoot
$outputDir  = Join-Path $scriptRoot "output"
$outFile    = Join-Path $outputDir "out3.txt"

# 4个远程txt源地址（全部TVbox #genre#格式）
$sourceUrls = @(
    "https://gitee.com//hw2837/iptv/raw/master/iptv",
    "https://gitee.com/mycaijunhao/123/raw/master/sttv",
    "https://gitee.com/zwssina/yunduanyuan/raw/master/SB",
    "https://pastebin.com/raw/RV8wks5K"
)
# 【黑名单分组：包含这些关键词的分组直接丢弃】
$blackListGroup = @(
    "测试区_7890",
    "幼儿园",
    "备用1",
    "垃圾频道1"
)
# 【分组重命名映射：旧名称 -> 新名称】
$renameMap = @{
    "地方台" = "地方频道"
}
# ========================================

# 自动创建output目录
if(-not (Test-Path $outputDir)){
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}
Write-Host "✅ 输出文件绝对路径：$outFile"

# 存储分组信息：key=分组名，value=对象包含去重哈希 + 有序频道数组
$groupDict = @{}
# 记录分组首次出现顺序
$groupOrder = @()

foreach($url in $sourceUrls){
    Write-Host "正在下载源：$url"
    $retryCount = 3
    $success = $false
    for($i=1; $i -le $retryCount; $i++){
        try{
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20
            $rawContent = $resp.Content
            Write-Host "下载文件大小: $($rawContent.Length) 字节"
            if([string]::IsNullOrWhiteSpace($rawContent)){
                throw "返回空内容"
            }
            $lines = $rawContent -split "`r?`n"
            $currentGroup = $null
            $skipCurrentGroup = $false
            foreach($line in $lines){
                $line = $line.Trim()
                if([string]::IsNullOrWhiteSpace($line)){continue}
                # 识别TVbox分组行：xxx,#genre#
                if($line -match '^(.*),#genre#$'){
                    $rawGName = $matches[1]
                    # 黑名单判断
                    $skipCurrentGroup = $false
                    foreach($bw in $blackListGroup){
                        if($rawGName -match $bw){
                            $skipCurrentGroup = $true
                            break
                        }
                    }
                    if($skipCurrentGroup){
                        $currentGroup = $null
                        continue
                    }
                    # 分组重命名
                    if($renameMap.ContainsKey($rawGName)){
                        $currentGroup = $renameMap[$rawGName]
                    }else{
                        $currentGroup = $rawGName
                    }
                    # 首次出现该分组，初始化；分组已存在直接复用，频道追加至数组尾部
                    if(-not $groupDict.ContainsKey($currentGroup)){
                        $groupDict[$currentGroup] = [PSCustomObject]@{
                            seen  = @{}
                            items = @()
                        }
                        $groupOrder += $currentGroup
                    }
                    continue
                }
                # 频道行，当前分组有效且不处于黑名单跳过状态
                if($currentGroup -and (-not $skipCurrentGroup)){
                    $gData = $groupDict[$currentGroup]
                    # 只有第一次见到这条频道行，才加入有序数组
                    if(-not $gData.seen.ContainsKey($line)){
                        $gData.seen[$line] = $true
                        $gData.items += $line
                    }
                }
            }
            $success = $true
            Write-Host "源解析完成：$url"
            break
        }
        catch{
            Write-Host "下载失败，第$i次重试：$($_.Exception.Message)"
            Start-Sleep -Seconds 3
        }
    }
    if(-not $success){
        Write-Host "源下载最终失败：$url"
    }
}

# ========== 一次性组装全部文本，只写入一次（重点修复！） ==========
$outputBuilder = [System.Text.StringBuilder]::new()
foreach($gName in $groupOrder){
    $channelList = $groupDict[$gName].items
    Write-Host "输出分组：$gName，频道数量：$($channelList.Count)"
    [void]$outputBuilder.AppendLine("$gName,#genre#")
    [void]$outputBuilder.Append($channelList -join "`r`n")
    [void]$outputBuilder.AppendLine("`r`n")
}

# 一次性写入 UTF8 无BOM
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($outFile, $outputBuilder.ToString(), $utf8NoBom)

# ========== 输出文件校验，防止空txt ==========
$finalFile = Get-Item $outFile
if($finalFile.Length -lt 100){
    throw "输出文件过小($($finalFile.Length)字节)，生成空txt，终止任务"
}
Write-Host "脚本执行完成，输出文件大小：$($finalFile.Length) 字节"
