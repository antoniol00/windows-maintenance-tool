<#
.SYNOPSIS
    Mantenimiento a demanda de Windows 11 con barra de progreso.

.DESCRIPTION
    Ejecuta, en orden, estos pasos (todos opcionales):

      RestorePoint   Crea un punto de restauración del sistema antes de tocar nada.
      Temp           Borra archivos temporales (%TEMP% del usuario y C:\Windows\Temp).
      CleanMgr       Lanza el Liberador de espacio en disco (cleanmgr) de forma desatendida.
      DISM           Repara la imagen de Windows (RestoreHealth) y limpia el almacén de componentes.
      SFC            Comprueba y repara los archivos del sistema (sfc /scannow).
      WindowsUpdate  Busca, descarga e instala actualizaciones de Windows.
      Winget         Actualiza las aplicaciones instaladas con winget.
      Defender       Actualiza las firmas de Microsoft Defender y hace un análisis rápido.
      Optimize       Optimiza las unidades (TRIM en SSD, desfragmentación en HDD).

    Si no se ejecuta como administrador, se vuelve a lanzar elevado automáticamente.
    Todo queda registrado en la carpeta .\logs junto al script.

.PARAMETER Only
    Ejecuta solo los pasos indicados. Ej.: -Only Temp,Winget

.PARAMETER Skip
    Omite los pasos indicados. Ej.: -Skip SFC,Optimize

.PARAMETER TempOlderThanDays
    Solo borra temporales con más de N días de antigüedad (por defecto 1). 0 = todos.

.PARAMETER WingetExclude
    Ids de winget que no se deben actualizar. Ej.: -WingetExclude Microsoft.Edge,Adobe.Acrobat.Pro

.PARAMETER Reboot
    Reinicia automáticamente al terminar si hace falta.

.PARAMETER NoPause
    No espera a que se pulse Enter al terminar (útil para tareas programadas).

.EXAMPLE
    .\Invoke-WindowsMaintenance.ps1

.EXAMPLE
    .\Invoke-WindowsMaintenance.ps1 -Only Temp,CleanMgr

.EXAMPLE
    .\Invoke-WindowsMaintenance.ps1 -Skip WindowsUpdate -WingetExclude Microsoft.Edge
#>
[CmdletBinding()]
param(
    [string[]]$Only = @(),
    [string[]]$Skip = @(),
    [ValidateRange(0, 3650)]
    [int]$TempOlderThanDays = 1,
    [string[]]$WingetExclude = @(),
    [switch]$Reboot,
    [switch]$NoPause
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Continue'

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------

# Categorías del Liberador de espacio que NO se limpian (nombres de las claves en
# HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches).
# Quita 'Recycle Bin' de la lista si quieres que también vacíe la papelera.
$CleanMgrExclude = @(
    'DownloadsFolder'                  # Tu carpeta de Descargas
    'Recycle Bin'                      # Papelera de reciclaje
    'Previous Installations'           # Windows.old (permite volver a la versión anterior)
    'Windows ESD installation files'   # Necesarios para "Restablecer este PC"
    'User file versions'               # Versiones anteriores del Historial de archivos
)
$CleanMgrProfile = 777   # número de perfil para cleanmgr /sageset /sagerun

$AllSteps = @('RestorePoint', 'Temp', 'CleanMgr', 'DISM', 'SFC', 'WindowsUpdate', 'Winget', 'Defender', 'Optimize')

# ---------------------------------------------------------------------------
# Parámetros y elevación
# ---------------------------------------------------------------------------

# Con "powershell -File" las listas llegan como un único texto "A,B": se separan aquí.
function Split-List([string[]]$Value) {
    @($Value | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })
}

# @() evita que una lista vacía se convierta en $null (StrictMode no permite $null.Count).
$Only = @(Split-List $Only)
$Skip = @(Split-List $Skip)
$WingetExclude = @(Split-List $WingetExclude)

