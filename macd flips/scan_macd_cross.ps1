param(
    [string]$File = ".\wavecrest_debug_raw.txt"
)

# Ensure file exists
if (-not (Test-Path $File)) {
    Write-Error "File not found: $File"
    exit 1
}

# Regex pieces
$macdLineRegex = '^([^,]+),MACD_DEBUG,(.*)$'
$sigPrevRegex  = 'signal_prev=([+\-0-9.eE]+)@'
$sigNowRegex   = 'signal_now=([+\-0-9.eE]+)@'
$mainPrevRegex = 'main_prev=([+\-0-9.eE]+)'
$mainNowRegex  = 'main_now=([+\-0-9.eE]+)'

$matches = @()
$lineNo = 0

Get-Content -LiteralPath $File | ForEach-Object {
    $lineNo++
    $line = $_.TrimEnd()
    $mLine = [regex]::Match($line, $macdLineRegex)
    if (-not $mLine.Success) { return }

    $timestamp = $mLine.Groups[1].Value.Trim()
    $body = $mLine.Groups[2].Value

    $mSP = [regex]::Match($body, $sigPrevRegex)
    $mSN = [regex]::Match($body, $sigNowRegex)
    $mMP = [regex]::Match($body, $mainPrevRegex)
    $mMN = [regex]::Match($body, $mainNowRegex)

    if ($mSP.Success -and $mSN.Success -and $mMP.Success -and $mMN.Success) {
        try {
            $sp = [double]::Parse($mSP.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture)
            $sn = [double]::Parse($mSN.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture)
            $mp = [double]::Parse($mMP.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture)
            $mn = [double]::Parse($mMN.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture)
        } catch {
            # skip unparsable numeric values
            return
        }

        # Condition: signal_prev < main_prev AND signal_now > main_now
        if ($sp -lt $mp -and $sn -gt $mn) {
            $matches += [pscustomobject]@{
                Line       = $lineNo
                Timestamp  = $timestamp
                signal_prev= $sp
                main_prev  = $mp
                signal_now = $sn
                main_now   = $mn
                FullLine   = $line
            }
        }
    }
}

if ($matches.Count -eq 0) {
    Write-Host "No MACD_DEBUG lines found matching: signal_prev < main_prev AND signal_now > main_now"
    exit 0
}

Write-Host "Found $($matches.Count) matching MACD_DEBUG lines:`n"
foreach ($r in $matches) {
    Write-Host "Line $($r.Line)  Timestamp: $($r.Timestamp)"
    Write-Host ("  signal_prev = {0}    main_prev = {1}" -f $r.signal_prev, $r.main_prev)
    Write-Host ("  signal_now  = {0}    main_now  = {1}" -f $r.signal_now, $r.main_now)
    Write-Host "  Full line:"
    Write-Host "    $($r.FullLine)"
    Write-Host ("-" * 80)
}

# Optional: save summary CSV next to the input file
$csvOut = [System.IO.Path]::ChangeExtension($File, ".matches.csv")
$matches | Select-Object Line,Timestamp,signal_prev,main_prev,signal_now,main_now | Export-Csv -Path $csvOut -NoTypeInformation -Encoding UTF8
Write-Host "Summary CSV written to: $csvOut"