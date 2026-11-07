[CmdletBinding()]
param([string]$ArtifactRoot='', [string]$AutoCADRoot='C:\Program Files\Autodesk\AutoCAD 2024', [string]$DotnetPath='E:\PASS_AI\.tools\pass-ai-pro\dotnet\8.0.426\dotnet.exe',
      [ValidateRange(1,600)][int]$SdkTimeoutSeconds=30,[ValidateRange(1,600)][int]$RestoreTimeoutSeconds=180,[ValidateRange(1,600)][int]$BuildTimeoutSeconds=120,[ValidateRange(1,600)][int]$CoreTestTimeoutSeconds=60)
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'cad_log_cleanup.ps1')
. (Join-Path $PSScriptRoot 'core_run_state.ps1')
. (Join-Path $PSScriptRoot 'owned_process.ps1')
. (Join-Path $PSScriptRoot '..\tests\verify_cad_diagnostics.ps1')
. (Join-Path $PSScriptRoot '..\tests\verify_runner_safety.ps1')
$workspace=Get-RunWorkspace -ArtifactRoot $ArtifactRoot
[void][IO.Directory]::CreateDirectory($workspace.Artifacts)
$lease=[IO.File]::Open((Join-Path $workspace.Artifacts '.build.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$run=$null;$testEnvironment=$null
try{
$run=New-CoreRunState -Workspace $workspace -Kind test
Set-CoreRunStatus -Run $run -Status STARTED -Phase 'test-preflight'
$context=Get-BuildContext -ArtifactRoot $workspace.Artifacts -AutoCADRoot $AutoCADRoot -DotnetPath $DotnetPath
$testEnvironment=Set-BuildEnvironment $context
& (Join-Path $PSScriptRoot 'build.ps1') -ArtifactRoot $context.Artifacts -AutoCADRoot $AutoCADRoot -DotnetPath $DotnetPath -WorkspaceLease $lease -RunState $run -SdkTimeoutSeconds $SdkTimeoutSeconds -RestoreTimeoutSeconds $RestoreTimeoutSeconds -BuildTimeoutSeconds $BuildTimeoutSeconds
$receipt=Get-Content -LiteralPath (Join-Path $context.Artifacts 'build-receipt.json') -Raw | ConvertFrom-Json
Set-CoreRunStatus -Run $run -Status STARTED -Phase 'core-tests'
$coreProcess=Invoke-CoreOwnedProcess -Run $run -Step core-tests -FilePath $receipt.test_executable -Arguments @($context.Version) -WorkingDirectory $context.Root -TimeoutSeconds $CoreTestTimeoutSeconds
$coreText=Get-CoreProcessLog -Result $coreProcess -LogPath (Join-Path $context.Artifacts 'core-tests.txt')
$output=@($coreText.TrimEnd() -split '\r?\n')
$testExit=$coreProcess.exit_code
if($testExit -ne 0){throw 'Core scenarios failed; see core-tests.txt.'}
$checks=New-Object 'System.Collections.Generic.List[object]'
$checks.Add([pscustomobject]@{name='core-behavioral-scenarios';ok=($testExit -eq 0);detail=($output[-1] | Out-String).Trim()})
$sourceOutputRejected=$true
foreach($name in @('bin','obj')){
    $sourceOutput=Join-Path $context.Root $name
    $rejected=$false
    try{[void](Get-RunWorkspace -ArtifactRoot $sourceOutput)}catch{
        $rejected=$_.Exception.Message -like 'Artifacts must remain in *'
    }
    $sourceOutputRejected=$sourceOutputRejected -and $rejected
}
$checks.Add([pscustomobject]@{name='source-output-root-rejected';ok=$sourceOutputRejected;detail='bin and obj under the current source root'})
$rejected=$false
try{[void](Get-BuildContext -ArtifactRoot $context.Artifacts -AutoCADRoot 'C:\Windows' -DotnetPath $DotnetPath)}catch{$rejected=$true}
$checks.Add([pscustomobject]@{name='missing-cad-references-rejected';ok=$rejected})
$fixture=Join-Path 'D:\PASS_AI\TEST\automated' ('pass-ai-pro-path-fixture-'+[Guid]::NewGuid().ToString('N'))
$fixtureRoot=Join-Path $fixture 'artifact'
$fixtureTarget=Join-Path $fixture 'plain-target'
[void][IO.Directory]::CreateDirectory($fixtureRoot)
[void][IO.Directory]::CreateDirectory($fixtureTarget)
[void](New-Item -ItemType Junction -Path (Join-Path $fixtureRoot 'temp') -Target $fixtureTarget)
$rejected=$false
try{Assert-PlainTree $fixtureRoot}catch{$rejected=$true}
$checks.Add([pscustomobject]@{name='nested-artifact-junction-rejected';ok=$rejected})
$encodedSourceObj=[Uri]::EscapeDataString((Join-Path $context.Root 'obj'))
foreach($bad in @("D:\PASS_AI\TEST\automated\pass-ai-pro-x;BaseIntermediateOutputPath=$encodedSourceObj",'D:\PASS_AI\TEST\automated\pass-ai-pro-x%3Bother')){
    $rejected=$false
    try{[void](Get-RunWorkspace -ArtifactRoot $bad)}catch{
        $rejected=$_.Exception.Message -eq 'Path contains unsupported MSBuild or shell metacharacters.'
    }
    $checks.Add([pscustomobject]@{name=('msbuild-property-injection-rejected-'+$checks.Count);ok=$rejected})
}
$badConfig=Join-Path $fixture 'unapproved-NuGet.config'
$original=[IO.File]::ReadAllText((Join-Path $context.Root 'NuGet.config'))
[IO.File]::WriteAllText($badConfig,$original.Replace('https://api.nuget.org/v3/index.json','https://example.invalid/v3/index.json'))
$rejected=$false
try{Assert-RestoreSource $badConfig}catch{$rejected=$true}
$checks.Add([pscustomobject]@{name='unapproved-package-source-rejected-before-network';ok=$rejected})
$badLock=Join-Path $fixture 'unapproved-packages.lock.json'
$original=[IO.File]::ReadAllText((Join-Path $context.Root 'src\PassAiPro.Core\packages.lock.json'))
[IO.File]::WriteAllText($badLock,$original.Replace('"resolved": "1.0.3"','"resolved": "9.0.0"'))
$rejected=$false
try{Assert-PackageLock $badLock}catch{$rejected=$true}
$checks.Add([pscustomobject]@{name='unapproved-locked-package-version-rejected';ok=$rejected})
$blocked=Join-Path $fixture 'environment-failure'
[void][IO.Directory]::CreateDirectory($blocked)
[IO.File]::WriteAllText((Join-Path $blocked 'temp'),'block directory creation')
$beforeTemp=[Environment]::GetEnvironmentVariable('TEMP','Process')
$rejected=$false
try{[void](Set-BuildEnvironment ([pscustomobject]@{Artifacts=$blocked}))}catch{$rejected=$true}
$checks.Add([pscustomobject]@{name='environment-preserved-when-temp-creation-fails';ok=($rejected -and [Environment]::GetEnvironmentVariable('TEMP','Process') -ceq $beforeTemp)})
$start=New-Object System.Diagnostics.ProcessStartInfo
$start.FileName=(Join-Path $PSHOME $(if($PSVersionTable.PSEdition -eq 'Core'){'pwsh.exe'}else{'powershell.exe'}))
$start.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'build.ps1')+'" -ArtifactRoot "'+$context.Artifacts+'" -AutoCADRoot "'+$AutoCADRoot+'" -DotnetPath "'+$DotnetPath+'"'
$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
$child=[Diagnostics.Process]::Start($start)
$childOut=$child.StandardOutput.ReadToEndAsync();$childError=$child.StandardError.ReadToEndAsync()
if(-not $child.WaitForExit(30000)){$child.Kill();$child.WaitForExit();throw 'Concurrent-build negative test timed out.'}
($childOut.Result+$childError.Result) | Out-File -LiteralPath (Join-Path $context.Artifacts 'concurrent-build-rejected.txt') -Encoding utf8
$checks.Add([pscustomobject]@{name='concurrent-build-rejected-before-receipt-mutation';ok=($child.ExitCode -ne 0 -and (Get-FileHash -LiteralPath $receipt.plugin -Algorithm SHA256).Hash -ceq $receipt.plugin_sha256)})
$child.Dispose()
$sourceOutputs=@(Get-ChildItem -LiteralPath $context.Root -Recurse -Directory -Force | Where-Object Name -in @('bin','obj'))
$checks.Add([pscustomobject]@{name='no-source-bin-obj';ok=($sourceOutputs.Count -eq 0)})
$pluginFiles=@(Get-ChildItem -LiteralPath (Split-Path -Parent $receipt.plugin) -File | Select-Object -ExpandProperty Name)
$checks.Add([pscustomobject]@{name='plugin-and-core-delivered-together';ok=('PassAiPro.Core.dll' -in $pluginFiles -and 'PassAiPro.AutoCAD.dll' -in $pluginFiles)})
$checks.Add([pscustomobject]@{name='autodesk-references-not-redistributed';ok=($receipt.autodesk_assemblies_copied -eq 0)})
$cleanupPid=2147483647
$knownBytes=[Text.Encoding]::ASCII.GetBytes("m_kernelList still has 1 entry.`r`n")
foreach($caseName in @('success','live-pid','unknown-content','readonly','archive-conflict','locked','wrong-owner','failed-exit','junction')){
    $caseRoot=Join-Path $fixture ('cleanup-'+$caseName)
    [void][IO.Directory]::CreateDirectory($caseRoot)
    $casePid=if($caseName -eq 'live-pid'){$PID}else{$cleanupPid}
    $log=Join-Path $caseRoot ('accc'+$casePid+'2')
    [IO.File]::WriteAllBytes($log,$knownBytes)
    $warning="ERROR: Can't delete temp file "+$log+'. (errno=13).'
    if($caseName -eq 'unknown-content'){[IO.File]::WriteAllText($log,'unexpected engine diagnostic')}
    if($caseName -eq 'readonly'){(Get-Item -LiteralPath $log).IsReadOnly=$true}
    if($caseName -eq 'archive-conflict'){
        $saved=Join-Path $caseRoot 'preserved-engine-logs';[void][IO.Directory]::CreateDirectory($saved)
        [IO.File]::WriteAllText((Join-Path $saved ('accc'+$casePid+'2.txt')),'existing evidence')
    }
    if($caseName -eq 'junction'){
        $savedTarget=Join-Path $fixture 'cleanup-archive-target';[void][IO.Directory]::CreateDirectory($savedTarget)
        [void](New-Item -ItemType Junction -Path (Join-Path $caseRoot 'preserved-engine-logs') -Target $savedTarget)
    }
    if($caseName -eq 'wrong-owner'){$warning="ERROR: Can't delete temp file "+(Join-Path $caseRoot 'accc12')+'. (errno=13).'}
    $exit=if($caseName -eq 'failed-exit'){1}else{0}
    $lockHandle=$null;$rejected=$false;$recovery=$null
    try{
        if($caseName -eq 'locked'){$lockHandle=[IO.File]::Open($log,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)}
        try{$recovery=Complete-PassAiProOwnedEngineLog -WorkRoot $caseRoot -OwnedProcessId $casePid -ProcessExited $true -ExitCode $exit -WarningLine $warning}catch{$rejected=$true}
    }finally{if($null -ne $lockHandle){$lockHandle.Dispose()}}
    if($caseName -eq 'success'){
        $ok=-not $rejected -and -not (Test-Path -LiteralPath $log) -and $recovery.status -ceq 'ARCHIVED_AND_REMOVED_AFTER_EXIT' -and (Get-FileHash -LiteralPath $recovery.archive -Algorithm SHA256).Hash -ceq '9E5BD9A8B1D7E1538D41A06C9F65743121BEDA95F7380F55A78A2D506E51F896'
    }else{$ok=$rejected -and (Test-Path -LiteralPath $log -PathType Leaf)}
    $checks.Add([pscustomobject]@{name=('owned-engine-log-'+$caseName);ok=$ok})
}
$existingCheckCount=$checks.Count
foreach($diagnosticCheck in @(Invoke-PassAiProCadDiagnosticTests -ArtifactRoot $context.Artifacts -Version $context.Version)){$checks.Add($diagnosticCheck)}
$diagnosticCount=$checks.Count-$existingCheckCount
foreach($runnerCheck in @(Invoke-PassAiProRunnerSafetyTests -ArtifactRoot $context.Artifacts)){$checks.Add($runnerCheck)}
$failed=@($checks | Where-Object {-not $_.ok}).Count
Write-CoreJson -Path (Join-Path $context.Artifacts 'test-receipt.json') -Value ([ordered]@{status=if($failed -eq 0){'PASS'}else{'FAIL'};run_id=$run.Id;completed_utc=[DateTime]::UtcNow.ToString('o');execution_receipt=(Join-Path $context.Artifacts 'execution-receipt.json');passed=$checks.Count-$failed;failed=$failed;existing_runner_checks=$existingCheckCount;diagnostic_checks=$diagnosticCount;runner_safety_checks=$checks.Count-$existingCheckCount-$diagnosticCount;checks=$checks.ToArray();version=$context.Version;cad_runtime='NOT RUN';plugin=$receipt.plugin;plugin_sha256=$receipt.plugin_sha256;build_receipt=(Join-Path $context.Artifacts 'build-receipt.json');diagnostic_receipt=(Join-Path $context.Artifacts 'cad-diagnostics-tests.json')})
if($failed -gt 0){throw 'Source isolation or distribution layout scenario failed.'}
Set-CoreRunStatus -Run $run -Status PASS -Phase 'tests-complete'
Write-Output ($output[-1])
Write-Output ('TEST PASS: '+$context.Artifacts)
}catch{
    if($null -ne $run){
        $failure=$_.Exception.Message
        if(-not (Test-Path -LiteralPath (Join-Path $workspace.Artifacts 'test-receipt.json'))){Write-CoreJson -Path (Join-Path $workspace.Artifacts 'test-receipt.json') -Value ([ordered]@{status='FAIL';run_id=$run.Id;phase=$run.Phase;error=$failure;completed_utc=[DateTime]::UtcNow.ToString('o')})}
        Set-CoreRunStatus -Run $run -Status FAIL -Phase $run.Phase -ErrorMessage $failure
    }
    throw
}finally{if($null -ne $testEnvironment){Restore-BuildEnvironment $testEnvironment};$lease.Dispose()}
