function Get-EnergyKwh([double]$Watts, [double]$Seconds) {
    if ($Watts -lt 0 -or $Seconds -lt 0) { throw 'La potencia y el tiempo no pueden ser negativos.' }
    return $Watts * $Seconds / 3600000.0
}

function Add-EnergyInterval {
    param([hashtable]$Days, [datetime]$Start, [datetime]$End, [double]$Watts, [double]$Rate)
    if ($End -lt $Start -or $Rate -lt 0 -or $Watts -lt 0) { throw 'Intervalo o valores invalidos.' }
    while ($Start -lt $End) {
        $next=$Start.Date.AddDays(1)
        if ($next -gt $End) { $next=$End }
        $key=$Start.ToString('yyyy-MM-dd')
        if (-not $Days.ContainsKey($key)) { $Days[$key]=[pscustomobject]@{seconds=0.0; kWh=0.0; clp=0.0} }
        $seconds=($next-$Start).TotalSeconds
        $energy=Get-EnergyKwh $Watts $seconds
        $Days[$key].seconds += $seconds
        $Days[$key].kWh += $energy
        $Days[$key].clp += $energy*$Rate
        $Start=$next
    }
}

function Write-AtomicJson([string]$Path, $Value) {
    $tmp=$Path+'.tmp'
    $json=ConvertTo-Json -InputObject $Value -Depth 8
    [IO.File]::WriteAllText($tmp,$json,(New-Object Text.UTF8Encoding($false)))
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp,$Path,($Path+'.bak')) }
    else { [IO.File]::Move($tmp,$Path) }
}

function Read-EnergyHistory([string]$Path) {
    $days=@{}
    $raw=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($raw.version -ne 1 -or $null -eq $raw.days) { throw 'Formato de historial desconocido.' }
    foreach ($p in $raw.days.PSObject.Properties) {
        $date=[datetime]::MinValue
        if (-not [datetime]::TryParseExact($p.Name,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)) { throw 'Fecha invalida en historial.' }
        foreach ($field in @('seconds','kWh','clp')) {
            $v=$p.Value.$field
            if ($null -eq $v -or [double]$v -lt 0 -or [double]::IsNaN([double]$v) -or [double]::IsInfinity([double]$v)) { throw 'Valor invalido en historial.' }
        }
        $days[$p.Name]=[pscustomobject]@{seconds=[double]$p.Value.seconds; kWh=[double]$p.Value.kWh; clp=[double]$p.Value.clp}
    }
    return ,$days
}

function Get-EnergyRows([hashtable]$Days) {
    foreach ($key in ($Days.Keys | Sort-Object -Descending)) {
        $d=$Days[$key]
        [pscustomobject]@{Fecha=$key; Horas=[math]::Round($d.seconds/3600,4); kWh=[math]::Round($d.kWh,6); Costo_CLP=[math]::Round($d.clp,2); Tipo='Estimacion manual'}
    }
}
