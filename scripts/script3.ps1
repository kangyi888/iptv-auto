<#
脚本功能：
1. 下载3个远程M3U源，适配标准格式：#EXTINF:-1 tvg-id="" tvg-name="" tvg-logo="" group-title="分组名",频道名
2. 支持EPG头行 #EXTM3U x-tvg-url="..." 保留
3. 黑名单分组：命中黑名单group-title分组，丢弃该分组全部频道
4. 清洗：移除emoji表情、零宽隐形Unicode特殊字符，中文保留
5. 分组标题替换（清洗后的分组名匹配替换）
6. 同名分组合并：相同分组名全部频道归集到首次出现的分组，全局去重
7. 输出完整标准M3U（保留tvg-id/tvg-name/tvg-logo/group-title全部属性）
8. 远程源下载失败自动重试，间隔15秒，最多重试3次，失败则退出
#>
# ===================== 【配置区，请自行修改这里】=====================
# 黑名单分组：填写分组名称（不需要,#genre#后缀，直接写分组名）
$blackGroupList = @(
    "更新时间",
    "MO测试",
    "体育",
    "地方",
    "新闻",
    "教育",
    "综艺",
    "少儿",
    "纪实"
)
# ==========【新增分组重命名映射】【清洗后的旧分组名 => 新分组名】 ==========
$renameGroupMap = @{
    "地方台" = "地方频道"
}
# 3个远程M3U地址
$urlM3U1 = "这里替换成script3的源地址1"
$urlM3U2 = "这里替换成script3的源地址2"
$urlM3U3 = "这里替换成script3的源地址3"
# 输出文件（输出到上层output目录）
$outFileName = "../output/out3.m3u"
# 临时本地文件（放在脚本同目录）
$tempFile1 = "$PSScriptRoot\temp_src1.m3u"
$tempFile2 = "$PSScriptRoot\temp_src2.m3u"
$tempFile3 = "$PSScriptRoot\temp_src3.m3u"
# 下载重试设置
$retryMax = 3
$retryWaitSec = 15
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
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.ServicePointManager]::Tls12
#endregion
#region 清理旧临时文件
$tempList = @($tempFile1,$tempFile2,$tempFile3)
foreach($f in $tempList){
    if (Test-Path $f) { Remove-Item $f -Force }
}
if (Test-Path $outFileName) { Remove-Item $outFileName -Force }
Write-Host " 已清理历史临时文件`n"
#endregion
#region 带重试的下载函数
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
            # 增加 -UseBasicParsing 解决Windows Powershell IE引擎导致空白文件
            Invoke-WebRequest -Uri $DownloadUrl -OutFile $OutPath -TimeoutSec 30 -UseBasicParsing
            # 校验文件大小，小于100字节判定下载无效（空文件）
            $fileInfo = Get-Item $OutPath
            Write-Host " 下载文件大小：$($fileInfo.Length) 字节"
            if($fileInfo.Length -lt 100){
                throw "文件内容过小，判定为空源"
            }
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
#region 下载3个远程M3U
$urlList = @(
    @{Url=$urlM3U1; Local=$tempFile1},
    @{Url=$urlM3U2; Local=$tempFile2},
    @{Url=$urlM3U3; Local=$tempFile3}
)
foreach($item in $urlList){
    $downloadOk = Invoke-DownloadWithRetry -DownloadUrl $item.Url -OutPath $item.Local -MaxRetry $retryMax -WaitSeconds $retryWaitSec
    if(-not $downloadOk) {
        exit 1
    }
}
#endregion
#region M3U解析【新版：同名分组归集合并】黑名单过滤+清洗+分组重命名+全局去重
Write-Host " 开始解析3个M3U源，group-title分组识别，黑名单过滤 + 清洗表情符号 + 分组重命名 + 同名分组合并..."
$entryHash = @{} # 全局去重key=频道名|url
$groupBucket = @{} # key=最终分组名，value=数组存放(extinf,url)
$groupOrder = @()  # 记录分组首次出现顺序，保证输出顺序
$totalChannel = 0
for($i=0;$i -lt $tempList.Count;$i++){
    $tempPath = $tempList[$i]
    $srcIndex = $i + 1
    $rawLines = Get-Content $tempPath -Encoding UTF8
    $skipThisGroup = $false
    $extinfLine = ""
    $currentGroupName = ""
    $currentChannelName = ""
    foreach($line in $rawLines){
        $lineTrim = $line.Trim()
        if([string]::IsNullOrWhiteSpace($lineTrim)){continue}
        # 匹配 #EXTINF:-1 xxx group-title="分组名",频道名
        if($lineTrim -match '^#EXTINF:(.+?)group-title="([^"]+)",(.*)$'){
            $fullExtInfRaw = $lineTrim
            $groupRaw = $matches[2]
            $chNameRaw = $matches[3]
            # 清洗分组名、频道名，移除表情、零宽字符
            $groupClean = [regex]::Replace($groupRaw, '[\u2600-\u26FF]|[\u2700-\u27BF]|[\uD800-\uDBFF][\uDC00-\uDFFF]|\u200B|\u200C|\u200D|\uFEFF', '')
            $groupClean = $groupClean.Trim()
            $chClean = [regex]::Replace($chNameRaw, '[\u2600-\u26FF]|[\u2700-\u27BF]|[\uD800-\uDBFF][\uDC00-\uDFFF]|\u200B|\u200C|\u200D|\uFEFF', '')
            $chClean = $chClean.Trim()
            # 清洗EXTINF整行内的表情符号
            $fullExtInfClean = [regex]::Replace($fullExtInfRaw, '[\u2600-\u26FF]|[\u2700-\u27BF]|[\uD800-\uDBFF][\uDC00-\uDFFF]|\u200B|\u200C|\u200D|\uFEFF', '')
            # ==========分组重命名逻辑==========
            $finalGroupName = $groupClean
            if($renameGroupMap.ContainsKey($groupClean)){
                $finalGroupName = $renameGroupMap[$groupClean]
                Write-Host " 源$srcIndex：分组重命名【$groupClean】 → 【$finalGroupName】"
                # 替换EXTINF行内group-title的值，保留其他所有属性不变
                $fullExtInfClean = $fullExtInfClean -replace 'group-title="([^"]+)"', "group-title=`"$finalGroupName`""
            }
            # ===================================
            $extinfLine = $fullExtInfClean
            $currentGroupName = $finalGroupName
            $currentChannelName = $chClean
            # 判断黑名单分组：黑名单使用清洗后的原始分组名（替换前）
            if($blackGroupList -contains $groupClean){
                $skipThisGroup = $true
                Write-Host " 源$srcIndex：命中黑名单分组【$groupClean】，丢弃该分组全部频道"
            }else{
                $skipThisGroup = $false
                # 记录分组首次出现顺序
                if(-not $groupBucket.ContainsKey($finalGroupName)){
                    $groupBucket[$finalGroupName] = @()
                    $groupOrder += $finalGroupName
                }
            }
            continue
        }
        # URL行，非#开头
        if(-not $lineTrim.StartsWith("#")){
            if($skipThisGroup){
                $extinfLine = ""
                continue
            }
            if(-not [string]::IsNullOrWhiteSpace($extinfLine) -and -not [string]::IsNullOrWhiteSpace($lineTrim)){
                $urlClean = [regex]::Replace($lineTrim, '[\u2600-\u26FF]|[\u2700-\u27BF]|[\uD800-\uDBFF][\uDC00-\uDFFF]|\u200B|\u200C|\u200D|\uFEFF', '')
                $uniqueKey = "$currentChannelName|$urlClean"
                if(-not $entryHash.ContainsKey($uniqueKey)){
                    $entryHash[$uniqueKey] = $true
                    $groupBucket[$currentGroupName] += @{
                        ExtInf = $extinfLine
                        Url    = $urlClean
                    }
                    $totalChannel++
                }
            }
            $extinfLine = ""
        }
    }
}
# 组装最终M3U文本
$m3uEntries = @()
# 输出头部，保留完整EXTM3U EPG属性
$epgHeader = '#EXTM3U x-tvg-url="http://epg.51zmt.top:8000/e.xml,https://tv.mxdyeah.top/epgphp/t.xml,https://fy.188766.xyz/e.xml" catchup="append" catchup-source="?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}"'
$m3uEntries += $epgHeader
# 按分组首次出现顺序输出，同分组所有频道依次写出
foreach($gName in $groupOrder) {
    $items = $groupBucket[$gName]
    foreach($ch in $items) {
        $m3uEntries += $ch.ExtInf
        $m3uEntries += $ch.Url
    }
}
# 写入最终M3U
$m3uEntries | Out-File $outFileName -Encoding UTF8
Write-Host " 合并解析完成，输出M3U文件：$outFileName"
Write-Host " 有效频道数量：$totalChannel`n"
#endregion
# 清理临时文件
foreach($f in $tempList){
    if (Test-Path $f) { Remove-Item $f -Force }
}
Write-Host "`n 已清理全部本地临时文件"
Write-Host "`n==== script3 任务执行完毕 ====" -ForegroundColor Green
