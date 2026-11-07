[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BuildReceipt,
    [Parameter(Mandatory=$true)][string]$ExpectedPluginSha256,
    [Parameter(Mandatory=$true)][string]$ExpectedCoreSha256,
    [Parameter(Mandatory=$true)][string]$ExpectedTemplateSha256,
    [Parameter(Mandatory=$true)][string]$Approval,
    [string]$TemplatePath='C:\Users\SYBME_PC\AppData\Local\Autodesk\AutoCAD 2024\R24.3\kor\Template\acadiso.dwt',
    [int]$TimeoutSeconds=120
)
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'cad_log_cleanup.ps1')
. (Join-Path $PSScriptRoot 'cad_diagnostics.ps1')
. (Join-Path $PSScriptRoot 'core_run_state.ps1')
if([string]::IsNullOrWhiteSpace($Approval)){throw 'Exact CAD smoke-test approval evidence is required.'}
if($TimeoutSeconds -lt 10 -or $TimeoutSeconds -gt 180){throw 'CAD timeout must be between 10 and 180 seconds.'}
Assert-PlainPath $BuildReceipt
Assert-PlainPath $TemplatePath
$build=Get-Content -LiteralPath $BuildReceipt -Raw | ConvertFrom-Json
Assert-CoreCompletedBuild -Build $build
if($build.status -cne 'PASS' -or $build.plugin_sha256 -ine $ExpectedPluginSha256){throw 'Build receipt or reviewed plugin identity mismatch.'}
$context=Get-BuildContext -ArtifactRoot $build.artifact_root
if($context.Artifacts -match '[^\x20-\x7e]'){throw 'Core Console script paths must use the approved ASCII artifact root.'}
if($build.version -cne $context.Version){throw 'Current product version changed after the reviewed build.'}
$plugin=[IO.Path]::GetFullPath([string]$build.plugin)
$expected=Join-Path $context.Artifacts 'bin\PassAiPro.AutoCAD\Release\net48\PassAiPro.AutoCAD.dll'
if($plugin -ine $expected -or (Get-FileHash -LiteralPath $plugin -Algorithm SHA256).Hash -ine $ExpectedPluginSha256){throw 'Reviewed Release artifact mismatch.'}
$core=Join-Path (Split-Path -Parent $plugin) 'PassAiPro.Core.dll'
if($build.core_sha256 -ine $ExpectedCoreSha256 -or (Get-FileHash -LiteralPath $core -Algorithm SHA256).Hash -ine $ExpectedCoreSha256){throw 'Reviewed Core artifact mismatch.'}
$exe=Join-Path $context.CadRoot 'accoreconsole.exe'
if(-not (Test-Path -LiteralPath $exe -PathType Leaf)){throw 'AutoCAD Core Console is missing.'}
$work=Join-Path $context.Artifacts ('cad-smoke-'+[Guid]::NewGuid().ToString('N'))
$bundle=Join-Path $work 'plugin'
[void][IO.Directory]::CreateDirectory($bundle)
$templateHash=(Get-FileHash -LiteralPath $TemplatePath -Algorithm SHA256).Hash
if($templateHash -ine $ExpectedTemplateSha256){throw 'Reviewed template identity mismatch.'}
$drawing=Join-Path $work 'foundation-input.dwg'
Copy-Item -LiteralPath $TemplatePath -Destination $drawing
(Get-Item -LiteralPath $drawing).IsReadOnly=$true
foreach($name in @('PassAiPro.AutoCAD.dll','PassAiPro.Core.dll')){Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $plugin) $name) -Destination (Join-Path $bundle $name)}
$copiedPlugin=(Get-FileHash -LiteralPath (Join-Path $bundle 'PassAiPro.AutoCAD.dll') -Algorithm SHA256).Hash
$copiedCore=(Get-FileHash -LiteralPath (Join-Path $bundle 'PassAiPro.Core.dll') -Algorithm SHA256).Hash
if($copiedPlugin -ine $ExpectedPluginSha256 -or $copiedCore -ine $ExpectedCoreSha256){throw 'Copied CAD test artifacts differ from the reviewed binaries.'}
$script=Join-Path $work 'smoke.scr'
$cadBundle=$bundle.Replace('\','/')
$cadDll=(Join-Path $bundle 'PassAiPro.AutoCAD.dll').Replace('\','/')
$commands=@(('(setvar "TRUSTEDPATHS" (strcat (getvar "TRUSTEDPATHS") ";" "{0}"))' -f $cadBundle),'_.NETLOAD',('"{0}"' -f $cadDll),'PASSAIPRO_ABOUT','PASSAIPRO_STATUS','_.QUIT','_Y','')
[IO.File]::WriteAllText($script,($commands -join "`r`n"),[Text.Encoding]::ASCII)
$request=[ordered]@{status='APPROVED FOR EXECUTION';approval=$Approval;exe=$exe;plugin_sha256=$copiedPlugin;core_sha256=$copiedCore;template=$TemplatePath;template_sha256=$templateHash;drawing_copy=$drawing;work_root=$work;commands=$commands;security='Only isolated profile TRUSTEDPATHS adds the owned test DLL folder; SECURELOAD unchanged';scope='Core Console actual engine diagnostics; no desktop GUI, no save, no Plot'}
$request | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $work 'request.json') -Encoding utf8
$start=New-Object Diagnostics.ProcessStartInfo
$start.FileName=$exe
$start.Arguments='/i "'+$drawing+'" /s "'+$script+'" /isolate PASSAIPRO_'+[Guid]::NewGuid().ToString('N')+' "'+(Join-Path $work 'profile')+'" /l ko-KR /readonly'
$start.WorkingDirectory=$work
$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
$start.EnvironmentVariables['TEMP']=$work;$start.EnvironmentVariables['TMP']=$work
$process=$null
$timedOut=$false
try{
    $process=[Diagnostics.Process]::Start($start)
    $ownedId=$process.Id
    $stdout=New-Object IO.MemoryStream;$stderr=New-Object IO.MemoryStream
    $outTask=$process.StandardOutput.BaseStream.CopyToAsync($stdout)
    $errTask=$process.StandardError.BaseStream.CopyToAsync($stderr)
    if(-not $process.WaitForExit($TimeoutSeconds*1000)){$timedOut=$true;$process.Kill();$process.WaitForExit()}
    $outTask.GetAwaiter().GetResult();$errTask.GetAwaiter().GetResult()
    $bytes=$stdout.ToArray()
    [IO.File]::WriteAllBytes((Join-Path $work 'stdout.bin'),$bytes)
    $errBytes=$stderr.ToArray()
    [IO.File]::WriteAllBytes((Join-Path $work 'stderr.bin'),$errBytes)
    $decodingErrors=@()
    try{$text=ConvertFrom-PassAiProCadBytes -Bytes $bytes}catch{$decodingErrors+=('stdout: '+$_.Exception.Message);$text=[Text.Encoding]::UTF8.GetString($bytes)}
    try{$errorText=ConvertFrom-PassAiProCadBytes -Bytes $errBytes}catch{$decodingErrors+=('stderr: '+$_.Exception.Message);$errorText=[Text.Encoding]::UTF8.GetString($errBytes)}
    [IO.File]::WriteAllText((Join-Path $work 'stdout.txt'),$text,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $work 'stderr.txt'),$errorText,[Text.UTF8Encoding]::new($false))
    $unchanged=(Get-FileHash -LiteralPath $TemplatePath -Algorithm SHA256).Hash -ceq $templateHash -and (Get-FileHash -LiteralPath $drawing -Algorithm SHA256).Hash -ceq $templateHash
    $assessment=Test-PassAiProCadDiagnostics -Stdout $text -Stderr $errorText -ExpectedVersion $context.Version -WorkRoot $work -OwnedProcessId $ownedId -ProcessExited $process.HasExited -ExitCode $process.ExitCode -TimedOut $timedOut -TemplateAndCopyUnchanged $unchanged -ExpectedTemplatePath $TemplatePath -ExpectedConsolePath $exe
    $hits=$assessment.product_output_occurrences
    $quitConfirmed=$assessment.explicit_quit_confirmed
    $cleanupWarnings=@($assessment.engine_cleanup_warnings)
    $unexpectedErrors=@($assessment.unexpected_errors)
    $ok=$assessment.ok -and $decodingErrors.Count -eq 0
    $logRecovery=@();$logRecoveryError=$null
    if($ok){
        try{
            foreach($warning in $cleanupWarnings){$logRecovery+=Complete-PassAiProOwnedEngineLog -WorkRoot $work -OwnedProcessId $ownedId -ProcessExited $process.HasExited -ExitCode $process.ExitCode -TimedOut $timedOut -WarningLine $warning}
        }catch{$logRecoveryError=$_.Exception.Message;$ok=$false}
    }
    [ordered]@{status=if($ok){'PASS'}else{'FAIL'};scope='actual AutoCAD 2024 Core Console diagnostics; desktop GUI NOT RUN';owned_pid=$ownedId;exited=$process.HasExited;exit_code=$process.ExitCode;timed_out=$timedOut;product_output_occurrences=$hits;explicit_quit_confirmed=$quitConfirmed;template_and_copy_unchanged=$unchanged;diagnostic_assessment=$assessment;decoding_errors=$decodingErrors;engine_cleanup_warnings=$cleanupWarnings;engine_warning_eliminated=($cleanupWarnings.Count -eq 0);engine_log_recovery=$logRecovery;engine_log_recovery_error=$logRecoveryError;unexpected_errors=$unexpectedErrors;plugin_sha256=$ExpectedPluginSha256;core_sha256=$ExpectedCoreSha256;template_sha256=$templateHash;work_root=$work} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $work 'result.json') -Encoding utf8
    if(-not $ok){throw "Actual CAD smoke test failed; preserve $work"}
    Write-Output ('CAD CORE CONSOLE PASS: '+$work)
}finally{if($null -ne $process){if(-not $process.HasExited){$process.Kill();$process.WaitForExit()};$process.Dispose()}}
