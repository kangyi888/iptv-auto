<#
script3.ps1
功能：多txt源下载 + 分组重命名 + 同名分组合并 + 黑名单过滤
#>
# 极简SSL 忽略证书，适配PowerShell7
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::Tls12
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

# ========== 配置区（在这里修改）==========
$outFile = "output\out3.txt"

# 4个远程txt源地址
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
    "备用",
    "垃圾频道"
)

# 【分组重命名映射：旧名称 -> 新名称】
$renameMap = @{
    "地方台" = "地方频道"

}
# ========================================

# 存储分组字典，key=分组名，value=频道行数组（自动同名合并）
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
            $currentGroup = "其他" # 默认分组

            foreach($line in $lines){
                $line = $line.Trim()
                if([string]::IsNullOrWhiteSpace($line)){continue}

                # 匹配 #EXTINF 分组信息
                if($line -match '#EXTINF.*group-title="([^"]+)"'){
                    $currentGroup = $matches[1]
                    # 黑名单过滤：包含黑名单关键词直接跳过这个分组
                    $skipGroup = $false
                    foreach($bw in $blackListGroup){
                        if($currentGroup -match $bw){
                            $skipGroup = $true
                            break
                        }
                    }
                    if($skipGroup){
                        $currentGroup = $null
                        continue
                    }
                    # 分组重命名
                    if($renameMap.ContainsKey($currentGroup)){
                        $currentGroup = $renameMap[$currentGroup]
                    }
                }

                # 频道行（url行），并且当前分组不为空
                if($currentGroup -and $line -notmatch "^#"){
                    if(-not $groupDict.ContainsKey($currentGroup)){
                        $groupDict[$currentGroup] = @()
                    }
                    $groupDict[$currentGroup] += $line
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

# 清空旧文件
if(Test-Path $outFile){
    Remove-Item $outFile -Force
}

# 按分组顺序输出归集后的内容
foreach($gName in $groupDict.Keys){
    Write-Host "输出分组：$gName，频道数量：$($groupDict[$gName].Count)"
    # 输出分组标题
    "【$gName】" | Out-File $outFile -Append -Encoding UTF8
    # 输出该分组所有频道
    $groupDict[$gName] -join "`r`n" | Out-File $outFile -Append -Encoding UTF8
    "`r`n" | Out-File $outFile -Append -Encoding UTF8
}

# ========== 输出文件校验，防止空txt ==========
$finalFile = Get-Item $outFile
if($finalFile.Length -lt 100){
    throw "输出文件过小($($finalFile.Length)字节)，生成空txt，终止任务"
}
Write-Host "脚本执行完成，输出文件大小：$($finalFile.Length) 字节"
