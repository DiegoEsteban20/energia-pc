#requires -Version 5.1
param([string]$DataDirectory, [switch]$SmokeTest, [string]$PreviewPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib/Energy.Core.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

# A form message runs on the UI thread; no cross-thread PowerShell event callbacks.
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class EnergyWindow : Form {
    public event EventHandler PowerTransition;
    [DllImport("kernel32.dll")] public static extern bool QueryUnbiasedInterruptTime(out ulong value);
    public static double AwakeSeconds() {
        ulong value; if (!QueryUnbiasedInterruptTime(out value)) throw new InvalidOperationException("No se pudo leer el reloj del sistema.");
        return value / 10000000.0;
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x218 && PowerTransition != null) PowerTransition(this, EventArgs.Empty);
        base.WndProc(ref m);
    }
}
'@
if (-not $DataDirectory) { $DataDirectory=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'EnergiaPC' }
$DataDirectory=[IO.Path]::GetFullPath($DataDirectory)
$mutexName='Local\EnergiaPCCommunity'
if ($SmokeTest) { $mutexName+='SmokeTest' }
$mutex=New-Object Threading.Mutex($false,$mutexName)
if (-not $mutex.WaitOne(0)) {
    [Windows.Forms.MessageBox]::Show('Energia PC ya esta abierto. Busca el icono junto al reloj; puede estar dentro de la flecha ^.','Energia PC') | Out-Null
    $mutex.Dispose(); exit
}

$script:tracking=$false; $script:exiting=$false; $script:dirty=$false; $script:days=@{}
$script:lastWall=Get-Date; $script:lastAwake=[EnergyWindow]::AwakeSeconds()
$script:active=$null; $script:notice=''; $script:lastError=''
$configPath=Join-Path $DataDirectory 'config.json'
$historyPath=Join-Path $DataDirectory 'historial.json'
$settings=@{name='Mi PC'; cpu=''; gpu=''; ram=16.0; pc=70.0; monitor=25.0; monitorOn=$true; rate=200.0; reviewed=$false}
try {
    New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
    if (Test-Path -LiteralPath $configPath) {
        try {
            $saved=Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            foreach ($key in @($settings.Keys)) { if ($null -ne $saved.$key) { $settings[$key]=$saved.$key } }
        } catch { $script:notice='No se pudo leer la configuracion. Revisa los valores antes de iniciar.' }
    }
    if (Test-Path -LiteralPath $historyPath) {
        try { $script:days=Read-EnergyHistory $historyPath }
        catch {
            if (Test-Path -LiteralPath ($historyPath+'.bak')) {
                $script:days=Read-EnergyHistory ($historyPath+'.bak')
                $stamp=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
                Copy-Item -LiteralPath $historyPath -Destination ($historyPath+'.corrupt-'+$stamp)
                Copy-Item -LiteralPath ($historyPath+'.bak') -Destination ($historyPath+'.recovered-'+$stamp)
                $script:notice='Se recupero la copia anterior del historial. Puede faltar el ultimo intervalo guardado.'
            } else { throw 'Historial ilegible sin respaldo. Conserva los archivos y revisalos antes de continuar.' }
        }
    }
} catch {
    [Windows.Forms.MessageBox]::Show($_.Exception.Message,'No se pudo abrir Energia PC') | Out-Null
    $mutex.ReleaseMutex(); $mutex.Dispose(); exit 1
}

