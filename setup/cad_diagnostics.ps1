# Pure decoding and diagnostic assessment: no CAD launch or filesystem changes.
function ConvertFrom-PassAiProCadBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
    $nullCount=@($Bytes | Where-Object {$_ -eq 0}).Count
    if($Bytes.Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254){
        $decoder=New-Object Text.UnicodeEncoding($false,$false,$true)
    }elseif($Bytes.Length -ge 2 -and $Bytes[0] -eq 254 -and $Bytes[1] -eq 255){
        $decoder=New-Object Text.UnicodeEncoding($true,$false,$true)
    }elseif($Bytes.Length -gt 0 -and $nullCount -gt $Bytes.Length/5){
        $decoder=New-Object Text.UnicodeEncoding($false,$false,$true)
    }else{$decoder=New-Object Text.UTF8Encoding($false,$true)}
    # Strip an encoding marker only; retain original CRLF/LF and Korean text.
    $decoder.GetString($Bytes).TrimStart([char]0xFEFF)
}

function Test-PassAiProCadDiagnostics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Stdout,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Stderr,
        [Parameter(Mandatory=$true)][string]$ExpectedVersion,
        [Parameter(Mandatory=$true)][string]$WorkRoot,
        [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$OwnedProcessId,
        [Parameter(Mandatory=$true)][bool]$ProcessExited,
        [Parameter(Mandatory=$true)][int]$ExitCode,
        [Parameter(Mandatory=$true)][bool]$TimedOut,
        [Parameter(Mandatory=$true)][bool]$TemplateAndCopyUnchanged,
        [string]$ExpectedTemplatePath='',
        [string]$ExpectedConsolePath=''
    )
    $issues=New-Object 'System.Collections.Generic.List[string]'
    if($ExpectedVersion -cnotmatch '^\d+\.\d+\.\d+$'){$issues.Add('invalid-expected-version')}
    if(-not $ProcessExited){$issues.Add('owned-process-not-exited')}
    if($ExitCode -ne 0){$issues.Add('nonzero-exit')}
    if($TimedOut){$issues.Add('timeout')}
    if(-not $TemplateAndCopyUnchanged){$issues.Add('template-or-copy-changed')}
    # No stderr output has been approved. Even non-error prose is unexpected.
    if(-not [string]::IsNullOrWhiteSpace($Stderr)){$issues.Add('unexpected-stderr')}
    if($Stdout -match '[\x00-\x08\x0B\x0C\x0E-\x1F\uFFFD]'){$issues.Add('invalid-stdout-characters')}
    $lines=@($Stdout -split '\r?\n')
    $product='PASS_AI_PRO '+$ExpectedVersion
    $hostLine='AutoCAD 2024 / Windows x64'
    $about=@($product,$hostLine)
    $status=@($product,$hostLine,'프로그램 뼈대: 진단 명령 사용 가능','MPL: 미구현 (후속 단계)','XBT: 미구현 (후속 단계)')
    $commandPattern='^(?:명령|Command):\s*(PASSAIPRO_ABOUT|PASSAIPRO_STATUS|_\.QUIT)\s*$'
    $commands=@(for($i=0;$i -lt $lines.Count;$i++){
        if($lines[$i] -match $commandPattern){[pscustomobject]@{name=$Matches[1];index=$i}}
    })
    $commandOrder=($commands | ForEach-Object {$_.name}) -join '|'
    $ordered=$commandOrder -ceq 'PASSAIPRO_ABOUT|PASSAIPRO_STATUS|_.QUIT'
    if(-not $ordered){$issues.Add('missing-duplicate-or-out-of-order-command')}
    if($ordered){
        foreach($part in @(@{index=0;expected=$about;name='about'},@{index=1;expected=$status;name='status'})){
            $start=$commands[$part.index].index+1
            $end=$commands[$part.index+1].index-1
            $actual=@(if($end -ge $start){$lines[$start..$end] | Where-Object {$_ -cne ''}})
            if(($actual -join "`n") -cne ($part.expected -join "`n")){$issues.Add('invalid-'+$part.name+'-section')}
        }
    }
    # Reject extra or conflicting diagnostics outside the expected sections too.
    $productLines=@($lines | Where-Object {$_ -match '^\s*PASS_AI_'})
    if($productLines.Count -ne 2 -or @($productLines | Where-Object {$_ -cne $product}).Count -ne 0){$issues.Add('product-version-count-or-conflict')}
    foreach($expectedLine in $status[1..4]){
        $count=@($lines | Where-Object {$_ -ceq $expectedLine}).Count
        $expectedCount=if($expectedLine -ceq $hostLine){2}else{1}
        if($count -ne $expectedCount){$issues.Add('diagnostic-line-count:'+ $expectedLine)}
    }
    $featureLines=@($lines | Where-Object {$_ -match '^\s*(MPL|XBT)\s*:'})
    if($featureLines.Count -ne 2){$issues.Add('feature-state-count-or-conflict')}
    $hostLines=@($lines | Where-Object {$_ -match '^\s*(AutoCAD\s+\d|Unsupported CAD)'})
    if($hostLines.Count -ne 2 -or @($hostLines | Where-Object {$_ -cne $hostLine}).Count -ne 0){$issues.Add('host-count-or-conflict')}
    $diagnosticLines=@($lines | Where-Object {$_ -match '^\s*프로그램 뼈대\s*:'})
    if($diagnosticLines.Count -ne 1){$issues.Add('core-state-count-or-conflict')}
    # This is the exact owned warning candidate only. Recovery still must verify
    # PID absence, successful exit, known 33-byte content and safe archive paths.
    $ownedWarning="ERROR: Can't delete temp file "+$WorkRoot.TrimEnd('\')+'\accc'+$OwnedProcessId+'2. (errno=13).'
    $cleanupWarnings=@($lines | Where-Object {$_ -ceq $ownedWarning})
    if($cleanupWarnings.Count -gt 1){$issues.Add('duplicate-engine-cleanup-warning')}
    # Words inside the exact reviewed paths are data. Remove only those path
    # spans for error classification; keep the raw lines and error prefixes.
    $reviewedPaths=@($WorkRoot.TrimEnd('\'),$ExpectedTemplatePath,$ExpectedConsolePath) | Where-Object {-not [string]::IsNullOrWhiteSpace($_)}
    $pathForms=@($reviewedPaths | ForEach-Object {$_;$_.Replace('\','/');$_.Replace('\','\\')} | Select-Object -Unique | Sort-Object Length -Descending)
    $unexpectedErrors=@(foreach($line in $lines){
        if($line -ceq $ownedWarning){continue}
        $classified=$line
        foreach($path in $pathForms){
            $classified=[regex]::Replace($classified,('(?<![\p{L}\p{N}])'+[regex]::Escape($path)+'(?=$|[\\/"\s).;])'),'<reviewed-path>',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
        if($classified -match '(?i)\b(error|exception|fatal|failed|failure|[\w.]*Exception)\b|오류|예외|실패'){$line}
    })
    if($unexpectedErrors.Count -gt 0){$issues.Add('unexpected-stdout-error')}
    $quitConfirmed=$false
    if($ordered){
        $tail=($lines[($commands[2].index)..($lines.Count-1)] -join "`n")
        $quitConfirmed=$tail -cmatch '(?m)^(?:명령|Command):\s*_\.QUIT\n_Y\n[^\n]*<N> _Y\s*$'
    }
    if(-not $quitConfirmed){$issues.Add('explicit-quit-not-confirmed')}
    [pscustomobject]@{
        ok=($issues.Count -eq 0);issues=$issues.ToArray()
        product_output_occurrences=$productLines.Count;command_sections_valid=$ordered
        explicit_quit_confirmed=$quitConfirmed;engine_cleanup_warnings=$cleanupWarnings
        unexpected_errors=$unexpectedErrors;stderr_policy='Reject every non-whitespace stderr line; raw bytes retained'
    }
}
