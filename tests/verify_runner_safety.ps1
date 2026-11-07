function Invoke-PassAiProRunnerSafetyTests {
    param([Parameter(Mandatory=$true)][string]$ArtifactRoot)
    $checks=New-Object 'System.Collections.Generic.List[object]'
    $base=Join-Path $ArtifactRoot 'runner-safety'
    [void][IO.Directory]::CreateDirectory($base)
    $source=Split-Path -Parent $PSScriptRoot
    $completed=Join-Path $base 'completed'
    [void][IO.Directory]::CreateDirectory($completed)
    $run=New-CoreRunState -Workspace ([pscustomobject]@{Artifacts=$completed}) -Kind build
    $started=Get-Content (Join-Path $completed 'execution-receipt.json') -Raw | ConvertFrom-Json
    $checks.Add([pscustomobject]@{name='runner-started-with-unique-id-and-time';ok=($started.status -ceq 'STARTED' -and $started.run_id.Length -eq 32 -and -not [string]::IsNullOrWhiteSpace($started.started_utc))})
    Set-CoreRunStatus -Run $run -Status PASS -Phase 'fixture-complete'
    $receiptPath=Join-Path $completed 'execution-receipt.json'
    $before=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash
    $rejected=$false
    try{& (Join-Path $source 'setup\build.ps1') -ArtifactRoot $completed}catch{$rejected=$_.Exception.Message -like '*already contains execution data*'}
    $checks.Add([pscustomobject]@{name='runner-reuse-rejected-old-pass-preserved';ok=($rejected -and (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash -ceq $before)})
    $completedBuild=[pscustomobject]@{status='PASS';run_id=$run.Id;artifact_root=$completed;execution_receipt=$receiptPath}
    $accepted=$true
    try{Assert-CoreCompletedBuild -Build $completedBuild}catch{$accepted=$false}
    $checks.Add([pscustomobject]@{name='runner-completed-build-consumer-accepts-matching-pass';ok=$accepted})
    Set-CoreRunStatus -Run $run -Status FAIL -Phase 'expected-consumer-refusal' -ErrorMessage 'test fixture'
    $rejected=$false
    try{Assert-CoreCompletedBuild -Build $completedBuild}catch{$rejected=$true}
    $checks.Add([pscustomobject]@{name='runner-build-pass-cannot-hide-owning-run-failure';ok=$rejected})
    $rejected=$false
    try{Assert-CoreCompletedBuild -Build (Get-Content (Join-Path $ArtifactRoot 'build-receipt.json') -Raw | ConvertFrom-Json)}catch{$rejected=$true}
    $checks.Add([pscustomobject]@{name='runner-build-pass-cannot-hide-unfinished-test-run';ok=$rejected})
    $failed=Join-Path $base 'actual-build-failure'
    $rejected=$false
    try{& (Join-Path $source 'setup\build.ps1') -ArtifactRoot $failed -DotnetPath (Join-Path $base 'absent-sdk.exe')}catch{$rejected=$true}
    $state=Get-Content (Join-Path $failed 'execution-receipt.json') -Raw | ConvertFrom-Json
    $build=Get-Content (Join-Path $failed 'build-receipt.json') -Raw | ConvertFrom-Json
    $checks.Add([pscustomobject]@{name='runner-actual-build-error-is-current-fail';ok=($rejected -and $state.status -ceq 'FAIL' -and $build.status -ceq 'FAIL' -and $state.run_id -ceq $build.run_id -and $state.run_id -cne $run.Id)})
    $failedTest=Join-Path $base 'actual-test-preflight-failure'
    $rejected=$false
    try{& (Join-Path $source 'setup\run_tests.ps1') -ArtifactRoot $failedTest -DotnetPath (Join-Path $base 'absent-sdk.exe')}catch{$rejected=$true}
    $state=Get-Content (Join-Path $failedTest 'execution-receipt.json') -Raw | ConvertFrom-Json
    $test=Get-Content (Join-Path $failedTest 'test-receipt.json') -Raw | ConvertFrom-Json
    $checks.Add([pscustomobject]@{name='runner-actual-test-error-is-current-fail';ok=($rejected -and $state.status -ceq 'FAIL' -and $test.status -ceq 'FAIL' -and $state.run_id -ceq $test.run_id)})
    $checks.Add([pscustomobject]@{name='runner-receipt-update-leaves-no-partial-json';ok=(@(Get-ChildItem -LiteralPath $base -Recurse -File -Filter '*.tmp-*').Count -eq 0)})
    $lockPaths=@('src\PassAiPro.Core\packages.lock.json','src\PassAiPro.AutoCAD\packages.lock.json','tests\PassAiPro.Tests\packages.lock.json')
    $originalPins=@(Assert-ProductLocks -SourceRoot $source)
    foreach($missing in $lockPaths){
        $fixture=Join-Path $base ('missing-lock-'+$checks.Count)
        [void][IO.Directory]::CreateDirectory($fixture)
        foreach($relative in $lockPaths){
            if($relative -ceq $missing){continue}
            $target=Join-Path $fixture $relative
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
            Copy-Item -LiteralPath (Join-Path $source $relative) -Destination $target
        }
        $rejected=$false
        try{[void]@(Assert-ProductLocks -SourceRoot $fixture)}catch{$rejected=$_.Exception.Message -like '*Required package lock is missing*'}
        $checks.Add([pscustomobject]@{name=('runner-missing-lock-rejected-without-recreation-'+$checks.Count);ok=($rejected -and -not (Test-Path -LiteralPath (Join-Path $fixture $missing)))})
    }
    $valid=Join-Path $base 'valid-locks'
    foreach($relative in $lockPaths){$target=Join-Path $valid $relative;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $target));Copy-Item -LiteralPath (Join-Path $source $relative) -Destination $target}
    $validPins=@(Assert-ProductLocks -SourceRoot $valid)
    $checks.Add([pscustomobject]@{name='runner-three-reviewed-locks-accepted';ok=($validPins.Count -eq 3)})
    $bad=Join-Path $valid $lockPaths[0]
    [IO.File]::WriteAllText($bad,[IO.File]::ReadAllText($bad).Replace('"resolved": "1.0.3"','"resolved": "9.0.0"'))
    $rejected=$false
    try{[void]@(Assert-ProductLocks -SourceRoot $valid)}catch{$rejected=$true}
    $checks.Add([pscustomobject]@{name='runner-invalid-lock-rejected-before-tool-use';ok=$rejected})
    $currentPins=@(Assert-ProductLocks -SourceRoot $source)
    $checks.Add([pscustomobject]@{name='runner-product-locks-remain-unchanged';ok=(($originalPins.sha256 -join '|') -ceq ($currentPins.sha256 -join '|'))})
    $processRoot=Join-Path $base 'process-cases'
    [void][IO.Directory]::CreateDirectory($processRoot)
    $processRun=New-CoreRunState -Workspace ([pscustomobject]@{Artifacts=$processRoot}) -Kind build
    $hostExe=Join-Path $PSHOME $(if($PSVersionTable.PSEdition -eq 'Core'){'pwsh.exe'}else{'powershell.exe'})
    $probe=Join-Path $PSScriptRoot 'fixtures\process_probe.ps1'
    $common=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$probe)
    $echo=([string][char]0xD55C)+([string][char]0xAE00)+' space "quoted" trailing\'
    $normal=Invoke-CoreOwnedProcess -Run $processRun -Step normal -FilePath $hostExe -Arguments ($common+@('-Mode','success','-Echo',$echo)) -WorkingDirectory $processRoot -TimeoutSeconds 20
    $normalText=Get-CoreProcessLog -Result $normal
    $checks.Add([pscustomobject]@{name='runner-real-process-success-and-argument-fidelity';ok=($normal.status -ceq 'PASS' -and $normalText.Contains($echo) -and $normal.cleanup_success -and $normal.remaining_owned_processes -eq 0)})
    $failure=Invoke-CoreOwnedProcess -Run $processRun -Step failure -FilePath $hostExe -Arguments ($common+@('-Mode','failure')) -WorkingDirectory $processRoot -TimeoutSeconds 20
    $checks.Add([pscustomobject]@{name='runner-real-nonzero-exit-and-stderr-preserved';ok=($failure.status -ceq 'FAIL' -and -not $failure.timed_out -and $failure.exit_code -eq 7 -and (Get-Item -LiteralPath $failure.stderr).Length -gt 0 -and $failure.remaining_owned_processes -eq 0)})
    $witnessMarker=Join-Path $processRoot 'witness.pid'
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$hostExe
    $start.Arguments=ConvertTo-CoreNativeArguments ($common+@('-Mode','witness','-Marker',$witnessMarker))
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $witness=[Diagnostics.Process]::Start($start)
    try{
        $marker=Join-Path $processRoot 'tree.pid'
        $timeout=Invoke-CoreOwnedProcess -Run $processRun -Step timeout-tree -FilePath $hostExe -Arguments ($common+@('-Mode','tree','-Marker',$marker)) -WorkingDirectory $processRoot -TimeoutSeconds 4
        $parentId=[int][IO.File]::ReadAllText($marker);$childId=[int][IO.File]::ReadAllText($marker+'.child')
        $checks.Add([pscustomobject]@{name='runner-real-timeout-terminates-owned-parent-and-child';ok=($timeout.status -ceq 'FAIL' -and $timeout.timed_out -and $timeout.exit_code -eq 124 -and $timeout.cleanup_success -and $timeout.remaining_owned_processes -eq 0 -and $null -eq (Get-Process -Id $parentId -ErrorAction SilentlyContinue) -and $null -eq (Get-Process -Id $childId -ErrorAction SilentlyContinue))})
        $checks.Add([pscustomobject]@{name='runner-timeout-keeps-separate-witness-alive';ok=(-not $witness.HasExited)})
        $checks.Add([pscustomobject]@{name='runner-timeout-within-step-and-cleanup-budget';ok=($timeout.seconds -lt 15)})
        $rejected=$false
        try{[void](Get-CoreProcessLog -Result $timeout)}catch{$rejected=$true}
        $checks.Add([pscustomobject]@{name='runner-timeout-result-stops-calling-pipeline';ok=$rejected})
    }finally{if(-not $witness.HasExited){$witness.Kill();[void]$witness.WaitForExit(10000)};$witness.Dispose()}
    $notStarted=Invoke-CoreOwnedProcess -Run $processRun -Step start-failure -FilePath (Join-Path $base 'does-not-exist.exe') -WorkingDirectory $processRoot -TimeoutSeconds 20
    $checks.Add([pscustomobject]@{name='runner-start-failure-is-fail-with-no-owned-survivors';ok=($notStarted.status -ceq 'FAIL' -and $notStarted.exit_code -eq 125 -and -not [string]::IsNullOrEmpty($notStarted.error) -and $notStarted.cleanup_success -and $notStarted.remaining_owned_processes -eq 0)})
    Write-CoreJson -Path (Join-Path $ArtifactRoot 'runner-safety-tests.json') -Value ([ordered]@{scope='real owned process success/failure/timeout-tree, receipts and missing locks; CAD NOT RUN';checks=$checks.ToArray()})
    $checks.ToArray()
}