$form=New-Object EnergyWindow
$form.Text='Energia PC | Consumo estimado en pesos chilenos'
$form.ClientSize=New-Object Drawing.Size(900,740)
$form.MinimumSize=New-Object Drawing.Size(780,650)
$form.StartPosition='CenterScreen'
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$form.BackColor=[Drawing.Color]::FromArgb(246,248,252)
$form.AutoScaleMode='Dpi'
$form.Icon=[Drawing.SystemIcons]::Information
$panel=New-Object Windows.Forms.TableLayoutPanel
$panel.Dock='Fill'; $panel.AutoScroll=$true; $panel.Padding=New-Object Windows.Forms.Padding(22)
$panel.ColumnCount=1; $panel.RowCount=10
$panel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100))) | Out-Null
$form.Controls.Add($panel)
function New-Label([string]$Text,[int]$Size=10,[bool]$Bold=$false) {
    $l=New-Object Windows.Forms.Label; $l.Text=$Text; $l.AutoSize=$true; $l.Margin=New-Object Windows.Forms.Padding(0,0,0,9)
    $style=[Drawing.FontStyle]::Regular; if($Bold){$style=[Drawing.FontStyle]::Bold}
    $l.Font=New-Object Drawing.Font('Segoe UI',$Size,$style); return $l
}
function New-Number([double]$Value,[double]$Maximum,[int]$Decimals=2) {
    $n=New-Object Windows.Forms.NumericUpDown; $n.Width=135; $n.Maximum=[decimal]$Maximum; $n.DecimalPlaces=$Decimals
    $n.Value=[decimal][math]::Max([double]0,[math]::Min($Maximum,$Value)); return $n
}
$panel.Controls.Add((New-Label 'Cuanto cuesta usar tu PC' 22 $true))
$panel.Controls.Add((New-Label "Configura tu equipo, revisa la tarifa y pulsa Iniciar. Se guardara el consumo estimado de cada dia.`nNo mide electricidad real: usa la potencia en watts que tu indiques."))
$tabs=New-Object Windows.Forms.TabControl; $tabs.Dock='Top'; $tabs.Height=230
$setup=New-Object Windows.Forms.TabPage; $setup.Text='1. Mi equipo y tarifa'; $setup.Padding=New-Object Windows.Forms.Padding(12)
$help=New-Object Windows.Forms.TabPage; $help.Text='2. Ayuda para completar los datos'; $help.Padding=New-Object Windows.Forms.Padding(12)
$tabs.TabPages.Add($setup); $tabs.TabPages.Add($help); $panel.Controls.Add($tabs)
$fields=New-Object Windows.Forms.TableLayoutPanel; $fields.Dock='Fill'; $fields.AutoScroll=$true; $fields.ColumnCount=4; $fields.RowCount=5
foreach ($width in @(155,230,145,220)) { $fields.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,$width))) | Out-Null }
$setup.Controls.Add($fields)
$name=New-Object Windows.Forms.TextBox; $name.Text=[string]$settings.name; $name.Width=210; $name.MaxLength=100
$cpu=New-Object Windows.Forms.TextBox; $cpu.Text=[string]$settings.cpu; $cpu.Width=210; $cpu.MaxLength=120
$gpu=New-Object Windows.Forms.TextBox; $gpu.Text=[string]$settings.gpu; $gpu.Width=210; $gpu.MaxLength=120
$ram=New-Number ([double]$settings.ram) 4096 0
$pc=New-Number ([double]$settings.pc) 10000
$monitor=New-Number ([double]$settings.monitor) 5000
$rate=New-Number ([double]$settings.rate) 100000
$monitorOn=New-Object Windows.Forms.CheckBox; $monitorOn.Text='Incluir monitor'; $monitorOn.AutoSize=$true; $monitorOn.Checked=[bool]$settings.monitorOn
function Add-Field($Text,$Control,$Col,$Row) { $fields.Controls.Add((New-Label $Text),$Col,$Row); $fields.Controls.Add($Control,($Col+1),$Row) }
Add-Field 'Nombre del equipo' $name 0 0
Add-Field 'Memoria RAM (GB)' $ram 2 0
Add-Field 'Procesador (opcional)' $cpu 0 1
Add-Field 'PC completo (W)' $pc 2 1
Add-Field 'Grafica (opcional)' $gpu 0 2
Add-Field 'Monitor(es) total (W)' $monitor 2 2
Add-Field 'Tarifa: pesos / kWh' $rate 0 3
$fields.Controls.Add($monitorOn,3,3)
$reviewed=New-Object Windows.Forms.CheckBox; $reviewed.Text='Revise los watts y la tarifa. Entiendo que el resultado es estimado.'; $reviewed.AutoSize=$true; $reviewed.Checked=[bool]$settings.reviewed
$fields.Controls.Add($reviewed,0,4); $fields.SetColumnSpan($reviewed,4)
$helpText=New-Object Windows.Forms.TextBox; $helpText.Multiline=$true; $helpText.ReadOnly=$true; $helpText.ScrollBars='Vertical'; $helpText.Dock='Fill'; $helpText.BackColor=[Drawing.Color]::White
$helpText.Text=@"
Nombre, procesador, grafica y RAM describen tu equipo. NO permiten calcular su consumo real por si solos. Si no sabes el modelo, deja los campos opcionales vacios.

