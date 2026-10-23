$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../lib/Energy.Core.ps1')
function Assert($Condition,$Message) { if(-not $Condition){throw $Message} }
Assert ([math]::Abs((Get-EnergyKwh 300 18000)-1.5) -lt 0.00000001) 'Conversion W/h a kWh'
$days=@{}
Add-EnergyInterval $days ([datetime]'2026-10-31T23:30:00') ([datetime]'2026-11-01T00:30:00') 100 200
Assert ($days.Count -eq 2) 'Separacion por dia y mes'
Assert ([math]::Abs($days['2026-10-31'].kWh-0.05) -lt 0.00000001) 'Energia antes de medianoche'
Assert ($days['2026-11-01'].clp -eq 10) 'Costo despues de medianoche'
Add-EnergyInterval $days ([datetime]'2026-11-01T01:00:00') ([datetime]'2026-11-01T02:00:00') 100 300
Assert ([math]::Abs($days['2026-11-01'].clp-40) -lt 0.00000001) 'Cambio de tarifa no retroactivo'
$rows=@(Get-EnergyRows $days)
Assert ($rows.Count -eq 2 -and $rows[0].Fecha -eq '2026-11-01') 'Filas para exportar ordenadas'
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('energia-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $path=Join-Path $tmp 'historial.json'
    Write-AtomicJson $path @{version=1;days=$days}
    $loaded=Read-EnergyHistory $path
    Assert ($loaded.Count -eq 2 -and $loaded['2026-11-01'].clp -eq 40) 'Persistencia de historial'
    Write-AtomicJson $path @{version=1;days=$days}
    Assert (Test-Path -LiteralPath ($path+'.bak')) 'Respaldo atomico'
    $loaded=Read-EnergyHistory ($path+'.bak')
    Assert ($loaded.Count -eq 2) 'Respaldo recuperable'
    $bad=Join-Path $tmp 'bad.json'
    [IO.File]::WriteAllText($bad,'{"version":1,"days":{"2026-10-22":{"seconds":-1,"kWh":1,"clp":1}}}')
    $rejected=$false; try { $null=Read-EnergyHistory $bad } catch { $rejected=$true }
    Assert $rejected 'Historial invalido debe rechazarse'
} finally {
    # Only known files created by this test are removed; no recursive deletion.
    foreach($file in @('historial.json','historial.json.bak','bad.json')) { $p=Join-Path $tmp $file; if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p} }
    Remove-Item -LiteralPath $tmp
}
Write-Output 'OK: conversion, medianoche, mes, tarifas, exportacion, persistencia, respaldo y validacion.'
