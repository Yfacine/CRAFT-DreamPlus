param([Parameter(Mandatory=$true)][string]$RequestPath,[Parameter(Mandatory=$true)][string]$StartEventName)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'core_run_state.ps1')
. (Join-Path $PSScriptRoot 'owned_process.ps1')
Assert-PlainPath $RequestPath
if(-not [IO.Path]::GetFullPath($RequestPath).StartsWith('D:\PASS_AI\TEST\automated\pass-ai-pro-',[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid owned request path.'}
if($StartEventName -cnotmatch '^Local\\PASS_AI_PRO_[a-f0-9]{32}$'){throw 'Invalid owned start event.'}
$request=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$event=$null;$process=$null;$outFile=$null;$errFile=$null;$exitCode=125;$errorText='';$childPid=$null
try{
    $event=[Threading.EventWaitHandle]::OpenExisting($StartEventName)
    if(-not $event.WaitOne(30000)){throw 'Owner did not release the start gate.'}
    foreach($path in @($request.file,$request.working_directory,$request.stdout,$request.stderr,$request.host_result)){Assert-PlainPath $path}
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=[string]$request.file;$start.Arguments=ConvertTo-CoreNativeArguments -Values @($request.arguments)
    $start.WorkingDirectory=[string]$request.working_directory
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $outFile=[IO.File]::Open($request.stdout,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $errFile=[IO.File]::Open($request.stderr,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $process=[Diagnostics.Process]::Start($start);$childPid=$process.Id
    $outCopy=$process.StandardOutput.BaseStream.CopyToAsync($outFile);$errCopy=$process.StandardError.BaseStream.CopyToAsync($errFile)
    $process.WaitForExit()
    $outCopy.GetAwaiter().GetResult();$errCopy.GetAwaiter().GetResult()
    $exitCode=$process.ExitCode
}catch{$errorText=$_.Exception.Message}
finally{
    if($null -ne $outFile){$outFile.Dispose()};if($null -ne $errFile){$errFile.Dispose()}
    if($null -ne $process){$process.Dispose()};if($null -ne $event){$event.Dispose()}
}
Write-CoreJson -Path $request.host_result -Value ([ordered]@{operation_id=$request.operation_id;exit_code=$exitCode;child_pid=$childPid;error=$errorText;completed_utc=[DateTime]::UtcNow.ToString('o')})
exit $exitCode