PC completo (W): potencia media que quieres suponer para el equipo completo, incluida su fuente. El valor inicial de 70 W es solo un ejemplo. Una fuente de 500 W no consume siempre 500 W; tampoco uses el TDP del procesador como consumo total. Para obtener precision necesitas un medidor de enchufe.

Monitor (W): busca el consumo tipico de tu modelo. 25 W es un ejemplo. Suma los watts si tienes varios monitores. Desmarca Incluir monitor cuando no corresponda; el programa no detecta si se apaga solo.

Tarifa: precio de un kWh en pesos chilenos. El valor inicial de 200 es un EJEMPLO. Si tu cargo de electricidad consumida es 40.000 pesos por 200 kWh: 40.000 / 200 = 200 pesos/kWh. Ese cociente puede no incluir transporte u otros cargos variables ni todos los impuestos. Revisa tu boleta. No uses el total con deudas o cargos fijos para calcular el costo adicional exacto del PC.

Para cambiar potencia o tarifa mientras registra: Pausar, editar y volver a Iniciar. Los cambios solo afectan al consumo futuro.
"@
$help.Controls.Add($helpText)
$actions=New-Object Windows.Forms.FlowLayoutPanel; $actions.AutoSize=$true; $actions.Dock='Top'; $panel.Controls.Add($actions)
function New-Button($Text,$Width) { $b=New-Object Windows.Forms.Button; $b.Text=$Text; $b.Size=New-Object Drawing.Size($Width,38); $b.Margin=New-Object Windows.Forms.Padding(0,0,10,8); $actions.Controls.Add($b); return $b }
$start=New-Button 'Iniciar y ocultar' 180
$pause=New-Button 'Pausar' 100
$hide=New-Button 'Ocultar ventana' 155
$export=New-Button 'Exportar historial' 160
$state=New-Label 'En pausa. Completa los datos para comenzar.' 10 $true; $panel.Controls.Add($state)
$summary=New-Label '' 15 $true; $panel.Controls.Add($summary)
$projection=New-Label ''; $panel.Controls.Add($projection)
$hours=New-Number 8 24 1
$hoursRow=New-Object Windows.Forms.FlowLayoutPanel; $hoursRow.AutoSize=$true; $hoursRow.Dock='Top'
$hoursRow.Controls.Add((New-Label 'Simular horas de uso por dia:')); $hoursRow.Controls.Add($hours); $panel.Controls.Add($hoursRow)
$grid=New-Object Windows.Forms.DataGridView; $grid.Dock='Top'; $grid.Height=135; $grid.ReadOnly=$true; $grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false; $grid.RowHeadersVisible=$false; $grid.AutoSizeColumnsMode='Fill'; $grid.BackgroundColor=[Drawing.Color]::White
foreach ($heading in @('Fecha','Horas registradas','kWh estimados','Costo estimado CLP')) { [void]$grid.Columns.Add($heading,$heading) }
$panel.Controls.Add($grid)
$footer=New-Label "Al cerrar con X se oculta junto al reloj. Para detenerlo usa Pausar o Salir desde el icono.`nSolo registra mientras esta iniciado; no reconstruye el pasado ni el tiempo apagado."
$panel.Controls.Add($footer)

