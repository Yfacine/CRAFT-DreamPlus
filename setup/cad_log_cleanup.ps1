function Complete-PassAiProOwnedEngineLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$WorkRoot,
        [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$OwnedProcessId,
        [Parameter(Mandatory=$true)][bool]$ProcessExited,
        [Parameter(Mandatory=$true)][int]$ExitCode,
        [bool]$TimedOut=$false,
        [Parameter(Mandatory=$true)][string]$WarningLine
    )
    # This is post-exit recovery of an exact known engine log, not suppression
    # of the native warning. Unknown content and ownership stay untouched.
    $work=[IO.Path]::GetFullPath($WorkRoot).TrimEnd('\')
    if(-not $work.StartsWith('D:\PASS_AI\TEST\automated\pass-ai-pro-',[StringComparison]::OrdinalIgnoreCase)){throw 'Engine log cleanup must remain in the owned D test workspace.'}
    Assert-PlainPath $work
    if(-not $ProcessExited -or $ExitCode -ne 0 -or $TimedOut){throw 'Engine log cleanup requires a successful completed child.'}
    if($null -ne (Get-Process -Id $OwnedProcessId -ErrorAction SilentlyContinue)){throw 'Engine log cleanup refused: owned PID is still present.'}
    $name='accc'+$OwnedProcessId+'2'
    $source=Join-Path $work $name
    $expectedWarning="ERROR: Can't delete temp file "+$source+'. (errno=13).'
    if($WarningLine -cne $expectedWarning){throw 'Engine log warning does not match the exact owned PID and path.'}
    Assert-PlainPath $source
    $knownSha='9E5BD9A8B1D7E1538D41A06C9F65743121BEDA95F7380F55A78A2D506E51F896'
    $archiveRoot=Join-Path $work 'preserved-engine-logs'
    $archive=Join-Path $archiveRoot ($name+'.txt')
    Assert-PlainPath $archive
    if(-not (Test-Path -LiteralPath $source -PathType Leaf)){
        if((Test-Path -LiteralPath $archive -PathType Leaf) -and (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ceq $knownSha){
            return [pscustomobject]@{status='ALREADY_ARCHIVED';source=$source;archive=$archive;sha256=$knownSha;removed=$true;native_warning_preserved=$true}
        }
        throw 'Engine log source is missing without a verified archive.'
    }
    $item=Get-Item -LiteralPath $source -Force
    if($item.IsReadOnly -or $item.Length -ne 33){throw 'Engine log attributes or length differ; leave the source untouched.'}
    $sourceHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    if($sourceHash -cne $knownSha){throw 'Unknown engine log content; leave the source untouched.'}
    if(Test-Path -LiteralPath $archive){throw 'Refuse to overwrite an existing engine log archive.'}
    [void][IO.Directory]::CreateDirectory($archiveRoot)
    [IO.File]::Copy($source,$archive,$false)
    if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $sourceHash -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -cne $sourceHash){throw 'Engine log archive/source identity changed; source retained.'}
    # Remove one caller-owned file only after its exact original is preserved.
    Remove-Item -LiteralPath $source -ErrorAction Stop
    if(Test-Path -LiteralPath $source){throw 'Engine log cleanup did not remove the owned temporary file.'}
    [pscustomobject]@{status='ARCHIVED_AND_REMOVED_AFTER_EXIT';source=$source;archive=$archive;sha256=$sourceHash;removed=$true;native_warning_preserved=$true}
}
