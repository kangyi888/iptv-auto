<#
脚本功能：
1. 4个远程txt直播源下载，识别#EXTINF group-title分组
2. 黑名单分组：命中黑名单group-title分组，丢弃该分组全部频道
3. 清洗：移除emoji表情、零宽隐形Unicode特殊字符，中文保留
4. 分组标题替换（清洗后的分组名替换）
5. 同名分组合并：相同分组名归集到首次出现分组，全局频道去重
6. 分组顺序：使用独立数组$groupOrder记录分组首次出现顺序
7. 输出txt文本，格式【分组名】+频道地址
8. 远程源下载失败自动重试，等待8秒，最多重试3次，失败直接退出
#>
# ===================== 【配置区，请自行修改这里】=====================
# 黑名单分组
$blackGroupList = @(
    "测试区_7890",
    "幼儿园",
    "备用1",
    "垃圾频道1"
)
# 分组重命名映射【清洗后的旧分组名 => 新分组名】
$renameGroupMap = @{
    "地方台" = "地方频道"
}
# 4个远程txt源地址
$sourceUrls = @(
    "https://gitee.com//hw2837/iptv/raw/master/iptv",
    "https://gitee.com/mycaijunhao/123/raw/master/sttv",
    "https://gitee.com/zwssina/yunduanyuan/raw/master/SB",
    "https://pastebin.com/raw/RV8wks5K"
)
$outFile = "output\out3.txt"
# 下载重试设置
$retryMax = 3
$retryWaitSec = 8
# ====================================================================
#region HTTPS证书信任
Add-Type @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
#endregion
#region 清理旧临时文件与输出文件
if(Test-Path $outFile) { Remove-Item $outFile -Force -ErrorAction SilentlyContinue }
Write-Host " 已清理历史文件`n"
#endregion
#region 带重试下载函数
function Invoke-DownloadWithRetry {
    param(
        [string]$DownloadUrl,
        [string]$OutPath,
        [int]$MaxRetry,
        [int]$WaitSeconds
    )
    $tryCount = 0
    while($tryCount -lt $MaxRetry) {
        try{
            $tryCount++
            Write-Host " 正在下载源（尝试 $tryCount/$MaxRetry）：$DownloadUrl"
            Invoke-WebRequest -Uri $DownloadUrl -OutFile $OutPath -TimeoutSec 30
            Write-Host " 下载成功`n"
            return $true
        }
        catch{
            Write-Host " 下载尝试 $tryCount 失败：$($_.Exception.Message)" -ForegroundColor DarkYellow
            if($tryCount -ge $MaxRetry) {
                Write-Host " 已达到最大重试次数，下载终止！" -ForegroundColor Red
                return $false
            }
            Write-Host " 等待 ${WaitSeconds}s 后重试..."
            Start-Sleep -Seconds $WaitSeconds
        }
    }
    return $false
}
#endregion
#region 下载全部源
$tmpList = @()
foreach($url in $sourceUrls){
    $tmpPath = [System.IO.Path]::GetTempFileName()
    $tmpList += $tmpPath
    $ok = Invoke-DownloadWithRetry -DownloadUrl $url -OutPath $tmpPath -MaxRetry $retryMax -WaitSeconds $retryWaitSec
    if(-not $ok){
        exit 1
    }
}
#endregion
#region TXT源解析：$groupOrder数组记录分组首次出现顺序
Write-Host " 开始解析txt源，黑名单过滤+清洗表情+分组重命名+同名分组合并`n"
$entryHash = @{} #全局去重 key=频道url
$groupBucket = @{} #分组存储：key=最终分组名，value=频道url数组
$groupOrder = @()  #【核心：独立数组记录分组首次出现顺序】
$totalChannel = 0

for($i=0;$i -lt $tmpList.Count;$i++){
    $tempPath = $tmpList[$i]
    $srcIndex = $i + 1
    $rawLines = Get-Content $tempPath -Encoding UTF8
    $skipThisGroup = $false
    $extinfLine = ""
    $currentGroupName = ""

    foreach($line in $rawLines){
        $lineTrim = $line.Trim()
        if([string]::IsNullOrWhiteSpace($lineTrim)){continue}

        # 匹配EXTINF提取group-title
        if($lineTrim -match '^#EXTINF:(.+?)group-title="([^"]+)",(.*)$'){
            $fullExtInfRaw = $lineTrim
            $groupRaw = $matches[2]
            $chNameRaw = $matches[3]

            # 清洗表情、零宽字符
            $groupClean = [regex]::Replace($groupRaw, '[\u2600-\u26FF]|[\u2700-\u27BF]|[\uD800-\uDBFF][\uDC00-\uDFFF]|\u200B|\u200C|\u200D|\uFEFF', '')
            $groupClean = $groupClean.Trim()

            # 分组重命名
            $finalGroupName = $groupClean
            if($renameGroupMap.ContainsKey($groupClean)){
                $finalGroupName = $renameGroupMap[$groupClean]
                Write-Host " 源$srcIndex：分组重命名【$groupClean】→【$finalGroupName】"
            }

            $extinfLine = $fullExtInfRaw
            $currentGroupName = $finalGroupName

            # 黑名单判断
            if($blackGroupList -contains $groupClean){
                $skipThisGroup = $true
                Write-Host " 源$srcIndex：命中黑名单分组【$groupClean】，丢弃该分组全部频道"
            }else{
                $skipThisGroup = $false
                # 首次出现分组加入groupOrder
                if(-not $groupBucket.ContainsKey($finalGroupName)){
                    $groupBucket[$finalGroupName] = @()
                    $groupOrder += $finalGroupName
                }
            }
            continue
        }

        # 频道URL行
        if(-not $lineTrim.StartsWith("#")){
            if($skipThisGroup){
                $extinfLine = ""
                continue
            }
            if(-not [string]::IsNullOrWhiteSpace($extinfLine) -and -not [string]::IsNullOrWhiteSpace($lineTrim)){
                $urlClean = [regex]::Replace($lineTrim, '[\u2600-\u26FF]|[\u2700-\u27BF]|[\uD800-\uDBFF][\uDC00-\uDFFF]|\u200B|\u200C|\u200D|\uFEFF', '')
                if(-not $entryHash.ContainsKey($urlClean)){
                    $entryHash[$urlClean] = $true
                    $groupBucket[$currentGroupName] += $urlClean
                    $totalChannel++
                }
            }
            $extinfLine = ""
        }
    }
}
#endregion

#region 组装txt输出，严格按照$groupOrder顺序输出
$txtEntries = @()
foreach($gName in $groupOrder) {
    $items = $groupBucket[$gName]
    $txtEntries += "【$gName】"
    $txtEntries += $items
    $txtEntries += ""
}
$txtEntries | Out-File $outFile -Encoding UTF8
Write-Host "`n 解析完成，输出文件：$outFile"
Write-Host " 有效频道总数：$totalChannel`n"
#endregion

#region 清理临时文件
foreach($tmp in $tmpList){
    if(Test-Path $tmp){Remove-Item $tmp -Force -ErrorAction SilentlyContinue}
}
Write-Host " 临时文件清理完毕"
Write-Host "==== script3 执行完成 ====" -ForegroundColor Green
