param([string]$File = ".\wavecrest_debug_raw.txt")

if (-not (Test-Path $File)) {
    Write-Error "File not found: $File"
    exit 1
}

$macdRegex = '^([^,]+),MACD_DEBUG,(.*)$'
$sigPrev = 'signal_prev=([+\-0-9.eE]+)@'
$sigNow  = 'signal_now=([+\-0-9.eE]+)@'
$mainPrev= 'main_prev=([+\-0-9.eE]+)'
$mainNow = 'main_now=([+\-0-9.eE]+)'

$ln = 0
Get-Content -LiteralPath $File | ForEach-Object {
    $ln++
    $line = $_.Trim()
    $m = [regex]::Match($line, $macdRegex)
    if (-not $m.Success) { return }

    $ts = $m.Groups[1].Value
    $body = $m.Groups[2].Value

    $a = [regex]::Match($body, $sigPrev)
    $b = [regex]::Match($body, $sigNow)
    $c = [regex]::Match($body, $mainPrev)
    $d = [regex]::Match($body, $mainNow)
    if (-not ($a.Success -and $b.Success -and $c.Success -and $d.Success)) { return }

    try {
        $sp = [double]::Parse($a.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
        $sn = [double]::Parse($b.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
        $mp = [double]::Parse($c.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
        $mn = [double]::Parse($d.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return
    }

    $rawBuy  = ($sp -lt $mp) -and ($sn -gt $mn)
    $absBuy  = ([math]::Abs($sp) -lt [math]::Abs($mp)) -and ([math]::Abs($sn) -gt [math]::Abs($mn))
    $rawSell = ($sp -gt $mp) -and ($sn -lt $mn)
    $absSell = ([math]::Abs($sp) -gt [math]::Abs($mp)) -and ([math]::Abs($sn) -lt [math]::Abs($mn))

    if (($rawBuy -ne $absBuy) -or ($rawSell -ne $absSell)) {
        [PSCustomObject]@{
            Line = $ln
            Timestamp = $ts
            signal_prev = $sp
            main_prev   = $mp
            signal_now  = $sn
            main_now    = $mn
            rawBuy = $rawBuy
            absBuy = $absBuy
            rawSell = $rawSell
            absSell = $absSell
            LineText = $line
        }
    }
}