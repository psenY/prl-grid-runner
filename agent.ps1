# prl-agent.ps1 —— 放在你 Windows 电脑上的"手"（v3）
# 作用：每 20 秒按我下发的配置补挂网格单；触发停机线就撤单清仓；kill=true 就撤单退出。
# 你只需要做一次：在 PowerShell 里跑一行命令（我把那行给你），首次会让你填 SafeTrade 的
# API Key/Secret —— 只存在本机 %USERPROFILE%\.prl-agent\config.json，不会外传。
# 停止：Ctrl+C，或让我把配置里的 kill 设为 true。

$ErrorActionPreference = 'Stop'
$Base = 'https://safe.trade'
$Dir  = Join-Path $env:USERPROFILE '.prl-agent'
$CfgF = Join-Path $Dir 'config.json'
$StF  = Join-Path $Dir 'state.json'
$CchF = Join-Path $Dir 'config-cache.json'
$Log  = Join-Path $Dir 'agent.log'
$DefaultSrc = 'https://api.github.com/repos/psenY/prl-grid-runner/contents/config.json'
if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir | Out-Null }

function Say($m) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $m
  Write-Host $line
  Add-Content -Path $Log -Value $line -Encoding UTF8
}

if (-not (Test-Path $CfgF)) {
  Say '首次运行：请输入 SafeTrade API 信息（只存本机，不外传）'
  $key = (Read-Host 'API Key').Trim()
  $sec = (Read-Host 'API Secret').Trim()
  $px  = (Read-Host '代理地址（如果浏览器走代理而 PowerShell 不走，就填 http://127.0.0.1:7890；否则直接回车）').Trim()
  $src = (Read-Host '配置地址（直接回车用默认）').Trim()
  if (-not $src) { $src = $DefaultSrc }
  @{ apikey = $key; secret = $sec; srcUrl = $src } | ConvertTo-Json | Set-Content $CfgF -Encoding UTF8
  Say "已保存：$CfgF"
}
$conf = Get-Content $CfgF -Raw -Encoding UTF8 | ConvertFrom-Json
$apikey = $conf.apikey; $secret = $conf.secret; $srcUrl = $conf.srcUrl
if (-not (Test-Path $StF)) { @{ authScheme = '' } | ConvertTo-Json | Set-Content $StF -Encoding UTF8 }
$st = Get-Content $StF -Raw -Encoding UTF8 | ConvertFrom-Json
function Save-St { $st | ConvertTo-Json -Depth 6 | Set-Content $StF -Encoding UTF8 }

function Sign($nonce, $scheme) {
  $h = New-Object System.Security.Cryptography.HMACSHA256
  $h.Key = [Text.Encoding]::UTF8.GetBytes($secret)
  $msg = if ($scheme -eq 'B') { $apikey + $nonce } else { $nonce + $apikey }
  ($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($msg)) | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Api($method, $path, $bodyObj) {
  $nonce = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString()
  $scheme = if ($st.authScheme) { $st.authScheme } else { 'A' }
  $hdr = @{
    'X-Auth-Apikey' = $apikey; 'X-Auth-Nonce' = $nonce
    'X-Auth-Signature' = (Sign $nonce $scheme)
    'Accept' = 'application/json'; 'Content-Type' = 'application/json'
    'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36'
    'Referer' = 'https://safetrade.com/exchange/PRL-USDT'
  }
  try {
    if ($method -eq 'GET') { return Invoke-RestMethod -Method Get -Uri ($Base + $path) -Headers $hdr -TimeoutSec 20 @SP }
    $json = if ($bodyObj) { $bodyObj | ConvertTo-Json -Compress } else { '{}' }
    return Invoke-RestMethod -Method Post -Uri ($Base + $path) -Headers $hdr -Body $json -TimeoutSec 20
  } catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -eq 401 -and -not $st.authScheme) { $st.authScheme = 'B'; Save-St; Say '签名方案 A 被拒 → 切 B 重试'; return Api $method $path $bodyObj }
    throw
  }
}

function Inv($x) { ([double]$x).ToString([Globalization.CultureInfo]::InvariantCulture) }
function Waiting { return @(Api GET '/api/v2/peatio/market/orders?market=prlusdt&state=wait&limit=100') }
function Balances {
  $b = Api GET '/api/v2/peatio/account/balances'
  $t = @{ prl = 0.0; usdt = 0.0 }
  foreach ($row in $b) {
    if ($row.currency -eq 'prl')  { $t.prl  = [double]$row.balance }
    if ($row.currency -eq 'usdt') { $t.usdt = [double]$row.balance }
  }
  return $t
}
function Price {
  $t = Invoke-RestMethod -Uri "$Base/api/v2/peatio/public/markets/prlusdt/tickers" -TimeoutSec 20 @SP -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36'; 'Referer' = 'https://safetrade.com/exchange/PRL-USDT' }
  return [double]$t.ticker.last
}

