# prl-agent.ps1 - my remote hands on your Windows PC (v5: ASCII-only, PS 5.1 safe)
# What it does: every 20s it reads the config I publish, then keeps the grid ladder filled;
# if price drops below the stop line it cancels everything, market-sells, and exits.
# You only do this once: run the one-liner in PowerShell, answer the prompts.
# API key/secret stay on this machine: %USERPROFILE%\.prl-agent\config.json
# Stop: Ctrl+C in the window, or set kill=true in my config.

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
  Say 'First run: enter SafeTrade API info (stored locally only).'
  $key = (Read-Host 'API Key').Trim()
  $sec = (Read-Host 'API Secret').Trim()
  $px  = (Read-Host 'Proxy (press Enter = auto-detect local proxy, or e.g. http://127.0.0.1:7890)').Trim()
  $src = (Read-Host 'Config URL (press Enter for default)').Trim()
  if (-not $src) { $src = $DefaultSrc }
  @{ apikey = $key; secret = $sec; srcUrl = $src; proxy = $px } | ConvertTo-Json | Set-Content $CfgF -Encoding UTF8
  Say ("Saved: " + $CfgF)
}

$conf = Get-Content $CfgF -Raw -Encoding UTF8 | ConvertFrom-Json
$apikey = $conf.apikey
$secret = $conf.secret
$srcUrl = $conf.srcUrl
$SP = @{}
if ($conf.proxy -and $conf.proxy.Trim() -ne '') {
  $SP['Proxy'] = $conf.proxy.Trim(); Say ("Using proxy: " + $conf.proxy.Trim())
} else {
  Say 'No proxy in config -> auto-detecting local proxy...'
  $found = Find-Proxy
  if ($found) { $SP['Proxy'] = $found; $conf.proxy = $found; $conf | ConvertTo-Json | Set-Content $CfgF -Encoding UTF8 }
}

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
    'X-Auth-Apikey'    = $apikey
    'X-Auth-Nonce'     = $nonce
    'X-Auth-Signature' = (Sign $nonce $scheme)
    'Accept'           = 'application/json'
    'Content-Type'     = 'application/json'
    'User-Agent'       = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36'
    'Referer'          = 'https://safetrade.com/exchange/PRL-USDT'
  }
  try {
    if ($method -eq 'GET') { return Invoke-RestMethod -Method Get -Uri ($Base + $path) -Headers $hdr -TimeoutSec 20 @SP }
    $json = if ($bodyObj) { $bodyObj | ConvertTo-Json -Compress } else { '{}' }
    return Invoke-RestMethod -Method Post -Uri ($Base + $path) -Headers $hdr -Body $json -TimeoutSec 20 @SP
  } catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -eq 401 -and -not $st.authScheme) { $st.authScheme = 'B'; Save-St; Say 'Signature scheme A rejected -> retry with B'; return Api $method $path $bodyObj }
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
  $h = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36'; 'Referer' = 'https://safetrade.com/exchange/PRL-USDT' }
  $t = Invoke-RestMethod -Uri "$Base/api/v2/peatio/public/markets/prlusdt/tickers" -TimeoutSec 20 -Headers $h @SP
  return [double]$t.ticker.last
}

function Find-Proxy {
  # Auto-detect a local HTTP proxy that can actually reach the exchange (Clash/v2rayN/etc.)
  $cands = @(7890,7897,10809,10808,1080,8888,8889,8080,8118,20171,33210)
  foreach ($p in $cands) {
    $u = "http://127.0.0.1:$p"
    try {
      $t = Invoke-RestMethod -Proxy $u -TimeoutSec 6 -Uri ($Base + '/api/v2/peatio/public/markets/prlusdt/tickers')
      if ($t.ticker.last) { Say ("Proxy FOUND: $u (PRL " + $t.ticker.last + ")"); return $u }
    } catch { Say ("  port $p : " + $_.Exception.Message) }
  }
  Say 'No working local proxy found on common ports.'
  return $null
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
  if (Test-Path $CchF) { Say 'Config source unreachable -> using local cache'; return (Get-Content $CchF -Raw -Encoding UTF8 | ConvertFrom-Json) }
  throw 'Cannot fetch config and no local cache'
}

