# windows-maintenance-tool

Script de PowerShell para hacer un mantenimiento completo de Windows 11 **a demanda**, con barra de progreso global y por paso, y un registro de todo lo que hace.

## Qué hace

| Paso | Id | Descripción |
|---|---|---|
| 1 | `RestorePoint` | Crea un punto de restauración antes de empezar (Windows solo permite uno cada 24 h). |
| 2 | `Temp` | Borra archivos temporales de `%TEMP%` y `C:\Windows\Temp` (los que tengan más de 1 día; los que estén en uso se saltan). |
| 3 | `CleanMgr` | Ejecuta el Liberador de espacio en disco (`cleanmgr /sagerun`) de forma desatendida. |
| 4 | `DISM` | `DISM /Online /Cleanup-Image /RestoreHealth` y `/StartComponentCleanup`. |
| 5 | `SFC` | `sfc /scannow`. |
| 6 | `WindowsUpdate` | Busca, descarga e instala las actualizaciones de Windows (no instala las opcionales ni las actualizaciones de versión). |
| 7 | `Winget` | Actualiza las aplicaciones con `winget`, una a una, y pide a Microsoft Store que actualice sus apps. |
| 8 | `Defender` | Actualiza las firmas de Microsoft Defender y hace un análisis rápido. |
| 9 | `Optimize` | Optimiza las unidades: TRIM en SSD, desfragmentación en HDD. |

Al final muestra un resumen con el resultado de cada paso, el espacio recuperado y si hace falta reiniciar (y pregunta si quieres reiniciar ya).

## Uso

Doble clic en **`Mantenimiento.cmd`**. Pedirá permisos de administrador (UAC) y abrirá una ventana con el progreso.

Desde PowerShell:

```powershell
.\Invoke-WindowsMaintenance.ps1                                   # todo
.\Invoke-WindowsMaintenance.ps1 -Only Temp,CleanMgr               # solo limpieza
.\Invoke-WindowsMaintenance.ps1 -Skip WindowsUpdate,Optimize      # todo menos esos pasos
.\Invoke-WindowsMaintenance.ps1 -WingetExclude Microsoft.Edge     # no actualizar ciertas apps
.\Invoke-WindowsMaintenance.ps1 -TempOlderThanDays 0              # borrar todos los temporales
.\Invoke-WindowsMaintenance.ps1 -Reboot -NoPause                  # desatendido, reinicia si hace falta
```

Si PowerShell bloquea el script por la directiva de ejecución, usa el `.cmd` o lánzalo así:

```powershell
powershell -ExecutionPolicy Bypass -File .\Invoke-WindowsMaintenance.ps1
```

## Detalles

- **Duración:** la primera vez puede tardar bastante (DISM, SFC y Windows Update son lentos). Es normal que DISM se quede un rato parado en un porcentaje.
- **Registro:** cada ejecución deja un log en `logs\mantenimiento_AAAAMMDD_HHMMSS.log`, con la salida completa de DISM, SFC y winget.
- **Liberador de espacio:** por seguridad **no** se limpian la carpeta de Descargas, la Papelera, `Windows.old`, los archivos ESD de reinstalación ni el Historial de archivos. Se puede cambiar en la variable `$CleanMgrExclude` al principio del script.
- **winget:** si el script se ejecuta dentro de Windows Terminal, no actualiza Windows Terminal (cerraría la ventana). `App Installer` (el propio winget) se actualiza el último.
- **Suspensión:** el equipo no entra en suspensión mientras dura el mantenimiento.
- Requiere Windows 10/11 y Windows PowerShell 5.1 (incluido en Windows). También funciona en PowerShell 7.