function Fetch-Config {
  foreach ($u in @($srcUrl, 'https://raw.githubusercontent.com/psenY/prl-grid-runner/main/config.json', 'https://cdn.jsdelivr.net/gh/psenY/prl-grid-runner@main/config.json')) {
    try {
      $hdr = @{ 'Accept' = 'application/vnd.github.raw'; 'User-Agent' = 'prl-agent' }
      $raw = (Invoke-WebRequest -Uri $u -Headers $hdr -TimeoutSec 25 -UseBasicParsing @SP).Content
      $txt = $null
      if ($raw -match '^\s*\{' -and $raw -match '"content"\s*:') {
        $j = $raw | ConvertFrom-Json
        $txt = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($j.content -replace '\s', '')))
      } elseif ($raw -match '^\s*\{') {
        $txt = $raw
      } else {
        $i = $raw.IndexOf('{'); if ($i -ge 0) { $txt = $raw.Substring($i) }
      }
      if ($txt) { Set-Content -Path $CchF -Value $txt -Encoding UTF8; return ($txt | ConvertFrom-Json) }
    } catch { }
  }
  if (Test-Path $CchF) { Say '配置源不可达 → 用本机缓存配置'; return (Get-Content $CchF -Raw -Encoding UTF8 | ConvertFrom-Json) }
  throw '拿不到配置，且本机没有缓存'
}

Say '== 自检 =='
try { $b0 = Balances;  Say ("余额 PRL {0} / USDT {1}" -f $b0.prl, $b0.usdt) } catch { Say ("余额查询失败：{0}" -f $_.Exception.Message) }
try { $w0 = Waiting;   Say ("当前挂单 {0} 笔" -f $w0.Count) } catch { Say ("查挂单失败：{0}" -f $_.Exception.Message) }

Say "开始运行：挂单节奏 20 秒，配置每 60 秒刷新；配置源 $srcUrl"
$cyc = 0; $cfg = $null; $lastLog = ''
while ($true) {
  $cyc++
  if (-not $cfg -or ($cyc % 3 -eq 1)) {
    try { $cfg = Fetch-Config; if ($cyc -le 1) { Say ("配置已加载：{0} 档 / 停机线 {1}" -f $cfg.levels.Count, $cfg.stopPriceBelow) } } catch { Say ("配置获取失败：{0}" -f $_.Exception.Message) }
  }
  try {
    if ($cfg -and $cfg.kill) {
      Say '配置 kill=true → 撤销全部挂单并退出'
      foreach ($o in Waiting) { try { Api POST ("/api/v2/peatio/market/orders/{0}/cancel" -f $o.id) $null | Out-Null } catch {} }
      exit
    }
    $p = Price
    if ($cfg -and $cfg.stopPriceBelow -and $p -lt [double]$cfg.stopPriceBelow) {
      Say ("!! 触发停机线 {0}（现价 {1}）→ 撤单并市价清仓" -f $cfg.stopPriceBelow, $p)
      foreach ($o in Waiting) { try { Api POST ("/api/v2/peatio/market/orders/{0}/cancel" -f $o.id) $null | Out-Null } catch {} }
      $bb = Balances
      if ($bb.prl -gt 0) {
        Api POST '/api/v2/peatio/market/orders' @{ market = 'prlusdt'; side = 'sell'; volume = (Inv $bb.prl); ord_type = 'market' } | Out-Null
        Say ("已市价卖出 {0} PRL" -f $bb.prl)
      }
      Say '停机完成，进程退出'; exit
    }

    $wait = @(); try { $wait = Waiting } catch { }
    $b = Balances
    $placed = 0; $skipped = 0
    if ($cfg) {
      foreach ($lv in $cfg.levels) {
        $dup = $wait | Where-Object { $_.side -eq $lv.side -and [math]::Abs([double]$_.price - [double]$lv.price) -lt 0.00000001 }
        if ($dup) { $skipped++; continue }
        $usd = [double]$lv.price * [double]$lv.amount
        if ($cfg.maxOrderUsd -and $usd -gt [double]$cfg.maxOrderUsd) { Say ("拒绝档位 {0} {1}：{2:N1}U 超单笔上限" -f $lv.side, $lv.price, $usd); continue }
        if ($wait.Count -ge [int]$cfg.maxOpenOrders) { Say '挂单数已达上限，本轮不再补单'; break }
        if ($lv.side -eq 'sell' -and $b.prl -lt [double]$lv.amount) { Say ("跳过卖档 {0}：PRL 不足（{1:N2}）" -f $lv.price, $b.prl); continue }
        if ($lv.side -eq 'buy'  -and $b.usdt -lt $usd)            { Say ("跳过买档 {0}：USDT 不足（{1:N2}）" -f $lv.price, $b.usdt); continue }
        try {
          $r = Api POST '/api/v2/peatio/market/orders' @{ market = 'prlusdt'; side = $lv.side; volume = (Inv $lv.amount); price = (Inv $lv.price); ord_type = 'limit' }
          Say ("挂单 {0} {1} @{2} → id={3}" -f $lv.side, $lv.amount, $lv.price, $r.id)
          $placed++; $wait += $r
        } catch { Say ("挂单失败 {0} @{1}：{2}" -f $lv.side, $lv.price, $_.Exception.Message) }
      }
    }
    $msg = "价 {0} | PRL {1:N2} USDT {2:N2} | 挂单 {3} | 本轮新挂 {4} / 已存在 {5}" -f $p, $b.prl, $b.usdt, $wait.Count, $placed, $skipped
    if ($msg -ne $lastLog) { Say $msg; $lastLog = $msg }
  } catch { Say ("本轮异常：{0}" -f $_.Exception.Message) }
  Start-Sleep -Seconds 20
}
