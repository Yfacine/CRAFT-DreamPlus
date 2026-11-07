# Run receipts belong to one immutable execution directory. No user data is stored.
function Write-CoreJson {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)]$Value)
    Assert-PlainPath $Path
    if(-not [IO.Path]::GetFullPath($Path).StartsWith('D:\PASS_AI\TEST\automated\pass-ai-pro-',[StringComparison]::OrdinalIgnoreCase)){throw 'Run receipts must stay in the PRO test workspace.'}
    $temporary=$Path+'.tmp-'+[Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temporary,($Value | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($true))
    if(Test-Path -LiteralPath $Path -PathType Leaf){[IO.File]::Replace($temporary,$Path,[NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
}

function Set-CoreRunStatus {
    param([Parameter(Mandatory=$true)]$Run,[ValidateSet('STARTED','PASS','FAIL')][string]$Status,[string]$Phase,[string]$ErrorMessage='')
    $Run.Status=$Status;$Run.Phase=$Phase;$Run.UpdatedUtc=[DateTime]::UtcNow.ToString('o');$Run.Error=$ErrorMessage
    Write-CoreJson -Path (Join-Path $Run.Artifacts 'execution-receipt.json') -Value ([ordered]@{
        schema_version='1.0.0';run_id=$Run.Id;kind=$Run.Kind;status=$Run.Status;phase=$Run.Phase
        started_utc=$Run.StartedUtc;updated_utc=$Run.UpdatedUtc;error=$Run.Error;artifact_root=$Run.Artifacts
    })
}

function New-CoreRunState {
    param([Parameter(Mandatory=$true)]$Workspace,[ValidateSet('build','test')][string]$Kind)
    $previous=@(Get-ChildItem -LiteralPath $Workspace.Artifacts -Force | Where-Object Name -ne '.build.lock')
    if($previous.Count -ne 0){throw 'ArtifactRoot already contains execution data. Previous evidence is unchanged; choose a new run directory.'}
    $id=[Guid]::NewGuid().ToString('N')
    $marker=[IO.File]::Open((Join-Path $Workspace.Artifacts '.run.id'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$bytes=[Text.Encoding]::ASCII.GetBytes($id);$marker.Write($bytes,0,$bytes.Length)}finally{$marker.Dispose()}
    $run=[pscustomobject]@{Id=$id;Kind=$Kind;Artifacts=$Workspace.Artifacts;StartedUtc=[DateTime]::UtcNow.ToString('o');UpdatedUtc='';Status='STARTED';Phase='starting';Error=''}
    Set-CoreRunStatus -Run $run -Status STARTED -Phase 'starting'
    return $run
}

function Assert-CoreRunState {
    param([Parameter(Mandatory=$true)]$Run,[Parameter(Mandatory=$true)]$Workspace)
    if($Run.Artifacts -cne $Workspace.Artifacts -or $Run.Status -cne 'STARTED' -or $Run.Kind -cne 'test'){throw 'Invalid internal run owner.'}
    $marker=[IO.File]::ReadAllText((Join-Path $Workspace.Artifacts '.run.id'))
    $receipt=Get-Content -LiteralPath (Join-Path $Workspace.Artifacts 'execution-receipt.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if($marker -cne $Run.Id -or $receipt.run_id -cne $Run.Id -or $receipt.status -cne 'STARTED'){throw 'Internal run identity changed.'}
}

function Assert-CoreCompletedBuild {
    param([Parameter(Mandatory=$true)]$Build)
    if($Build.status -cne 'PASS'){throw 'Build receipt is not PASS.'}
    # Historical pinned receipts remain readable. New receipts must also bind
    # to the completed outer run, never an unfinished/failed test execution.
    if('run_id' -notin @($Build.PSObject.Properties.Name)){return}
    $expected=Join-Path $Build.artifact_root 'execution-receipt.json'
    if($Build.execution_receipt -ine $expected){throw 'Build execution receipt path mismatch.'}
    Assert-PlainPath $expected
    $state=Get-Content -LiteralPath $expected -Raw -Encoding UTF8 | ConvertFrom-Json
    if($state.run_id -cne $Build.run_id -or $state.status -cne 'PASS' -or $state.artifact_root -ine $Build.artifact_root){throw 'The owning build/test run is not a matching completed PASS.'}
}