foreach ($name in $Only + $Skip) {
    if ($AllSteps -notcontains $name) {
        Write-Host "Paso desconocido: '$name'. Valores válidos: $($AllSteps -join ', ')" -ForegroundColor Red
        exit 1
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host 'Se necesitan permisos de administrador. Solicitando elevación...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($param in $PSBoundParameters.GetEnumerator()) {
        if ($param.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($param.Value.IsPresent) { $argList += "-$($param.Key)" }
        }
        elseif ($param.Value -is [array]) {
            if ($param.Value.Count) { $argList += "-$($param.Key)", "`"$($param.Value -join ',')`"" }
        }
        else {
            $argList += "-$($param.Key)", "`"$($param.Value)`""
        }
    }
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argList
    }
    catch {
        Write-Host 'No se concedieron permisos de administrador. Saliendo.' -ForegroundColor Red
        exit 1
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Registro y utilidades
# ---------------------------------------------------------------------------

$LogDir = Join-Path $PSScriptRoot 'logs'
try { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
catch { $LogDir = $env:ProgramData }
$LogFile = Join-Path $LogDir ('mantenimiento_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))

function Write-Log {
    param(
        [string]$Message = '',
        [ValidateSet('Info', 'Ok', 'Warn', 'Error', 'Title', 'Detail')]
        [string]$Level = 'Info',
        [switch]$LogOnly
    )
    try { Add-Content -LiteralPath $LogFile -Value ('[{0:HH:mm:ss}] [{1}] {2}' -f (Get-Date), $Level, $Message) -Encoding UTF8 } catch { }
    if (-not $LogOnly) {
        $color = switch ($Level) {
            'Ok'     { 'Green' }
            'Warn'   { 'Yellow' }
            'Error'  { 'Red' }
            'Title'  { 'Cyan' }
            'Detail' { 'DarkGray' }
            default  { 'Gray' }
        }
        Write-Host $Message -ForegroundColor $color
    }
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return '{0:N0} B' -f $Bytes
}

function Format-Elapsed([TimeSpan]$Span) { '{0:hh\:mm\:ss}' -f $Span }

function Get-FreeSpace { (New-Object System.IO.DriveInfo $env:SystemDrive).AvailableFreeSpace }

function New-StepResult {
    param(
        [ValidateSet('OK', 'Aviso', 'Error', 'Omitido')][string]$State,
        [string]$Detail = ''
    )
    [pscustomobject]@{ IsStepResult = $true; State = $State; Detail = $Detail }
}

# Quita las líneas de progreso que los programas reescriben con \r y las líneas vacías.
function ConvertTo-CleanLines([string]$Text) {
    @($Text -split "`r?`n" |
        ForEach-Object { ($_ -split "`r")[-1].TrimEnd() } |
        Where-Object { $_ -match '\w' })
}

# Últimas líneas "de mensaje" (sin barras de progreso ni porcentajes) de una salida.
function Get-LastMessages([string]$Text, [int]$Count = 2) {
    @(ConvertTo-CleanLines $Text | Where-Object { $_ -notmatch '%' } | Select-Object -Last $Count)
}

function Get-System32Path {
    # Un PowerShell de 32 bits en Windows de 64 bits no ve el System32 real.
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        return Join-Path $env:windir 'Sysnative'
    }
    Join-Path $env:windir 'System32'
}

function Test-PendingReboot {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($key in $keys) { if (Test-Path $key) { return $true } }
    return $false
}

# ---------------------------------------------------------------------------
# Barra de progreso (Id 1 = global, Id 2 = paso actual)
# ---------------------------------------------------------------------------

$Run = @{
    Clock       = [Diagnostics.Stopwatch]::StartNew()
    TotalWeight = 1
    DoneWeight  = 0
    StepIndex   = 0
    StepCount   = 0
    StepWeight  = 0
    StepName    = 'Preparando'
    RebootFlag  = $false
}

function Set-StepProgress {
    param(
        [int]$Percent = -1,
        [string]$Status = 'Trabajando...'
    )
    $fraction = if ($Percent -ge 0) { [Math]::Min(100, $Percent) / 100 } else { 0 }
    $overall = [int][Math]::Min(100, ($Run.DoneWeight + $Run.StepWeight * $fraction) / $Run.TotalWeight * 100)

    Write-Progress -Id 1 -Activity 'Mantenimiento de Windows' `
        -Status ('Paso {0} de {1}: {2}  |  {3}% total  |  {4}' -f $Run.StepIndex, $Run.StepCount, $Run.StepName, $overall, (Format-Elapsed $Run.Clock.Elapsed)) `
        -PercentComplete $overall

    if (-not $Status) { $Status = 'Trabajando...' }
    $child = @{ Id = 2; ParentId = 1; Activity = $Run.StepName; Status = $Status }
    if ($Percent -ge 0) { $child.PercentComplete = [Math]::Min(100, $Percent) }
    Write-Progress @child
}

# Ejecuta un programa de consola capturando su salida y leyendo el porcentaje que
# imprime (DISM, SFC, winget...) para reflejarlo en la barra del paso.
#   -RangeStart/-RangeEnd: qué tramo de la barra del paso ocupa esta ejecución.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [System.Text.Encoding]$Encoding = [System.Text.Encoding]::UTF8,
        [string]$Status = 'Ejecutando...',
        [int]$RangeStart = 0,
        [int]$RangeEnd = 100,
        [switch]$TrackPercent
    )
    Write-Log "> $FilePath $Arguments" -Level Detail -LogOnly

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Encoding
    $psi.StandardErrorEncoding = $Encoding

    $proc = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $output = New-Object System.Text.StringBuilder
    $buffer = New-Object char[] 2048
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $percent = -1
    $lastDraw = -1L

    $readTask = $proc.StandardOutput.ReadAsync($buffer, 0, $buffer.Length)
    while ($true) {
        if ($readTask.Wait(250)) {
            $read = $readTask.Result
            if ($read -le 0) { break }
            [void]$output.Append($buffer, 0, $read)
            if ($TrackPercent) {
                $start = [Math]::Max(0, $output.Length - 160)
                $tail = $output.ToString($start, $output.Length - $start)
                $found = [regex]::Matches($tail, '(\d{1,3})(?:[.,]\d+)?\s*%')
                if ($found.Count) {
                    $value = [int]$found[$found.Count - 1].Groups[1].Value
                    if ($value -le 100) { $percent = $value }
                }
            }
            $readTask = $proc.StandardOutput.ReadAsync($buffer, 0, $buffer.Length)
        }
        if ($clock.ElapsedMilliseconds - $lastDraw -ge 500) {
            $lastDraw = $clock.ElapsedMilliseconds
            $text = $Status
            if ($percent -ge 0) { $text += " $percent%" }
            $text += "  ($(Format-Elapsed $clock.Elapsed))"
            $scaled = if ($percent -ge 0) { $RangeStart + ($RangeEnd - $RangeStart) * $percent / 100 } else { $RangeStart }
            Set-StepProgress -Percent $scaled -Status $text
        }
    }
    $proc.WaitForExit()
    $stdErr = $errTask.Result
    $text = $output.ToString()

    $clean = @(ConvertTo-CleanLines ($text + "`n" + $stdErr))
    if ($clean.Count) { Add-Content -LiteralPath $LogFile -Value ($clean | ForEach-Object { "    $_" }) -Encoding UTF8 -ErrorAction SilentlyContinue }
    Write-Log ("< código de salida {0} ({1})" -f $proc.ExitCode, (Format-Elapsed $clock.Elapsed)) -Level Detail -LogOnly

    [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = $text; StdErr = $stdErr }
}

# Espera a un trabajo en segundo plano (-AsJob) mostrando el tiempo y, si el
# trabajo informa de su progreso, también el porcentaje.
function Wait-JobWithProgress {
    param(
        [Parameter(Mandatory)]$Job,
        [string]$Status = 'Trabajando...',
        [int]$RangeStart = 0,
        [int]$RangeEnd = 100
    )
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($Job.State -in 'NotStarted', 'Running') {
        $percent = -1
        foreach ($child in $Job.ChildJobs) {
            $last = $child.Progress | Select-Object -Last 1
            if ($last -and $last.PercentComplete -ge 0) { $percent = $last.PercentComplete }
        }
        $text = $Status
        if ($percent -ge 0) { $text += " $percent%" }
        $scaled = if ($percent -ge 0) { $RangeStart + ($RangeEnd - $RangeStart) * $percent / 100 } else { $RangeStart }
        Set-StepProgress -Percent $scaled -Status "$text  ($(Format-Elapsed $clock.Elapsed))"
        Start-Sleep -Milliseconds 500
    }
    $jobErrors = @()
    $result = Receive-Job -Job $Job -ErrorAction SilentlyContinue -ErrorVariable jobErrors
    $failed = $Job.State -eq 'Failed'
    Remove-Job -Job $Job -Force
    [pscustomobject]@{ Output = $result; Errors = $jobErrors; Failed = $failed }
}

# ---------------------------------------------------------------------------
# Pasos
# ---------------------------------------------------------------------------

function Step-RestorePoint {
    Set-StepProgress -Percent 10 -Status 'Creando punto de restauración (puede tardar un minuto)...'
    $getLatest = {
        Get-CimInstance -Namespace root/default -ClassName SystemRestore -ErrorAction SilentlyContinue |
            Sort-Object SequenceNumber | Select-Object -Last 1
    }
    $before = & $getLatest
    $hint = '¿Está activada la Protección del sistema en {0}?' -f $env:SystemDrive
    try {
        $call = Invoke-CimMethod -Namespace root/default -ClassName SystemRestore -MethodName CreateRestorePoint -Arguments @{
            Description      = 'Mantenimiento {0:yyyy-MM-dd HH:mm}' -f (Get-Date)
            RestorePointType = [uint32]12    # MODIFY_SETTINGS
            EventType        = [uint32]100   # BEGIN_SYSTEM_CHANGE
        }
    }
    catch { return New-StepResult Aviso "No se pudo crear: $($_.Exception.Message) $hint" }
    $after = & $getLatest

    if ($call.ReturnValue -ne 0) {
        return New-StepResult Aviso ("No se pudo crear (código {0}). {1}" -f $call.ReturnValue, $hint)
    }
    if ($after -and (-not $before -or $after.SequenceNumber -gt $before.SequenceNumber)) {
        return New-StepResult OK "Creado: $($after.Description)"
    }
    New-StepResult Aviso 'No se creó uno nuevo: Windows solo permite uno cada 24 h (ya existe uno reciente).'
}

function Step-Temp {
    $cutoff = (Get-Date).AddDays(-$TempOlderThanDays)
    $roots = @([IO.Path]::GetTempPath(), (Join-Path $env:windir 'Temp')) |
        ForEach-Object { $_.TrimEnd('\') } | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ }

    # 1) Inventario (sin seguir enlaces simbólicos ni uniones).
    Set-StepProgress -Percent 0 -Status 'Analizando carpetas temporales...'
    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $dirs = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
    foreach ($root in $roots) {
        $pending = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
        $pending.Push((New-Object System.IO.DirectoryInfo $root))
        while ($pending.Count) {
            $dir = $pending.Pop()
            try { $entries = $dir.GetFileSystemInfos() } catch { continue }
            foreach ($entry in $entries) {
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($entry -is [IO.DirectoryInfo]) {
                    $pending.Push($entry)
                    if ($entry.LastWriteTime -lt $cutoff) { $dirs.Add($entry) }
                }
                elseif ($entry.LastWriteTime -lt $cutoff) {
                    $files.Add($entry)
                }
            }
        }
    }
    Write-Log ("Carpetas: {0}" -f ($roots -join ' | ')) -Level Detail
    Write-Log ("Encontrados {0} archivos con más de {1} día(s)" -f $files.Count, $TempOlderThanDays) -Level Detail

    # 2) Borrado de archivos.
    $deleted = 0; $failed = 0; [long]$freed = 0
    for ($i = 0; $i -lt $files.Count; $i++) {
        $file = $files[$i]
        try {
            $size = $file.Length
            if ($file.IsReadOnly) { $file.IsReadOnly = $false }
            $file.Delete()
            $deleted++; $freed += $size
        }
        catch { $failed++ }
        if ($i % 200 -eq 0) {
            Set-StepProgress -Percent (5 + 90 * $i / $files.Count) -Status ("Borrando {0} de {1}  ({2} liberados)" -f $i, $files.Count, (Format-Size $freed))
        }
    }

    # 3) Carpetas que se han quedado vacías (de la más profunda a la menos).
    Set-StepProgress -Percent 97 -Status 'Eliminando carpetas vacías...'
    $removedDirs = 0
    foreach ($dir in ($dirs | Sort-Object { $_.FullName.Length } -Descending)) {
        try { $dir.Delete($false); $removedDirs++ } catch { }
    }

    $detail = '{0} archivos y {1} carpetas eliminados, {2} liberados' -f $deleted, $removedDirs, (Format-Size $freed)
    if ($failed) { $detail += " ($failed en uso, omitidos)" }
    New-StepResult OK $detail
}

function Step-CleanMgr {
    $cleanmgr = Join-Path (Get-System32Path) 'cleanmgr.exe'
    if (-not (Test-Path $cleanmgr)) { return New-StepResult Omitido 'cleanmgr.exe no está disponible en este equipo.' }

    Set-StepProgress -Percent 0 -Status 'Configurando categorías a limpiar...'
    $flag = 'StateFlags{0:D4}' -f $CleanMgrProfile
    $base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    $enabled = @()
    foreach ($key in Get-ChildItem -Path $base) {
        if ($CleanMgrExclude -contains $key.PSChildName) {
            Remove-ItemProperty -Path $key.PSPath -Name $flag -ErrorAction SilentlyContinue
        }
        else {
            New-ItemProperty -Path $key.PSPath -Name $flag -Value 2 -PropertyType DWord -Force | Out-Null
            $enabled += $key.PSChildName
        }
    }
    Write-Log ("Categorías: {0}" -f ($enabled -join ', ')) -Level Detail -LogOnly

    $freeBefore = Get-FreeSpace
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Start-Process -FilePath $cleanmgr -ArgumentList "/sagerun:$CleanMgrProfile" -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 2
    # cleanmgr puede delegar en procesos hijos: se espera a que no quede ninguno.
    while (Get-Process -Name cleanmgr, cleanmgrhost -ErrorAction SilentlyContinue) {
        Set-StepProgress -Status ("Liberando espacio ({0} categorías, la limpieza de Windows Update puede tardar)  ({1})" -f $enabled.Count, (Format-Elapsed $clock.Elapsed))
        Start-Sleep -Seconds 1
    }
    $gain = (Get-FreeSpace) - $freeBefore
    New-StepResult OK ("{0} categorías limpiadas, ~{1} liberados" -f $enabled.Count, (Format-Size ([Math]::Max(0, $gain))))
}

function Step-DISM {
    $dism = Join-Path (Get-System32Path) 'dism.exe'
    $oem = [System.Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)

    $repair = Invoke-Native -FilePath $dism -Arguments '/Online /Cleanup-Image /RestoreHealth' -Encoding $oem -TrackPercent `
        -Status 'Reparando imagen (RestoreHealth, a veces se para un rato en un %, es normal)' -RangeStart 0 -RangeEnd 70
    foreach ($line in Get-LastMessages $repair.Output) { Write-Log "  $line" -Level Detail }

    $cleanup = Invoke-Native -FilePath $dism -Arguments '/Online /Cleanup-Image /StartComponentCleanup' -Encoding $oem -TrackPercent `
        -Status 'Limpiando almacén de componentes (WinSxS)' -RangeStart 70 -RangeEnd 100
    foreach ($line in Get-LastMessages $cleanup.Output) { Write-Log "  $line" -Level Detail }

    $okCodes = 0, 3010
    if ($okCodes -notcontains $repair.ExitCode) {
        return New-StepResult Error ('RestoreHealth falló con código 0x{0:X8}. Revisa C:\Windows\Logs\DISM\dism.log' -f $repair.ExitCode)
    }
    if ($repair.ExitCode -eq 3010 -or $cleanup.ExitCode -eq 3010) { $Run.RebootFlag = $true }
    if ($okCodes -notcontains $cleanup.ExitCode) {
        return New-StepResult Aviso ('Imagen reparada/correcta, pero la limpieza de componentes devolvió 0x{0:X8}' -f $cleanup.ExitCode)
    }
    New-StepResult OK 'Imagen comprobada y almacén de componentes limpio'
}

function Step-SFC {
    $sfc = Join-Path (Get-System32Path) 'sfc.exe'
    # sfc escribe en UTF-16 cuando su salida está redirigida.
    $scan = Invoke-Native -FilePath $sfc -Arguments '/scannow' -Encoding ([System.Text.Encoding]::Unicode) -TrackPercent `
        -Status 'Comprobando archivos del sistema'
    $messages = @(Get-LastMessages $scan.Output 3)
    foreach ($line in $messages) { Write-Log "  $line" -Level Detail }

    $summary = $messages | Where-Object { $_ -match 'Protecci|Resource Protection' } | Select-Object -First 1
    if (-not $summary) { $summary = $messages | Select-Object -Last 1 }
    if (-not $summary) { $summary = "Terminado con código $($scan.ExitCode)" }
    $joined = $messages -join ' '
    if ($joined -match 'no pudo|unable to|could not|no se pudo') { return New-StepResult Error $summary }
    if ($joined -match 'repar|repaired') { return New-StepResult Aviso $summary }
    if ($scan.ExitCode -ne 0 -and $joined -notmatch 'no encontr|did not find') { return New-StepResult Aviso $summary }
    New-StepResult OK $summary
}

function Step-WindowsUpdate {
    Set-StepProgress -Percent 2 -Status 'Buscando actualizaciones (puede tardar varios minutos, la barra no se moverá)...'
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'windows-maintenance-tool'
    $searcher = $session.CreateUpdateSearcher()
    $search = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")

    # Se omiten las opcionales (BrowseOnly) y las actualizaciones de versión de Windows.
    $upgradesCategory = '3689BDC8-B205-4AF4-8D4A-A63924C5E9D5'
    $updates = @()
    foreach ($update in $search.Updates) {
        if ($update.BrowseOnly) { continue }
        if (@($update.Categories | Where-Object { $_.CategoryID -eq $upgradesCategory }).Count) { continue }
        $updates += $update
    }
    if (-not $updates.Count) { return New-StepResult OK 'El equipo está al día' }

    Write-Log ("{0} actualizaciones encontradas:" -f $updates.Count)
    foreach ($update in $updates) { Write-Log "  - $($update.Title)" -Level Detail }

    $installed = 0; $failedTitles = @()
    for ($i = 0; $i -lt $updates.Count; $i++) {
        $update = $updates[$i]
        $label = '[{0}/{1}] {2}' -f ($i + 1), $updates.Count, $update.Title
        $slice = 90 / $updates.Count
        $base = 10 + $slice * $i
        try {
            if (-not $update.EulaAccepted) { $update.AcceptEula() }
            $collection = New-Object -ComObject Microsoft.Update.UpdateColl
            [void]$collection.Add($update)

            if (-not $update.IsDownloaded) {
                Set-StepProgress -Percent $base -Status "Descargando $label"
                $downloader = $session.CreateUpdateDownloader()
                $downloader.Updates = $collection
                [void]$downloader.Download()
            }

            Set-StepProgress -Percent ($base + $slice / 2) -Status "Instalando $label"
            $installer = $session.CreateUpdateInstaller()
            $installer.Updates = $collection
            $result = $installer.Install()
            if ($result.ResultCode -in 2, 3) {
                $installed++
                if ($result.RebootRequired) { $Run.RebootFlag = $true }
                Write-Log "  OK  $($update.Title)" -Level Ok
            }
            else {
                $failedTitles += $update.Title
                Write-Log ("  ERROR (resultado {0}, 0x{1:X8})  {2}" -f $result.ResultCode, $result.HResult, $update.Title) -Level Error
            }
        }
        catch {
            $failedTitles += $update.Title
            Write-Log "  ERROR  $($update.Title): $($_.Exception.Message)" -Level Error
        }
    }

    $detail = '{0} de {1} instaladas' -f $installed, $updates.Count
    if ($Run.RebootFlag) { $detail += ', requiere reinicio' }
    if ($failedTitles.Count) { return New-StepResult Aviso "$detail ($($failedTitles.Count) con error)" }
    New-StepResult OK $detail
}

function Get-WingetUpgrades([string]$Winget) {
    $list = Invoke-Native -FilePath $Winget -Arguments 'upgrade --accept-source-agreements --disable-interactivity' `
        -Status 'Consultando actualizaciones disponibles' -RangeStart 0 -RangeEnd 5
    $lines = @($list.Output -split "`r?`n" | ForEach-Object { ($_ -split "`r")[-1] })

    $dashes = -1
    for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^-{10,}\s*$') { $dashes = $i; break } }
    if ($dashes -lt 1) { return , @() }   # sin tabla: no hay nada que actualizar

    # Columnas según la cabecera (Nombre, Id, Versión, Disponible, Origen).
    $header = $lines[$dashes - 1]
    $starts = @([regex]::Matches($header, '(?<=^|\s)\S') | ForEach-Object { $_.Index })
    if ($starts.Count -lt 4) { return $null }

    $packages = @()
    for ($i = $dashes + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if (-not $line.Trim()) { break }              # fin de la primera tabla
        if ($line.Length -le $starts[3]) { continue }  # línea de resumen ("N upgrades available.")
        $id = $line.Substring($starts[1], $starts[2] - $starts[1]).Trim()
        if ($id -notmatch '^\S+$') { continue }
        $packages += [pscustomobject]@{
            Name      = $line.Substring(0, $starts[1]).Trim()
            Id        = $id
            Version   = $line.Substring($starts[2], $starts[3] - $starts[2]).Trim()
            Available = $(if ($starts.Count -gt 4 -and $line.Length -gt $starts[4]) { $line.Substring($starts[3], $starts[4] - $starts[3]).Trim() } else { $line.Substring($starts[3]).Trim() })
        }
    }
    , $packages
}

function Step-Winget {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    $winget = if ($cmd) { $cmd.Source } else { Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe' }
    if (-not (Test-Path $winget)) { return New-StepResult Omitido 'winget no está instalado (instala "Instalador de aplicación" desde Microsoft Store).' }

    # Apps de la Tienda: se pide a Windows que busque actualizaciones (no bloquea, mejor esfuerzo).
    try {
        Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' -ErrorAction Stop |
            Invoke-CimMethod -MethodName UpdateScanMethod -ErrorAction Stop | Out-Null
        Write-Log 'Solicitada a Microsoft Store la actualización de sus aplicaciones.' -Level Detail
    }
    catch { Write-Log "No se pudo pedir a Microsoft Store que actualice: $($_.Exception.Message)" -Level Detail -LogOnly }

    $exclude = @($WingetExclude)
    # No actualizar la terminal ni el PowerShell desde los que se está ejecutando el script.
    if ($env:WT_SESSION) { $exclude += 'Microsoft.WindowsTerminal' }
    if ($PSVersionTable.PSEdition -eq 'Core') { $exclude += 'Microsoft.PowerShell' }

    $packages = Get-WingetUpgrades $winget
    if ($null -eq $packages) {
        # Si no se ha podido leer la tabla, se actualiza todo de una vez.
        $all = Invoke-Native -FilePath $winget -Arguments 'upgrade --all --silent --accept-source-agreements --accept-package-agreements --disable-interactivity' `
            -Status 'Actualizando todas las aplicaciones' -TrackPercent -RangeStart 5
        foreach ($line in Get-LastMessages $all.Output 3) { Write-Log "  $line" -Level Detail }
        if ($all.ExitCode -eq 0) { return New-StepResult OK 'Aplicaciones actualizadas (winget upgrade --all)' }
        return New-StepResult Aviso ('winget upgrade --all terminó con código 0x{0:X8}' -f $all.ExitCode)
    }

    $skipped = @($packages | Where-Object { $exclude -contains $_.Id })
    # El propio winget (App Installer) se actualiza el último.
    $todo = @($packages | Where-Object { $exclude -notcontains $_.Id } | Sort-Object { $_.Id -eq 'Microsoft.AppInstaller' })
    foreach ($pkg in $skipped) { Write-Log "  Excluido: $($pkg.Name) ($($pkg.Id))" -Level Detail }
    if (-not $todo.Count) { return New-StepResult OK 'Todas las aplicaciones están al día' }

    Write-Log ("{0} aplicaciones por actualizar:" -f $todo.Count)
    $ok = 0; $failedNames = @()
    for ($i = 0; $i -lt $todo.Count; $i++) {
        $pkg = $todo[$i]
        $slice = 95 / $todo.Count
        $label = '[{0}/{1}] {2} {3} -> {4}' -f ($i + 1), $todo.Count, $pkg.Name, $pkg.Version, $pkg.Available
        $result = Invoke-Native -FilePath $winget `
            -Arguments "upgrade --id `"$($pkg.Id)`" --exact --silent --accept-source-agreements --accept-package-agreements --disable-interactivity" `
            -Status $label -TrackPercent -RangeStart (5 + $slice * $i) -RangeEnd (5 + $slice * ($i + 1))
        if ($result.ExitCode -eq 0) {
            $ok++
            Write-Log "  OK     $($pkg.Name) $($pkg.Version) -> $($pkg.Available)" -Level Ok
        }
        else {
            $failedNames += $pkg.Name
            $reason = (Get-LastMessages $result.Output 1) -join ''
            Write-Log ("  ERROR  {0} (0x{1:X8}) {2}" -f $pkg.Name, $result.ExitCode, $reason) -Level Error
        }
    }

    $detail = '{0} de {1} aplicaciones actualizadas' -f $ok, $todo.Count
    if ($skipped.Count) { $detail += ", $($skipped.Count) excluidas" }
    if ($failedNames.Count) { return New-StepResult Aviso "$detail. Fallaron: $($failedNames -join ', ')" }
    New-StepResult OK $detail
}

function Step-Defender {
    try { $status = Get-MpComputerStatus -ErrorAction Stop }
    catch { return New-StepResult Omitido 'Microsoft Defender no está disponible (¿otro antivirus instalado?).' }
    if (-not $status.AntivirusEnabled) { return New-StepResult Omitido 'Microsoft Defender está desactivado (¿otro antivirus instalado?).' }

    $update = Wait-JobWithProgress -Job (Update-MpSignature -AsJob) -Status 'Actualizando firmas' -RangeStart 0 -RangeEnd 15
    $scan = Wait-JobWithProgress -Job (Start-MpScan -ScanType QuickScan -AsJob) -Status 'Análisis rápido' -RangeStart 15 -RangeEnd 100

    $threats = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -gt $Run.StartTime })
    $version = (Get-MpComputerStatus).AntivirusSignatureVersion
    if ($threats.Count) {
        return New-StepResult Aviso ("¡{0} amenaza(s) detectada(s)! Revisa Seguridad de Windows > Protección antivirus" -f $threats.Count)
    }
    if ($scan.Failed -or $scan.Errors.Count) { return New-StepResult Aviso "El análisis no terminó correctamente: $($scan.Errors | Select-Object -First 1)" }
    if ($update.Failed -or $update.Errors.Count) { return New-StepResult Aviso "Análisis sin amenazas, pero no se pudieron actualizar las firmas (versión $version)" }
    New-StepResult OK "Firmas $version, sin amenazas"
}

function Step-Optimize {
    $volumes = @(Get-Volume | Where-Object {
            $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystem -in 'NTFS', 'ReFS' -and $_.OperationalStatus -eq 'OK'
        } | Sort-Object DriveLetter)
    if (-not $volumes.Count) { return New-StepResult Omitido 'No hay unidades que optimizar' }

    $done = @(); $failed = @()
    for ($i = 0; $i -lt $volumes.Count; $i++) {
        $letter = $volumes[$i].DriveLetter
        $slice = 100 / $volumes.Count
        $job = Optimize-Volume -DriveLetter $letter -AsJob
        $result = Wait-JobWithProgress -Job $job -Status "Optimizando ${letter}:" -RangeStart ($slice * $i) -RangeEnd ($slice * ($i + 1))
        if ($result.Failed -or $result.Errors.Count) {
            $failed += "${letter}:"
            Write-Log "  ${letter}: $($result.Errors | Select-Object -First 1)" -Level Warn
        }
        else { $done += "${letter}:" }
    }
    if ($failed.Count) { return New-StepResult Aviso "Optimizadas: $($done -join ' ') | Con error: $($failed -join ' ')" }
    New-StepResult OK "Optimizadas: $($done -join ' ')"
}

$StepDefs = [ordered]@{
    RestorePoint  = @{ Name = 'Punto de restauración';         Weight = 2;  Action = { Step-RestorePoint } }
    Temp          = @{ Name = 'Archivos temporales';           Weight = 2;  Action = { Step-Temp } }
    CleanMgr      = @{ Name = 'Liberador de espacio en disco'; Weight = 6;  Action = { Step-CleanMgr } }
    DISM          = @{ Name = 'DISM (imagen de Windows)';      Weight = 12; Action = { Step-DISM } }
    SFC           = @{ Name = 'SFC (archivos del sistema)';    Weight = 10; Action = { Step-SFC } }
    WindowsUpdate = @{ Name = 'Windows Update';                Weight = 15; Action = { Step-WindowsUpdate } }
    Winget        = @{ Name = 'Aplicaciones (winget)';         Weight = 10; Action = { Step-Winget } }
    Defender      = @{ Name = 'Microsoft Defender';            Weight = 6;  Action = { Step-Defender } }
    Optimize      = @{ Name = 'Optimizar unidades';            Weight = 4;  Action = { Step-Optimize } }
}

# ---------------------------------------------------------------------------
# Ejecución
# ---------------------------------------------------------------------------

$selected = @($AllSteps | Where-Object { ($Only.Count -eq 0 -or $Only -contains $_) -and $Skip -notcontains $_ })
if (-not $selected.Count) { Write-Host 'No hay ningún paso que ejecutar.' -ForegroundColor Yellow; exit 0 }

$Run.StartTime = Get-Date
$Run.StepCount = $selected.Count
$Run.TotalWeight = ($selected | ForEach-Object { $StepDefs[$_].Weight } | Measure-Object -Sum).Sum
$results = New-Object System.Collections.Generic.List[object]
$freeAtStart = Get-FreeSpace

try { $Host.UI.RawUI.WindowTitle = 'Mantenimiento de Windows' } catch { }

# Evita que el equipo entre en suspensión mientras dura el mantenimiento.
$keepAwake = $false
try {
    Add-Type -Namespace WinMaintenance -Name Power -MemberDefinition `
        '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
    [void][WinMaintenance.Power]::SetThreadExecutionState([Convert]::ToUInt32('80000001', 16))   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
    $keepAwake = $true
}
catch { }

Write-Log ''
Write-Log '==============================================================' -Level Title
Write-Log '  MANTENIMIENTO DE WINDOWS' -Level Title
Write-Log ('  {0:dddd d MMMM yyyy, HH:mm}  |  {1}' -f (Get-Date), $env:COMPUTERNAME) -Level Title
Write-Log '==============================================================' -Level Title
Write-Log ("Pasos: {0}" -f (($selected | ForEach-Object { $StepDefs[$_].Name }) -join ', '))
Write-Log ("Espacio libre en {0}: {1}" -f $env:SystemDrive, (Format-Size $freeAtStart))
Write-Log "Registro: $LogFile" -Level Detail

try {
    foreach ($id in $selected) {
        $def = $StepDefs[$id]
        $Run.StepIndex++
        $Run.StepName = $def.Name
        $Run.StepWeight = $def.Weight

        Write-Log ''
        Write-Log ("[{0}/{1}] {2}" -f $Run.StepIndex, $Run.StepCount, $def.Name) -Level Title
        Set-StepProgress -Percent 0 -Status 'Iniciando...'

        $clock = [Diagnostics.Stopwatch]::StartNew()
        try {
            $result = @(& $def.Action) | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['IsStepResult'] } | Select-Object -Last 1
            if (-not $result) { $result = New-StepResult OK '' }
        }
        catch {
            $result = New-StepResult Error $_.Exception.Message
            Write-Log ($_ | Out-String) -Level Detail -LogOnly
        }
        $clock.Stop()
        $Run.DoneWeight += $def.Weight

        $level = switch ($result.State) { 'OK' { 'Ok' } 'Error' { 'Error' } default { 'Warn' } }
        Write-Log ("  -> {0}: {1}  ({2})" -f $result.State, $result.Detail, (Format-Elapsed $clock.Elapsed)) -Level $level
        $results.Add([pscustomobject]@{
                Paso     = $def.Name
                Estado   = $result.State
                Duracion = Format-Elapsed $clock.Elapsed
                Detalle  = $result.Detail
            })
    }
}
finally {
    Write-Progress -Id 2 -Activity 'Paso' -Completed
    Write-Progress -Id 1 -Activity 'Mantenimiento de Windows' -Completed
    if ($keepAwake) { [void][WinMaintenance.Power]::SetThreadExecutionState([Convert]::ToUInt32('80000000', 16)) }
}

# ---------------------------------------------------------------------------
# Resumen
# ---------------------------------------------------------------------------

$freeAtEnd = Get-FreeSpace
$rebootNeeded = $Run.RebootFlag -or (Test-PendingReboot)

Write-Log ''
Write-Log '==============================================================' -Level Title
Write-Log '  RESUMEN' -Level Title
Write-Log '==============================================================' -Level Title
foreach ($r in $results) {
    $level = switch ($r.Estado) { 'OK' { 'Ok' } 'Error' { 'Error' } default { 'Warn' } }
    Write-Log ('  {0,-8} {1,-31} {2}  {3}' -f $r.Estado, $r.Paso, $r.Duracion, $r.Detalle) -Level $level
}
Write-Log ''
Write-Log ("Tiempo total: {0}" -f (Format-Elapsed $Run.Clock.Elapsed))
Write-Log ("Espacio libre en {0}: {1} -> {2} ({3} recuperados)" -f $env:SystemDrive, (Format-Size $freeAtStart), (Format-Size $freeAtEnd), (Format-Size ([Math]::Max(0, $freeAtEnd - $freeAtStart))))
Write-Log "Registro completo: $LogFile" -Level Detail

if ($rebootNeeded) {
    Write-Log ''
    Write-Log 'Es necesario REINICIAR el equipo para completar algunas reparaciones o actualizaciones.' -Level Warn
    if ($Reboot) {
        Write-Log 'Reiniciando en 60 segundos (cancelar con: shutdown /a)...' -Level Warn
        shutdown.exe /r /t 60 /c 'Mantenimiento de Windows completado: reiniciando.'
    }
    elseif (-not $NoPause) {
        $answer = Read-Host '¿Reiniciar ahora? (s/N)'
        if ($answer -match '^\s*(s|si|sí|y|yes)\s*$') { shutdown.exe /r /t 5 }
    }
}

if (-not $NoPause) { [void](Read-Host 'Pulsa Enter para cerrar') }
