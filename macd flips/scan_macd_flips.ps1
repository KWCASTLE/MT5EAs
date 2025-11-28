param(
    [string]$Path = "wavecrest_debug_raw.txt"
)

if(-not (Test-Path $Path)) {
    Write-Error "File not found: $Path"
    exit 1
}

$macdRe = '^(?<ts>\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2}),MACD_DEBUG,(?<body>.*)$'
$decRe  = '^(?<ts>\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2}),DECISION_SUMMARY,(?<body>.*)$'
$kvRe = '([a-zA-Z_]+)=(-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)'

$lines = Get-Content -LiteralPath $Path -ErrorAction Stop

$decisionMap = @{}
foreach($line in $lines) {
    $m = [regex]::Match($line, $decRe)
    if($m.Success) {
        $decisionMap[$m.Groups['ts'].Value] = $m.Groups['body'].Value
    }
}

$candidates = @()

foreach($line in $lines) {
    $m = [regex]::Match($line, $macdRe)
    if(-not $m.Success) { continue }

    $ts = $m.Groups['ts'].Value
    $body = $m.Groups['body'].Value

    $kvMatches = [regex]::Matches($body, $kvRe)
    $map = @{}
    foreach($kv in $kvMatches) {
        $k = $kv.Groups[1].Value
        $v = [double]$kv.Groups[2].Value
        $map[$k] = $v
    }

    $required = @('main_prev','main_now','signal_prev','signal_now','hist_prev','hist_now')
    if( ($required | Where-Object { -not $map.ContainsKey($_) }) ) {
        continue
    }

    $mp = $map['main_prev']; $mn = $map['main_now']
    $sp = $map['signal_prev']; $sn = $map['signal_now']
    $histp = $map['hist_prev']; $histn = $map['hist_now']

    # BUY candidate: |main_prev| > |signal_prev| AND |signal_now| > |main_now|
    if( ([math]::Abs($mp) - [math]::Abs($sp)) -gt 0 -and ([math]::Abs($sn) - [math]::Abs($mn)) -gt 0 ) {
        $candidates += [pscustomobject]@{
            Timestamp = $ts
            Type = "BUY_CANDIDATE"
            main_prev = $mp
            signal_prev = $sp
            main_now = $mn
            signal_now = $sn
            hist_prev = $histp
            hist_now = $histn
            DECISION_SUMMARY = if($decisionMap.ContainsKey($ts)) { $decisionMap[$ts] } else { "<none at exact timestamp>" }
        }
        continue
    }
    # SELL candidate: |signal_prev| > |main_prev| AND |main_now| > |signal_now|
    if( ([math]::Abs($sp) - [math]::Abs($mp)) -gt 0 -and ([math]::Abs($mn) - [math]::Abs($sn)) -gt 0 ) {
        $candidates += [pscustomobject]@{
            Timestamp = $ts
            Type = "SELL_CANDIDATE"
            main_prev = $mp
            signal_prev = $sp
            main_now = $mn
            signal_now = $sn
            hist_prev = $histp
            hist_now = $histn
            DECISION_SUMMARY = if($decisionMap.ContainsKey($ts)) { $decisionMap[$ts] } else { "<none at exact timestamp>" }
        }
        continue
    }
}

if($candidates.Count -eq 0) {
    Write-Output "No candidate flips found."
    exit 0
}

foreach($c in $candidates) {
    Write-Output "-----"
    Write-Output "$($c.Timestamp)    $($c.Type)"
    Write-Output ("  main_prev = {0:N8}, signal_prev = {1:N8}, hist_prev = {2:N8}" -f $c.main_prev, $c.signal_prev, $c.hist_prev)
    Write-Output ("  main_now  = {0:N8}, signal_now  = {1:N8}, hist_now  = {2:N8}" -f $c.main_now, $c.signal_now, $c.hist_now)
    Write-Output "  DECISION_SUMMARY: $($c.DECISION_SUMMARY)"
}
Write-Output "-----"
Write-Output "Total candidates: $($candidates.Count)"