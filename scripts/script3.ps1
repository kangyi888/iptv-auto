<#
脚本功能：
1. 从网络下载4个TVbox直播源txt（支持 #genre# 分组标记）
2. 支持【黑名单分组列表】，对全部4个源生效，命中黑名单分组标题时，丢弃该分组标题+分组下全部频道，直到下一个,#genre#
3. 新增：分组标题替换，旧分组行=>新分组行
4. 合并全部剩余内容，同名分组合并归集，按【频道名,播放URL】整行去重
5. 输出合并后的单一txt文件 out3.txt
6. 自带HTTPS证书信任、临时文件清理
新增：远程源下载失败自动重试，等待8秒，最多重试3次，失败直接退出
#>
# ===================== 【配置区，请自行修改这里】=====================
# 黑名单分组：在这里添加需要整体过滤的分组标题，格式："xxx,#genre#"
$blackGroupList = @(
    "测试区_7890,#genre#",
    "幼儿园,#genre#"
)
# ==========【新增分组重命名映射】旧分组完整行 => 新分组完整行 ==========
$renameGroupMap = @{
    "地方台,#genre#" = "地方频道,#genre#"
}
# 4个远程txt源地址
$urlTxt1 = "https://gitee.com//hw2837/iptv/raw/master/iptv"
$urlTxt2 = "https://gitee.com/mycaijunhao/123/raw/master/sttv"
$urlTxt3 = "https://gitee.com/zwssina/yunduanyuan/raw/master/SB"
$urlTxt4 = "https://pastebin.com/raw/RV8wks5K"
# 输出文件名
$outFileName = "out3.txt"
# 临时本地文件
$tempFile1 = "$PSScriptRoot\temp_src1.txt"
$tempFile2 = "$PSScriptRoot\temp_src2.txt"
$tempFile3 = "$PSScriptRoot\temp_src3.txt"
$tempFile4 = "$PSScriptRoot\temp_src4.txt"
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
#region 清理旧临时文件
$tempList = @($tempFile1,$tempFile2,$tempFile3,$tempFile4)
foreach($f in $tempList){
    if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
}
if (Test-Path $outFileName) { Remove-Item $outFileName -Force -ErrorAction SilentlyContinue }
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
#region 下载4个远程txt
$urlList = @(
    @{Url=$urlTxt1; Local=$tempFile1},
    @{Url=$urlTxt2; Local=$tempFile2},
    @{Url=$urlTxt3; Local=$tempFile3},
    @{Url=$urlTxt4; Local=$tempFile4}
)
foreach($item in $urlList){
    $downloadOk = Invoke-DownloadWithRetry -DownloadUrl $item.Url -OutPath $item.Local -MaxRetry $retryMax -WaitSeconds $retryWaitSec
    if(-not $downloadOk) {
        exit 1
    }
}
#endregion
#region 合并txt，黑名单分组过滤 + 分组标题重命名 + 同名分组合并归集
Write-Host " 开始合并4个直播源txt，黑名单分组过滤开启，分组重命名已启用，同名分组合并..."
$groupBucket = @{}       # key=分组标题，value=频道数组
$groupOrder = @()        # 记录分组首次出现顺序
$channelHash = @{}       # 全局频道去重
$totalChannel = 0

for($i=0;$i -lt $tempList.Count;$i++){
    $tempPath = $tempList[$i]
    $srcIndex = $i + 1
    $rawLines = Get-Content $tempPath -Encoding UTF8
    $skipThisGroup = $false
    $currentGroup = $null

    foreach($line in $rawLines){
        $lineTrim = $line.Trim()
        if([string]::IsNullOrWhiteSpace($lineTrim)){continue}

        # 命中黑名单分组标题
        if($blackGroupList -contains $lineTrim){
            $skipThisGroup = $true
            Write-Host " 源$srcIndex：命中黑名单分组【$lineTrim】，丢弃该分组全部频道"
            continue
        }

        # 识别分组标题行 xxx,#genre#
        if($lineTrim -match ',#genre#$'){
            $skipThisGroup = $false
            $groupTitle = $lineTrim
            # 分组标题重命名
            if($renameGroupMap.ContainsKey($groupTitle)){
                $newTitle = $renameGroupMap[$groupTitle]
                Write-Host " 源$srcIndex：分组重命名【$groupTitle】 → 【$newTitle】"
                $groupTitle = $newTitle
            }
            # 首次出现的分组，记录顺序
            if(-not $groupBucket.ContainsKey($groupTitle)){
                $groupBucket[$groupTitle] = @()
                $groupOrder += $groupTitle
            }
            $currentGroup = $groupTitle
            continue
        }

        if($skipThisGroup){
            continue
        }

        # 普通频道行，整行去重加入当前分组
        if(-not $channelHash.ContainsKey($lineTrim)){
            $channelHash[$lineTrim] = $true
            $groupBucket[$currentGroup] += $lineTrim
            $totalChannel++
        }
    }
}

# 组装输出文本：按分组首次出现顺序，分组标题+频道列表
$allLines = @()
foreach($gName in $groupOrder){
    $allLines += $gName
    $allLines += $groupBucket[$gName]
}

# 输出合并文件 UTF8，TVbox中文不乱码
$allLines | Out-File $outFileName -Encoding UTF8
Write-Host " 合并完成，输出文件：$outFileName"
Write-Host " 有效频道数量：$totalChannel`n"
#endregion

# 清理临时文件
foreach($f in $tempList){
    if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
}
Write-Host "`n 已清理全部本地临时文件"
Write-Host "`n==== 全部任务执行完毕 ====" -ForegroundColor Green