Say '== SELF TEST =='
try { $b0 = Balances; Say ("Balances: PRL {0} / USDT {1}" -f $b0.prl, $b0.usdt) } catch { Say ("Balance check FAILED: {0}" -f $_.Exception.Message) }
try { $w0 = Waiting;  Say ("Open orders: {0}" -f $w0.Count) } catch { Say ("Open order check FAILED: {0}" -f $_.Exception.Message) }

Say "Running: orders every 20s, config every 60s; source $srcUrl"
$cyc = 0; $cfg = $null; $lastLog = ''
while ($true) {
  $cyc++
  if (-not $cfg -or ($cyc % 3 -eq 1)) {
    try {
      $cfg = Fetch-Config
      if ($cyc -le 1 -and $cfg) { Say ("Config loaded: {0} levels / stop {1}" -f $cfg.levels.Count, $cfg.stopPriceBelow) }
    } catch { Say ("Config fetch failed: {0}" -f $_.Exception.Message) }
  }
  try {
    if ($cfg -and $cfg.kill) {
      Say 'kill=true -> cancel all orders and exit'
      foreach ($o in Waiting) { try { Api POST ("/api/v2/peatio/market/orders/{0}/cancel" -f $o.id) $null | Out-Null } catch {} }
      exit
    }
    $p = Price
    if ($cfg -and $cfg.stopPriceBelow -and $p -lt [double]$cfg.stopPriceBelow) {
      Say ("!! STOP LINE {0} hit (price {1}) -> cancel all, market sell, exit" -f $cfg.stopPriceBelow, $p)
      foreach ($o in Waiting) { try { Api POST ("/api/v2/peatio/market/orders/{0}/cancel" -f $o.id) $null | Out-Null } catch {} }
      $bb = Balances
      if ($bb.prl -gt 0) {
        Api POST '/api/v2/peatio/market/orders' @{ market = 'prlusdt'; side = 'sell'; volume = (Inv $bb.prl); ord_type = 'market' } | Out-Null
        Say ("Market sold {0} PRL" -f $bb.prl)
      }
      Say 'Stopped.'; exit
    }

    $wait = @(); try { $wait = Waiting } catch { }
    $b = Balances
    $placed = 0; $skipped = 0
    if ($cfg) {
      foreach ($lv in $cfg.levels) {
        $dup = $wait | Where-Object { $_.side -eq $lv.side -and [math]::Abs([double]$_.price - [double]$lv.price) -lt 0.00000001 }
        if ($dup) { $skipped++; continue }
        $usd = [double]$lv.price * [double]$lv.amount
        if ($cfg.maxOrderUsd -and $usd -gt [double]$cfg.maxOrderUsd) { Say ("Skip {0} {1}: {2:N1}U exceeds max per order" -f $lv.side, $lv.price, $usd); continue }
        if ($wait.Count -ge [int]$cfg.maxOpenOrders) { Say 'Max open orders reached; no new placement this cycle'; break }
        if ($lv.side -eq 'sell' -and $b.prl -lt [double]$lv.amount) { Say ("Skip sell {0}: PRL too low ({1:N2})" -f $lv.price, $b.prl); continue }
        if ($lv.side -eq 'buy'  -and $b.usdt -lt $usd)            { Say ("Skip buy {0}: USDT too low ({1:N2})" -f $lv.price, $b.usdt); continue }
        try {
          $r = Api POST '/api/v2/peatio/market/orders' @{ market = 'prlusdt'; side = $lv.side; volume = (Inv $lv.amount); price = (Inv $lv.price); ord_type = 'limit' }
          Say ("Placed {0} {1} @{2} -> id={3}" -f $lv.side, $lv.amount, $lv.price, $r.id)
          $placed++; $wait += $r
        } catch { Say ("Place failed {0} @{1}: {2}" -f $lv.side, $lv.price, $_.Exception.Message) }
      }
    }
    $msg = "price {0} | PRL {1:N2} USDT {2:N2} | open {3} | new {4} / existing {5}" -f $p, $b.prl, $b.usdt, $wait.Count, $placed, $skipped
    if ($msg -ne $lastLog) { Say $msg; $lastLog = $msg }
  } catch { Say ("Cycle error: {0}" -f $_.Exception.Message) }
  Start-Sleep -Seconds 20
}