$menu=New-Object Windows.Forms.ContextMenuStrip
$openItem=$menu.Items.Add('Abrir ventana')
$pauseItem=$menu.Items.Add('Pausar registro')
$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator)) | Out-Null
$exitItem=$menu.Items.Add('Salir y detener')
$tray=New-Object Windows.Forms.NotifyIcon; $tray.Icon=[Drawing.SystemIcons]::Information; $tray.ContextMenuStrip=$menu; $tray.Text='Energia PC - En pausa'; $tray.Visible=$true
$culture=[Globalization.CultureInfo]::GetCultureInfo('es-CL')
function Money([double]$Value) { return $Value.ToString('C0',$culture) }
function Reset-Clock { $script:lastWall=Get-Date; $script:lastAwake=[EnergyWindow]::AwakeSeconds() }
function Get-FormSettings {
    return @{name=$name.Text.Trim(); cpu=$cpu.Text.Trim(); gpu=$gpu.Text.Trim(); ram=[double]$ram.Value; pc=[double]$pc.Value; monitor=[double]$monitor.Value; monitorOn=$monitorOn.Checked; rate=[double]$rate.Value; reviewed=$reviewed.Checked}
}
function Save-History { if ($script:dirty) { Write-AtomicJson $historyPath @{version=1; days=$script:days}; $script:dirty=$false } }
function Record-Now {
    $now=Get-Date; $awake=[EnergyWindow]::AwakeSeconds()
    $elapsed=($now-$script:lastWall).TotalSeconds; $awakeElapsed=$awake-$script:lastAwake
    if ($script:tracking -and $elapsed -gt 0 -and $elapsed -le 30 -and [math]::Abs($elapsed-$awakeElapsed) -lt 0.5) {
        Add-EnergyInterval $script:days $script:lastWall $now $script:active.watts $script:active.rate
        $script:dirty=$true
    }
    # Advance the cursor before attempting disk I/O to avoid counting an interval twice on retry.
    $script:lastWall=$now; $script:lastAwake=$awake
    Save-History
}
function Refresh-View {
    $today=(Get-Date).ToString('yyyy-MM-dd'); $month=(Get-Date).ToString('yyyy-MM')
    $dk=0.0; $dc=0.0; $mk=0.0; $mc=0.0
    foreach ($key in $script:days.Keys) {
        $d=$script:days[$key]
        if ($key -eq $today) { $dk=$d.kWh; $dc=$d.clp }
        if ($key.StartsWith($month)) { $mk += $d.kWh; $mc += $d.clp }
    }
    $summary.Text=('Hoy: {0} kWh | {1}    -    Mes acumulado: {2} kWh | {3}' -f $dk.ToString('N4',$culture),(Money $dc),$mk.ToString('N4',$culture),(Money $mc))
    $watts=[double]$pc.Value; if($monitorOn.Checked){$watts += [double]$monitor.Value}
    $estimate=Get-EnergyKwh $watts ([double]$hours.Value*3600)
    $projection.Text=('Simulacion: {0} W, {1} h/dia = {2}/dia y {3} en 30 dias. No es consumo registrado.' -f $watts,$hours.Value,(Money ($estimate*[double]$rate.Value)),(Money ($estimate*[double]$rate.Value*30)))
    $state.Text=if($script:tracking){'Registrando en segundo plano. Puedes ocultar esta ventana.'}else{'En pausa. No se esta acumulando consumo.'}
    if($script:notice){$state.Text += ' '+$script:notice}
    if($script:lastError){$state.Text='REGISTRO DETENIDO: '+$script:lastError}
    $tray.Text=if($script:tracking){'Energia PC - Registrando | Hoy '+(Money $dc)}else{'Energia PC - En pausa'}
    $pause.Enabled=$script:tracking; $pauseItem.Enabled=$script:tracking; $start.Enabled=-not $script:tracking; $setup.Enabled=-not $script:tracking
    if ($form.Visible -or $SmokeTest) {
        $grid.Rows.Clear()
        foreach ($row in @(Get-EnergyRows $script:days)) { [void]$grid.Rows.Add($row.Fecha,$row.Horas.ToString('N2',$culture),$row.kWh.ToString('N4',$culture),(Money $row.Costo_CLP)) }
    }
}
function Show-Window { $form.Show(); $form.ShowInTaskbar=$true; $form.WindowState='Normal'; $form.Activate(); Refresh-View }
function Notify-User($Text) { $tray.BalloonTipTitle='Energia PC'; $tray.BalloonTipText=$Text; $tray.ShowBalloonTip(4000) }
function Handle-Error($ErrorRecord) {
    $script:tracking=$false; $script:lastError=$ErrorRecord.Exception.Message; Reset-Clock; Refresh-View
    Notify-User ('Registro detenido: '+$script:lastError)
    Show-Window
}
function Tick { try { Record-Now; Refresh-View } catch { Handle-Error $_ } }
function Pause-Tracking { try { Record-Now; $script:tracking=$false; Reset-Clock; Refresh-View } catch { Handle-Error $_ } }
$start.Add_Click({
    try {
        $s=Get-FormSettings
        if (-not $s.name -or -not $s.reviewed -or $s.pc -le 0 -or $s.rate -le 0) {
            [Windows.Forms.MessageBox]::Show('Pon un nombre, una potencia del PC mayor que cero y una tarifa mayor que cero. Marca la casilla despues de revisar los valores.','Revisa tus datos') | Out-Null; return
        }
        Save-History
        Write-AtomicJson $configPath $s
        $w=$s.pc; if($s.monitorOn){$w += $s.monitor}
        $script:active=@{watts=$w; rate=$s.rate}; $script:lastError=''; Reset-Clock; $script:tracking=$true
        Refresh-View; $form.Hide(); $form.ShowInTaskbar=$false
        Notify-User 'Registro iniciado. Busca el icono junto al reloj (o dentro de ^). Doble clic para volver; clic derecho para pausar o salir.'
    } catch { Handle-Error $_ }
})
$pause.Add_Click({Pause-Tracking}); $pauseItem.Add_Click({Pause-Tracking})
$hide.Add_Click({$form.Hide(); $form.ShowInTaskbar=$false; Notify-User 'La ventana esta oculta. Abrela con doble clic en el icono junto al reloj.'})
$openItem.Add_Click({Show-Window}); $tray.Add_DoubleClick({Show-Window})
$exitItem.Add_Click({
    try { Record-Now; Write-AtomicJson $configPath (Get-FormSettings); $script:tracking=$false; $script:exiting=$true; $form.Close() }
    catch { Handle-Error $_ }
})
$hours.Add_ValueChanged({Refresh-View})
$export.Add_Click({
    try {
        Record-Now
        if ($script:days.Count -eq 0) { [Windows.Forms.MessageBox]::Show('Aun no hay consumo registrado para exportar.') | Out-Null; return }
        $dialog=New-Object Windows.Forms.SaveFileDialog; $dialog.Filter='CSV (*.csv)|*.csv'; $dialog.FileName='energia-diaria.csv'
        if ($dialog.ShowDialog() -eq 'OK') { Get-EnergyRows $script:days | Export-Csv -LiteralPath $dialog.FileName -NoTypeInformation -Delimiter ';' -Encoding UTF8; [Windows.Forms.MessageBox]::Show('Historial exportado. Puedes abrirlo con Excel o LibreOffice.') | Out-Null }
        $dialog.Dispose()
    } catch { Handle-Error $_ }
})
$form.Add_PowerTransition({Reset-Clock})
$form.Add_FormClosing({
    if (-not $script:exiting -and $_.CloseReason -eq [Windows.Forms.CloseReason]::UserClosing) {
        $_.Cancel=$true; $form.Hide(); $form.ShowInTaskbar=$false
        Notify-User 'Energia PC sigue abierto. Clic derecho en su icono y Salir y detener para cerrarlo.'
    } else { try { Record-Now; Write-AtomicJson $configPath (Get-FormSettings) } catch {} }
})
$timer=New-Object Windows.Forms.Timer; $timer.Interval=5000; $timer.Add_Tick({Tick}); $timer.Start()
if ($SmokeTest) {
    # Exercise the actual event handlers in an isolated data directory.
    $script:testStage=0
    $testTimer=New-Object Windows.Forms.Timer; $testTimer.Interval=1200
    $testTimer.Add_Tick({
        try {
            if ($script:testStage -eq 0) {
                $rate.Value=[decimal]214.82; $reviewed.Checked=$true
                Refresh-View; if ($PreviewPath) { $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height); $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height))); $bitmap.Save($PreviewPath); $bitmap.Dispose() }
                $start.PerformClick()
                if (-not $script:tracking -or $form.Visible -or -not $tray.Visible -or $form.ShowInTaskbar) { throw 'El inicio no oculto la ventana o no activo el registro.' }
                $script:testStage=1
            } else {
                Tick
                if ($script:days.Count -eq 0) { throw 'No se acumulo energia en segundo plano.' }
                Show-Window; $pause.PerformClick()
                if ($script:tracking -or -not $form.Visible) { throw 'No se pudo abrir/pausar.' }
                $loaded=Read-EnergyHistory $historyPath
                if ($loaded.Count -eq 0 -or $rate.Value -ne [decimal]214.82) { throw 'Fallo el guardado o los decimales.' }
                $testTimer.Stop(); Write-Output 'OK: inicio, ventana oculta, icono, registro, reapertura, pausa, persistencia y tarifa decimal.'
                $script:exiting=$true; $form.Close()
            }
        } catch { $testTimer.Stop(); $script:testFailure=$_.Exception.Message; $script:exiting=$true; $form.Close() }
    }); $testTimer.Start()
}
try { Refresh-View; [Windows.Forms.Application]::Run($form) }
finally { $timer.Dispose(); if($SmokeTest){$testTimer.Dispose()}; $tray.Visible=$false; $tray.Dispose(); $menu.Dispose(); $form.Dispose(); $mutex.ReleaseMutex(); $mutex.Dispose() }
if ($script:testFailure) { throw $script:testFailure }
