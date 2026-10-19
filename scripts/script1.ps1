<#
script1.ps1
#>
# 极简SSL 忽略证书，适配PowerShell7
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::Tls12
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

# 输出文件路径
$outFile = "output\out1.m3u"

# 源列表，自行修改这里的直播源链接
$sourceUrls = @(
    "https://gitee.com/lwr851/live/raw/master/iptv.m3u",
    "https://raw.githubusercontent.com/kangyi888/IPTV/refs/heads/main/live.m3u",
    "https://raw.githubusercontent.com/jn958/live/main/holive.m3u"
)

# 清空旧输出文件
if(Test-Path $outFile){
    Remove-Item $outFile -Force
}

# 写入m3u头部
"#EXTM3U" | Out-File $outFile -Encoding UTF8

foreach($url in $sourceUrls){
    Write-Host "正在下载源（重试1/3）: $url"
    $retryCount = 3
    $success = $false
    for($i=1; $i -le $retryCount; $i++){
        try{
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20
            $content = $resp.Content
            Write-Host "下载文件大小: $($content.Length) 字节"
            if([string]::IsNullOrWhiteSpace($content)){
                throw "返回空内容"
            }
            # 追加到输出文件
            $content | Out-File $outFile -Append -Encoding UTF8
            $success = $true
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

# ========== 输出文件校验，防止空m3u ==========
$finalFile = Get-Item $outFile
if($finalFile.Length -lt 100){
    throw "输出文件过小($($finalFile.Length)字节)，生成空m3u，终止任务"
}
Write-Host "脚本执行完成，输出文件大小：$($finalFile.Length) 字节"
