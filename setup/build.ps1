[CmdletBinding()]
param([string]$ArtifactRoot='', [string]$AutoCADRoot='C:\Program Files\Autodesk\AutoCAD 2024', [string]$DotnetPath='E:\PASS_AI\.tools\pass-ai-pro\dotnet\8.0.426\dotnet.exe', [ValidateSet('Debug','Release')][string]$Configuration='Release', [IO.FileStream]$WorkspaceLease=$null, $RunState=$null,
      [ValidateRange(1,600)][int]$SdkTimeoutSeconds=30,[ValidateRange(1,600)][int]$RestoreTimeoutSeconds=180,[ValidateRange(1,600)][int]$BuildTimeoutSeconds=120)
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'core_run_state.ps1')
. (Join-Path $PSScriptRoot 'owned_process.ps1')
$workspace=Get-RunWorkspace -ArtifactRoot $ArtifactRoot
[void][IO.Directory]::CreateDirectory($workspace.Artifacts)
$guard=$null;$environment=$null;$pushed=$false;$ownsGuard=$false;$run=$null
try{
    $guardPath=Join-Path $workspace.Artifacts '.build.lock'
    if($null -ne $WorkspaceLease){
        if($WorkspaceLease.Name -ine $guardPath -or -not $WorkspaceLease.CanRead -or -not $WorkspaceLease.CanWrite -or $WorkspaceLease.SafeFileHandle.IsClosed){throw 'Invalid internal test workspace lease.'}
        $guard=$WorkspaceLease
        Assert-CoreRunState -Run $RunState -Workspace $workspace
        $run=$RunState
    }else{
        $guard=[IO.File]::Open($guardPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $ownsGuard=$true
        $run=New-CoreRunState -Workspace $workspace -Kind build
    }
    Set-CoreRunStatus -Run $run -Status STARTED -Phase 'build-preflight'
    $context=Get-BuildContext -ArtifactRoot $workspace.Artifacts -AutoCADRoot $AutoCADRoot -DotnetPath $DotnetPath
    Assert-RestoreSource (Join-Path $context.Root 'NuGet.config')
    $lockPins=@(Assert-ProductLocks -SourceRoot $context.Root)
    $environment=Set-BuildEnvironment $context
    Push-Location -LiteralPath $context.Root;$pushed=$true
    $sdkResult=Invoke-CoreOwnedProcess -Run $run -Step sdk-version -FilePath $context.Dotnet -Arguments @('--version') -WorkingDirectory $context.Root -TimeoutSeconds $SdkTimeoutSeconds
    $sdk=(Get-CoreProcessLog -Result $sdkResult -LogPath (Join-Path $context.Artifacts 'sdk-version.txt')).Trim()
    if($sdk -cne '8.0.426'){throw 'The exact SDK 8.0.426 is required.'}
    $props=@("-p:PassAiProArtifactsRoot=$($context.Artifacts)","-p:PassAiProVersion=$($context.Version)","-p:AutoCADManagedRoot=$($context.CadRoot)","-p:Configuration=$Configuration",'-nodeReuse:false','-p:UseSharedCompilation=false')
    Set-CoreRunStatus -Run $run -Status STARTED -Phase 'restore'
    $restore=Invoke-CoreOwnedProcess -Run $run -Step restore -FilePath $context.Dotnet -Arguments (@('restore','PASS_AI_PRO.sln','--configfile','NuGet.config','--locked-mode')+$props+@('--verbosity','minimal')) -WorkingDirectory $context.Root -TimeoutSeconds $RestoreTimeoutSeconds
    [void](Get-CoreProcessLog -Result $restore -LogPath (Join-Path $context.Artifacts 'restore-locked.txt'))
    $locksAfter=@(Assert-ProductLocks -SourceRoot $context.Root)
    if(($lockPins.sha256 -join '|') -cne ($locksAfter.sha256 -join '|')){throw 'Product package lock changed during locked restore.'}
    Set-CoreRunStatus -Run $run -Status STARTED -Phase 'compile'
    $compile=Invoke-CoreOwnedProcess -Run $run -Step compile -FilePath $context.Dotnet -Arguments (@('build','PASS_AI_PRO.sln','--no-restore','--configuration',$Configuration)+$props+@('--verbosity','minimal')) -WorkingDirectory $context.Root -TimeoutSeconds $BuildTimeoutSeconds
    [void](Get-CoreProcessLog -Result $compile -LogPath (Join-Path $context.Artifacts 'build.txt'))
    $plugin=Join-Path $context.Artifacts "bin\PassAiPro.AutoCAD\$Configuration\net48\PassAiPro.AutoCAD.dll"
    $test=Join-Path $context.Artifacts "bin\PassAiPro.Tests\$Configuration\net48\PassAiPro.Tests.exe"
    if(-not (Test-Path -LiteralPath $plugin -PathType Leaf) -or -not (Test-Path -LiteralPath $test -PathType Leaf)){throw 'Expected build artifacts missing.'}
    $copied=@(Get-ChildItem -LiteralPath (Join-Path $context.Artifacts 'bin') -Recurse -File | Where-Object Name -in @('AcCoreMgd.dll','AcMgd.dll','AcDbMgd.dll'))
    if($copied.Count -gt 0){throw 'Autodesk host assemblies must not be copied into product artifacts.'}
    $core=Join-Path (Split-Path -Parent $plugin) 'PassAiPro.Core.dll'
    $package=Join-Path $context.Artifacts 'packages\microsoft.netframework.referenceassemblies.net48\1.0.3\microsoft.netframework.referenceassemblies.net48.1.0.3.nupkg'
    $receipt=[ordered]@{status='PASS';run_id=$run.Id;completed_utc=[DateTime]::UtcNow.ToString('o');execution_receipt=(Join-Path $context.Artifacts 'execution-receipt.json');scope='net48 compilation only; CAD NOT RUN';version=$context.Version;sdk=$sdk;artifact_root=$context.Artifacts;plugin=$plugin;test_executable=$test;plugin_sha256=(Get-FileHash -LiteralPath $plugin -Algorithm SHA256).Hash;core_sha256=(Get-FileHash -LiteralPath $core -Algorithm SHA256).Hash;reference_package_sha256=(Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash;host_references=$context.References;source_pins=(Get-ProductSourcePins $context.Root);locked_restore=$true;autodesk_assemblies_copied=0}
    Write-CoreJson -Path (Join-Path $context.Artifacts 'build-receipt.json') -Value $receipt
    if($ownsGuard){Set-CoreRunStatus -Run $run -Status PASS -Phase 'build-complete'}
    Write-Output ('BUILD PASS: '+$plugin)
}catch{
    if($null -ne $run){
        $failure=$_.Exception.Message
        Write-CoreJson -Path (Join-Path $workspace.Artifacts 'build-receipt.json') -Value ([ordered]@{status='FAIL';run_id=$run.Id;phase=$run.Phase;error=$failure;completed_utc=[DateTime]::UtcNow.ToString('o');artifact_root=$workspace.Artifacts})
        Set-CoreRunStatus -Run $run -Status FAIL -Phase $run.Phase -ErrorMessage $failure
    }
    throw
}finally{
    if($pushed){Pop-Location}
    if($null -ne $environment){Restore-BuildEnvironment $environment}
    if($ownsGuard -and $null -ne $guard){$guard.Dispose()}
}
