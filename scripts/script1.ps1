<#
脚本功能：
1. 多远程M3U源下载，标准格式：#EXTINF:-1 tvg-id="" tvg-name="" tvg-logo="" group-title="分组名",频道名
2. 黑名单分组：命中黑名单group-title分组，丢弃该分组全部频道
3. 清洗：移除emoji表情、零宽隐形Unicode特殊字符，中文保留
4. 分组标题替换（清洗后的分组名替换，同步修改EXTINF内group-title）
5. 同名分组合并：相同分组名归集到首次出现分组，后续源同分组频道追加到该分组尾部，全局频道去重
6. 分组顺序：使用独立数组$groupOrder记录分组首次出现顺序
7. 输出完整标准M3U，保留tvg-id/tvg-name/tvg-logo/group-title全部属性
8. 远程源下载失败自动重试，等待8秒，最多重试3次，失败直接退出
修复点：EXTINF属性顺序不固定时也能正确提取group-title，解决部分源频道丢失
#>
# ===================== 【配置区，请自行修改这里】=====================
# 黑名单分组（填写【清洗之后】的分组名）
$blackGroupList = @(
    "更新时间",
    "本地频道",
    "MO测试",
    "体育",
    "新闻",
    "教育",
    "综艺",
    "少儿",
    "纪实"
)
# 分组重命名映射【清洗后的旧分组名 => 新分组名】
$renameGroupMap = @{
    "地方台" = "地方频道"
}
# M3U远程源列表
$sourceUrls = @(
    "https://gitee.com/lwr851/live/raw/master/iptv.m3u",
    "https://gh-proxy.org/https://raw.githubusercontent.com/kangyi888/IPTV/refs/heads/main/live.m3u",
    "https://gh-proxy.org/https://raw.githubusercontent.com/jn950/live/main/tv/holive.m3u"
)
$outFile = "output\out1.m3u"
# 下载重试设置
$retryMax = 3
$retryWaitSec = 8
# ====================================================================
#region HTTPS证书信任（适配PowerShell7 / .NET Core）
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::Tls12 -bor [Net.ServicePointManager]::Tls13
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
#endregion
#region 清理旧临时文件与输出文件
if(Test-Path "tmp_src1"){Remove-Item "tmp_src1" -Force -ErrorAction SilentlyContinue}
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
#region M3U解析【修复核心：独立提取group-title，不受属性顺序影响】
Write-Host " 开始解析M3U源，黑名单过滤+清洗表情+分组重命名+同名分组合并，同分组频道追加到尾部`n"
$entryHash = @{} #全局去重 key=频道名|url
$groupBucket = @{} #分组存储：key=最终分组名，value=频道对象数组
$groupOrder = @()  #独立数组记录分组首次出现顺序
$totalChannel = 0
# 输出头部，保留完整EPG信息
$epgHeader = '#EXTM3U x-tvg-url="http://epg.51zmt.top:8000/e.xml,https://tv.mxdyeah.top/epgphp/t.xml,https://fy.188766.xyz/e.xml" catchup="append" catchup-source="?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}"'

# 清洗函数抽离，复用
function Clear-TextSpecialChar{
    param([string]$inp)
    $r = [regex]::Replace($inp, '[\u2600-\u26FF]|[\u2700-\u27BF]|[\uD800-\uDBFF][\uDC00-\uDFFF]|\u200B|\u200C|\u200D|\uFEFF', '')
    return $r.Trim()
}

for($i=0;$i -lt $tmpList.Count;$i++){
    $tempPath = $tmpList[$i]
    $srcIndex = $i + 1
    $rawLines = Get-Content $tempPath -Encoding UTF8
    $skipThisGroup = $false
    $extinfLine = ""
    $currentGroupName = ""
    $currentChannelName = ""
    foreach($line in $rawLines){
        $lineTrim = $line.Trim()
        if([string]::IsNullOrWhiteSpace($lineTrim)){continue}

        # 匹配EXTINF行，只要以#EXTINF:开头就捕获整行
        if($lineTrim -match '^#EXTINF:.+'){
            $fullExtInfRaw = $lineTrim
            $skipThisGroup = $false
            $currentGroupName = ""
            $currentChannelName = ""

            # ========== 【修复核心：单独提取group-title，不限制位置】 ==========
            $groupRaw = ""
            if($fullExtInfRaw -match 'group-title="([^"]+)"'){
                $groupRaw = $matches[1]
            }
            # 提取逗号后面频道名称
            $chNameRaw = ""
            if($fullExtInfRaw -match ',([^,]+)$'){
                $chNameRaw = $matches[1]
            }
            # 清洗
            $groupClean = Clear-TextSpecialChar $groupRaw
            $chClean = Clear-TextSpecialChar $chNameRaw
            $fullExtInfClean = Clear-TextSpecialChar $fullExtInfRaw

            # 黑名单判断：使用清洗后的分组名
            if($blackGroupList -contains $groupClean){
                $skipThisGroup = $true
                Write-Host " 源$srcIndex：命中黑名单分组【$groupClean】，丢弃该分组全部频道"
                $extinfLine = ""
                continue
            }

            # 分组重命名
            $finalGroupName = $groupClean
            if($renameGroupMap.ContainsKey($groupClean)){
                $finalGroupName = $renameGroupMap[$groupClean]
                # 替换extinf里的group-title值
                $fullExtInfClean = $fullExtInfClean -replace 'group-title="([^"]+)"', "group-title=`"$finalGroupName`""
            }

            $extinfLine = $fullExtInfClean
            $currentGroupName = $finalGroupName
            $currentChannelName = $chClean

            # 维护分组顺序池
            if(-not $groupBucket.ContainsKey($finalGroupName)){
                $groupBucket[$finalGroupName] = @()
                $groupOrder += $finalGroupName
            }
            continue
        }

        # 频道URL行
        if(-not $lineTrim.StartsWith("#")){
            if($skipThisGroup){
                $extinfLine = ""
                continue
            }
            if(-not [string]::IsNullOrWhiteSpace($extinfLine) -and -not [string]::IsNullOrWhiteSpace($lineTrim) -and $groupBucket.ContainsKey($currentGroupName)){
                $urlClean = Clear-TextSpecialChar $lineTrim
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
#endregion
#region 组装输出M3U，严格按照$groupOrder顺序输出
$m3uEntries = @()
$m3uEntries += $epgHeader
foreach($gName in $groupOrder) {
    $items = $groupBucket[$gName]
    foreach($ch in $items) {
        $m3uEntries += $ch.ExtInf
        $m3uEntries += $ch.Url
    }
}
$m3uEntries | Out-File $outFile -Encoding UTF8
Write-Host "`n 解析完成，输出文件：$outFile"
Write-Host " 有效频道总数：$totalChannel`n"
#endregion
#region 清理临时文件
foreach($tmp in $tmpList){
    if(Test-Path $tmp){Remove-Item $tmp -Force -ErrorAction SilentlyContinue}
}
Write-Host " 临时文件清理完毕"
Write-Host "==== script1 执行完成 ====" -ForegroundColor Green
