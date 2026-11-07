param([ValidateSet('success','failure','hang','tree','witness')][string]$Mode='success',[string]$Marker='',[string]$Echo='')
$ErrorActionPreference='Stop'
if($Marker){[IO.File]::WriteAllText($Marker,[string]$PID)}
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
if($Mode -eq 'success'){[Console]::Out.WriteLine('PRO owned process output');[Console]::Out.WriteLine($Echo);exit 0}
if($Mode -eq 'failure'){[Console]::Error.WriteLine('PRO expected test failure');exit 7}
if($Mode -eq 'tree'){
    $exe=Join-Path $PSHOME $(if($PSVersionTable.PSEdition -eq 'Core'){'pwsh.exe'}else{'powershell.exe'})
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$exe
    $start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Mode hang -Marker "'+$Marker+'.child"'
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $child=[Diagnostics.Process]::Start($start);$child.Dispose()
}
[Threading.Thread]::Sleep(120000)
