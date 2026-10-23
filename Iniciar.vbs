Option Explicit
Dim shell, files, scriptPath, command
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
scriptPath = files.BuildPath(files.GetParentFolderName(WScript.ScriptFullName), "EnergiaPC.ps1")
If Not files.FileExists(scriptPath) Then
    MsgBox "No se encontro EnergiaPC.ps1. Extrae toda la carpeta ZIP antes de abrir Iniciar.vbs.", 16, "Energia PC"
    WScript.Quit 1
End If
command = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command " & Chr(34) & "try { & '" & Replace(scriptPath, "'", "''") & "' } catch { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Energia PC - Error al iniciar') | Out-Null; exit 1 }" & Chr(34)
shell.Run command, 0, False
