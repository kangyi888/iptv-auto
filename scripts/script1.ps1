<#
script1.ps1
功能：多M3U源下载 + 分组黑名单过滤 + 分组标题重命名 + 同名分组合并归集
输出：output\out1.m3u
#>
# 极简SSL 忽略证书，适配PowerShell7
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::Tls12
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

# ========== 配置区（自行修改）==========
$outFile = "output\out1.m3u"

# M3U远程源列表
$sourceUrls = @(
    "https://gitee.com/lwr851/live/raw/master/iptv.m3u",
    "https://raw.githubusercontent.com/kangyi888/IPTV/refs/heads/main/live.m3u",
    "https://raw.githubusercontent.com/jn958/live/main/holive.m3u"
)

# 黑名单分组：包含关键词直接丢弃该分组全部频道
$blackListGroup = @(
    "更新时间",
    "MO测试",
    "体育",
    "地方",
    "新闻",
    "教育",
    "少儿",
    "纪实"
)

# 分组重命名映射：旧分组名 => 新分组名
$renameMap = @{
    "地方台" = "地方频道"
}
# ========================================

# 字典：key=分组名，value=完整EXTINF+频道行数组，同名分组自动合并
$groupDict = @{}

foreach($url in $sourceUrls){
    Write-Host "正在下载源（重试1/3）: $url"
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
            $currentGroup = "其他"
            $extInfLine = $null

            foreach($line in $lines){
                $line = $line.Trim()
                if([string]::IsNullOrWhiteSpace($line)){continue}

                # 捕获EXTINF行，提取group-title
                if($line -match '#EXTINF(.*?)group-title="([^"]+)"'){
                    $extInfLine = $line
                    $currentGroup = $matches[2]

                    # 黑名单过滤
                    $skipGroup = $false
                    foreach($bw in $blackListGroup){
                        if($currentGroup -match $bw){
                            $skipGroup = $true
                            break
                        }
                    }
                    if($skipGroup){
                        $currentGroup = $null
                        $extInfLine = $null
                        continue
                    }
                    # 分组重命名
                    if($renameMap.ContainsKey($currentGroup)){
                        $currentGroup = $renameMap[$currentGroup]
                    }
                }
                # 频道URL行，并且存在有效的EXTINF和分组
                if($currentGroup -and $extInfLine -and $line -notmatch "^#"){
                    $record = @($extInfLine,$line)
                    if(-not $groupDict.ContainsKey($currentGroup)){
                        $groupDict[$currentGroup] = @()
                    }
                    $groupDict[$currentGroup] += $record
                    $extInfLine = $null
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

# 清空旧文件，写入M3U头部
if(Test-Path $outFile){
    Remove-Item $outFile -Force
}
"#EXTM3U" | Out-File $outFile -Encoding UTF8

# 遍历分组输出归集后的完整m3u内容
foreach($gName in $groupDict.Keys){
    Write-Host "输出分组：$gName，频道数量：$($groupDict[$gName].Count/2)"
    $groupDict[$gName] -join "`r`n" | Out-File $outFile -Append -Encoding UTF8
    "`r`n" | Out-File $outFile -Append -Encoding UTF8
}

# ========== 输出文件校验，防止空m3u ==========
$finalFile = Get-Item $outFile
if($finalFile.Length -lt 100){
    throw "输出文件过小($($finalFile.Length)字节)，生成空m3u，终止任务"
}
Write-Host "脚本执行完成，输出文件大小：$($finalFile.Length) 字节"
