<#
脚本功能：
1. 多远程txt源下载
2. 黑名单分组过滤
3. 清洗emoji、零宽隐形字符
4. 分组重命名映射
5. 同分组频道追加至尾部、全局频道去重
6. 分组顺序按照第一次出现顺序
7. 修复Tls13枚举null报错、锁定输出绝对路径，防止写跑偏
#>
# ===================== 【配置区，按需自行修改】=====================
# 黑名单分组名称
$blackGroupList = @(
    "更新时间"
    "幼儿园"
)
# 分组重命名映射：清洗后旧分组名 => 新分组名
$renameGroupMap = @{
    "地方台" = "地方频道"
}
# TXT直播源地址列表
$sourceUrls = @(
    "https://gitee.com/hw2837/iptv/raw/master/iptv",
    "https://gitee.com/mycaijunhao/123/raw/master/sttv",
    "https://gitee.com/zwssina/yunduanyuan/raw/master/SB",
    "https://pastebin.com/raw/RV8wks5K"
)
# 下载重试次数、等待秒数
$retryMax = 3
$retryWaitSec = 8
# ====================================================================

# 锁定脚本目录、仓库根目录，防止Action工作目录偏移
$ScriptRoot = $PSScriptRoot
$RepoRoot = Split-Path $ScriptRoot -Parent
$outFile = Join-Path $RepoRoot "output\out3.txt"

#region HTTPS证书信任（兼容没有Tls13枚举的pwsh环境，修复null转换报错）
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ([Enum]::IsDefined([Net.SecurityProtocolType], "Tls13")) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13
}
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
#endregion

#region 清理历史输出文件
if(Test-Path $outFile) {
    Remove-Item $outFile -Force -ErrorAction SilentlyContinue
}
Write-Host " 已清理历史输出文件`n"
Write-Host "✅ 输出文件绝对路径: $outFile`n"
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
            Write-Host " ✅ 下载成功`n"
            return $true
        }
        catch{
            Write-Host " ⚠️ 下载尝试 $tryCount 失败：$($_.Exception.Message)" -ForegroundColor DarkYellow
            if($tryCount -ge $MaxRetry) {
                Write-Host " ❌ 已达到最大重试次数，该源下载终止！" -ForegroundColor Red
                return $false
            }
            Write-Host " 等待 ${WaitSeconds}s 后重试..."
            Start-Sleep -Seconds $WaitSeconds
        }
    }
    return $false
}
#endregion

#region 批量下载所有源到临时文件
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

#region TXT源解析、清洗、分组合并、全局去重
Write-Host " 开始解析TXT源，黑名单过滤+表情清洗+分组重命名+同名分组合并，同分组频道追加到尾部`n"
$entryHash = @{}       # 全局去重key：频道名|url
$groupBucket = @{}     # 分组容器：key=最终分组名，value=频道行数组
$groupOrder = @()      # 记录分组首次出现顺序
$totalChannel = 0

for($i=0;$i -lt $tmpList.Count;$i++){
    $tempPath = $tmpList[$i]
    $srcIndex = $i + 1
    $rawLines = Get-Content $tempPath -Encoding UTF8
    $currentGroupName = $null

    foreach($line in $rawLines){
        $lineTrim = $line.Trim()
        if([string]::IsNullOrWhiteSpace($lineTrim)){continue}

        # 匹配分组标记行：xxx,#genre#
        if($lineTrim -match '^(.*?),#genre#$'){
            $groupRaw = $matches[1]
            # 清洗emoji、零宽字符、BOM
            $groupClean = [regex]::Replace($groupRaw, '[\u2600-\u26FF]|[\u2700-\u27BF]|[\uD800-\uDBFF][\uDC00-\uDFFF]|\u200B|\u200C|\u200D|\uFEFF', '')
            $groupClean = $groupClean.Trim()

            # 黑名单跳过
            if($blackGroupList -contains $groupClean){
                $currentGroupName = $null
                Write-Host " 源$srcIndex：命中黑名单分组【$groupClean】，跳过"
                continue
            }
            # 分组重命名
            $finalGroupName = $groupClean
            if($renameGroupMap.ContainsKey($groupClean)){
                $finalGroupName = $renameGroupMap[$groupClean]
            }
            $currentGroupName = $finalGroupName

            # 新分组加入顺序列表
            if(-not $groupBucket.ContainsKey($finalGroupName)){
                $groupBucket[$finalGroupName] = @()
                $groupOrder += $finalGroupName
            }
            continue
        }

        # 匹配频道行：频道名称,url
        if($currentGroupName -and $lineTrim -match '^(.*?),(.+)$'){
            $chRaw = $matches[1]
            $urlRaw = $matches[2]
            $chClean = [regex]::Replace($chRaw, '[\u2600-\u26FF]|[\u2700-\u27BF]|[\uD800-\uDBFF][\uDC00-\uDFFF]|\u200B|\u200C|\u200D|\uFEFF', '')
            $chClean = $chClean.Trim()
            $urlClean = $urlRaw.Trim()

            $uniqueKey = "$chClean|$urlClean"
            if(-not $entryHash.ContainsKey($uniqueKey)){
                $entryHash[$uniqueKey] = $true
                $groupBucket[$currentGroupName] += "$chClean,$urlClean"
                $totalChannel++
            }
        }
    }
}
#endregion

#region 一次性组装并写入文件（StringBuilder，避免多次IO句柄问题）
$sb = [System.Text.StringBuilder]::new()
foreach($gName in $groupOrder) {
    $sb.AppendLine("$gName,#genre#") | Out-Null
    foreach($line in $groupBucket[$gName]){
        $sb.AppendLine($line) | Out-Null
    }
}
[System.IO.File]::WriteAllText($outFile, $sb.ToString(), [System.Text.Encoding]::UTF8)

# 打印MD5哈希，用于日志判断文件是否真实改动
$fileMd5 = (Get-FileHash $outFile -Algorithm MD5).Hash
Write-Host "`n✅ 脚本执行完成，输出文件大小：$((Get-Item $outFile).Length) 字节"
Write-Host "📌 out3.txt MD5: $fileMd5"
#endregion

#region 清理临时文件
foreach($tmp in $tmpList){
    if(Test-Path $tmp){
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}
Write-Host " 临时文件清理完毕"
Write-Host "==== script3.ps1 执行完成 ====" -ForegroundColor Green
#endregion
