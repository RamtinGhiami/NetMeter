' NetMeter launcher: runs the dashboard without a console window.
Option Explicit
Dim fso, sh, here, ship, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
here = fso.GetParentFolderName(WScript.ScriptFullName)
ship = fso.GetParentFolderName(here)
sh.CurrentDirectory = ship

If fso.FileExists(here & "\dist\NetMeter\NetMeter.exe") Then
    cmd = """" & here & "\dist\NetMeter\NetMeter.exe"" --no-browser"
ElseIf fso.FileExists(here & "\NetMeter.exe") Then
    cmd = """" & here & "\NetMeter.exe"" --no-browser"
Else
    cmd = "pyw -3 """ & here & "\run.pyw"" --no-browser"
End If

On Error Resume Next
sh.Run cmd, 0, False
If Err.Number <> 0 Then
    Err.Clear
    sh.Run """" & here & "\run.bat""", 0, False
End If
