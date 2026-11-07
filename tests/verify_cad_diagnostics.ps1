function Invoke-PassAiProCadDiagnosticTests {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ArtifactRoot,[Parameter(Mandatory=$true)][string]$Version)
    . (Join-Path $PSScriptRoot '..\setup\cad_diagnostics.ps1')
    $checks=New-Object 'System.Collections.Generic.List[object]'
    $cases=New-Object 'System.Collections.Generic.List[object]'
    $work=Join-Path $ArtifactRoot 'diagnostic-fixture'
    $owned=2147483647
    $product='PASS_AI_PRO '+$Version
    $hostLine='AutoCAD 2024 / Windows x64'
    $diagnostic='프로그램 뼈대: 진단 명령 사용 가능'
    $mpl='MPL: 미구현 (후속 단계)';$xbt='XBT: 미구현 (후속 단계)'
    $about=@('명령: PASSAIPRO_ABOUT','',$product,$hostLine,'') -join "`n"
    $status=@('명령: PASSAIPRO_STATUS','',$product,$hostLine,$diagnostic,$mpl,$xbt,'') -join "`n"
    $quit="명령: _.QUIT`n_Y`n정말 도면의 전체 변경 사항을 버리겠습니까? <N> _Y`n`n명령:`n**** 시스템 변수가 변경되지 않음 ****"
    $normal=$about+"`n"+$status+"`n"+$quit
    function Add-DiagnosticCase([string]$Name,[string]$Text,[bool]$Expected,[string]$Issue='',[hashtable]$Overrides=@{}){
        $arguments=@{Stdout=$Text;Stderr='';ExpectedVersion=$Version;WorkRoot=$work;OwnedProcessId=$owned;ProcessExited=$true;ExitCode=0;TimedOut=$false;TemplateAndCopyUnchanged=$true}
        foreach($key in $Overrides.Keys){$arguments[$key]=$Overrides[$key]}
        $result=Test-PassAiProCadDiagnostics @arguments
        $ok=$result.ok -eq $Expected -and ($Issue -ceq '' -or $Issue -cin $result.issues)
        $checks.Add([pscustomobject]@{name=('cad-diagnostic-'+$Name);ok=$ok})
        $cases.Add([pscustomobject]@{name=$Name;expected_accept=$Expected;required_issue=$Issue;matches_expectation=$ok;inputs=$arguments;assessment=$result})
    }
    Add-DiagnosticCase 'normal-korean-lf' $normal $true
    Add-DiagnosticCase 'normal-korean-crlf' ($normal.Replace("`n","`r`n")) $true
    Add-DiagnosticCase 'normal-english-command-prompts' ($normal.Replace('명령:','Command:')) $true
    Add-DiagnosticCase 'normal-empty-stderr' $normal $true '' @{Stderr="`r`n `t"}
    foreach($pathWord in @('failed-control','error-control','오류검토','예외검토')){
        $pathWork='D:\PASS_AI\TEST\automated\pass-ai-pro-'+$pathWord+'\cad-smoke-owned'
        $pathTemplate='D:\PASS_AI\TEST\automated\pass-ai-pro-'+$pathWord+'\template.dwt'
        $pathEngine='C:\AutoCAD\'+$pathWord+'\accoreconsole.exe'
        $prefix=@(('Current Directory: '+$pathWork),$pathEngine,('Input: '+$pathTemplate),('명령: (setvar "TRUSTEDPATHS" "'+$pathWork.Replace('\','/')+'/plugin")'),('조립품 파일 이름: "'+$pathWork.Replace('\','/')+'/plugin/PassAiPro.AutoCAD.dll"'),('"C:\\old;'+$pathWork.Replace('\','/')+'/plugin"')) -join "`n"
        $overrides=@{WorkRoot=$pathWork;ExpectedTemplatePath=$pathTemplate;ExpectedConsolePath=$pathEngine}
        Add-DiagnosticCase ('normal-path-'+$pathWord) ($prefix+"`n"+$normal) $true '' $overrides
        Add-DiagnosticCase ('real-error-with-path-'+$pathWord) ($prefix+"`n"+$normal+"`nERROR: failed loading "+$pathWork+'\plugin\PassAiPro.AutoCAD.dll') $false 'unexpected-stdout-error' $overrides
    }
    Add-DiagnosticCase 'missing-output' '' $false 'missing-duplicate-or-out-of-order-command'
    Add-DiagnosticCase 'command-echo-only' "명령: PASSAIPRO_ABOUT`n명령: PASSAIPRO_STATUS`n$quit" $false 'invalid-about-section'
    Add-DiagnosticCase 'unscoped-old-normal-control' "$product`n$hostLine`n$product`n$hostLine`n$diagnostic`n$mpl`n$xbt`n$quit" $false 'missing-duplicate-or-out-of-order-command'
    Add-DiagnosticCase 'historical-missing-values' "$product`n$product`nMPL:`nXBT:`n$quit" $false 'missing-duplicate-or-out-of-order-command'
    Add-DiagnosticCase 'historical-available-wrong-host' "$product`n$product`nUnsupported CAD`nMPL: 사용 가능`nXBT: 사용 가능`n$quit" $false 'missing-duplicate-or-out-of-order-command'
    foreach($line in @($product,$hostLine,$diagnostic,$mpl,$xbt)){
        $label=if($line -ceq $product){'product'}elseif($line -ceq $hostLine){'host'}elseif($line -ceq $diagnostic){'diagnostic'}elseif($line -ceq $mpl){'mpl'}else{'xbt'}
        Add-DiagnosticCase ('missing-'+$label) ($normal.Replace($line,'')) $false
        Add-DiagnosticCase ('duplicate-'+$label) ($normal.Replace($line,($line+"`n"+$line))) $false
    }
    Add-DiagnosticCase 'wrong-product' ($normal.Replace('PASS_AI_PRO ','PASS_AI_FIRE ')) $false 'product-version-count-or-conflict'
    Add-DiagnosticCase 'wrong-version' ($normal.Replace($Version,'99.98.97')) $false 'product-version-count-or-conflict'
    Add-DiagnosticCase 'wrong-about-version-only' (($about.Replace($Version,'99.98.97'))+"`n"+$status+"`n"+$quit) $false 'invalid-about-section'
    Add-DiagnosticCase 'wrong-status-version-only' ($about+"`n"+($status.Replace($Version,'99.98.97'))+"`n"+$quit) $false 'invalid-status-section'
    Add-DiagnosticCase 'wrong-host-year' ($normal.Replace('AutoCAD 2024','AutoCAD 2025')) $false 'invalid-about-section'
    Add-DiagnosticCase 'wrong-host-platform' ($normal.Replace('Windows x64','Windows x86')) $false 'invalid-about-section'
    Add-DiagnosticCase 'wrong-status-host-only' ($about+"`n"+($status.Replace($hostLine,'Unsupported CAD'))+"`n"+$quit) $false 'invalid-status-section'
    Add-DiagnosticCase 'wrong-diagnostic' ($normal.Replace($diagnostic,'프로그램 뼈대: 사용 불가')) $false 'invalid-status-section'
    Add-DiagnosticCase 'missing-state-values' ($normal.Replace($mpl,'MPL:').Replace($xbt,'XBT:')) $false 'invalid-status-section'
    Add-DiagnosticCase 'available-states' ($normal.Replace('미구현 (후속 단계)','사용 가능')) $false 'invalid-status-section'
    Add-DiagnosticCase 'conflicting-state-after-quit' ($normal+"`nMPL: 사용 가능") $false 'feature-state-count-or-conflict'
    Add-DiagnosticCase 'extra-product-after-quit' ($normal+"`nPASS_AI_FIRE 0.1.0") $false 'product-version-count-or-conflict'
    Add-DiagnosticCase 'extra-lowercase-product-after-quit' ($normal+"`npass_ai_pro 99.98.97") $false 'product-version-count-or-conflict'
    Add-DiagnosticCase 'conflicting-host-after-quit' ($normal+"`nAutoCAD 2025 / Windows x64") $false 'host-count-or-conflict'
    Add-DiagnosticCase 'conflicting-unsupported-host-after-quit' ($normal+"`nUnsupported CAD") $false 'host-count-or-conflict'
    Add-DiagnosticCase 'conflicting-core-state-after-quit' ($normal+"`n프로그램 뼈대: 사용 불가") $false 'core-state-count-or-conflict'
    Add-DiagnosticCase 'extra-lowercase-command' ($normal+"`n명령: passaipro_about") $false 'missing-duplicate-or-out-of-order-command'
    Add-DiagnosticCase 'wrong-case' ($normal.Replace('PASS_AI_PRO ','pass_ai_pro ')) $false 'invalid-about-section'
    Add-DiagnosticCase 'prefix-product-only' ($normal.Replace($product,($product+'0'))) $false 'product-version-count-or-conflict'
    Add-DiagnosticCase 'swapped-commands' ($status+"`n"+$about+"`n"+$quit) $false 'missing-duplicate-or-out-of-order-command'
    Add-DiagnosticCase 'duplicate-about-command' ($about+"`n"+$normal) $false 'missing-duplicate-or-out-of-order-command'
    Add-DiagnosticCase 'missing-status-command' ($normal.Replace('명령: PASSAIPRO_STATUS','')) $false 'missing-duplicate-or-out-of-order-command'
    Add-DiagnosticCase 'extra-command-in-section' ($normal.Replace($diagnostic,('명령: UNEXPECTED'+"`n"+$diagnostic))) $false 'invalid-status-section'
    Add-DiagnosticCase 'output-in-wrong-section' ($about+"`n"+$mpl+"`n"+$status+"`n"+$quit) $false 'invalid-about-section'
    Add-DiagnosticCase 'missing-quit' ($about+"`n"+$status) $false 'explicit-quit-not-confirmed'
    Add-DiagnosticCase 'quit-no-discards' ($normal.Replace('<N> _Y','<N> _N')) $false 'explicit-quit-not-confirmed'
    Add-DiagnosticCase 'quit-echo-only' ($normal.Replace('정말 도면의 전체 변경 사항을 버리겠습니까? <N> _Y','')) $false 'explicit-quit-not-confirmed'
    Add-DiagnosticCase 'timeout' $normal $false 'timeout' @{TimedOut=$true}
    Add-DiagnosticCase 'nonzero-exit' $normal $false 'nonzero-exit' @{ExitCode=1}
    Add-DiagnosticCase 'still-running' $normal $false 'owned-process-not-exited' @{ProcessExited=$false}
    Add-DiagnosticCase 'original-or-copy-mutated' $normal $false 'template-or-copy-changed' @{TemplateAndCopyUnchanged=$false}
    foreach($errorLine in @('ERROR: unexpected','error: lower-case','prefix ERROR: embedded','System.InvalidOperationException: bad','Unhandled exception: bad','fatal: bad','failed to load','오류: 실패','예외가 발생했습니다')){
        Add-DiagnosticCase ('stdout-error-'+$checks.Count) ($normal+"`n"+$errorLine) $false 'unexpected-stdout-error'
    }
    foreach($errorLine in @('ERROR: stderr failure','System.Exception: stderr','임의의 표준 오류 출력')){
        Add-DiagnosticCase ('stderr-output-'+$checks.Count) $normal $false 'unexpected-stderr' @{Stderr=$errorLine}
    }
    Add-DiagnosticCase 'null-in-stdout' ($normal+[char]0) $false 'invalid-stdout-characters'
    Add-DiagnosticCase 'replacement-character' ($normal+[char]0xFFFD) $false 'invalid-stdout-characters'
    $warning="ERROR: Can't delete temp file "+$work+'\accc'+$owned+'2. (errno=13).'
    Add-DiagnosticCase 'exact-owned-warning-candidate' ($normal+"`n"+$warning) $true
    Add-DiagnosticCase 'warning-wrong-pid' ($normal+"`n"+$warning.Replace([string]$owned,'123')) $false 'unexpected-stdout-error'
    Add-DiagnosticCase 'warning-wrong-directory' ($normal+"`n"+$warning.Replace('diagnostic-fixture','other-fixture')) $false 'unexpected-stdout-error'
    Add-DiagnosticCase 'warning-wrong-content' ($normal+"`n"+$warning.Replace('errno=13','errno=2')) $false 'unexpected-stdout-error'
    Add-DiagnosticCase 'warning-in-stderr' $normal $false 'unexpected-stderr' @{Stderr=$warning}
    Add-DiagnosticCase 'warning-duplicate' ($normal+"`n"+$warning+"`n"+$warning) $false 'duplicate-engine-cleanup-warning'
    Add-DiagnosticCase 'warning-and-other-error' ($normal+"`n"+$warning+"`nERROR: other") $false 'unexpected-stdout-error'
    foreach($encodingName in @('utf8','utf8-bom','utf16le','utf16le-bom','utf16be-bom')){
        $encoding=switch($encodingName){
            'utf8' {New-Object Text.UTF8Encoding($false,$true)}
            'utf8-bom' {New-Object Text.UTF8Encoding($true,$true)}
            'utf16le' {New-Object Text.UnicodeEncoding($false,$false,$true)}
            'utf16le-bom' {New-Object Text.UnicodeEncoding($false,$true,$true)}
            'utf16be-bom' {New-Object Text.UnicodeEncoding($true,$true,$true)}
        }
        foreach($newline in @("`n","`r`n")){
            $original=$normal.Replace("`n",$newline)
            $decoded=ConvertFrom-PassAiProCadBytes -Bytes ($encoding.GetPreamble()+$encoding.GetBytes($original))
            $assessment=Test-PassAiProCadDiagnostics -Stdout $decoded -Stderr '' -ExpectedVersion $Version -WorkRoot $work -OwnedProcessId $owned -ProcessExited $true -ExitCode 0 -TimedOut $false -TemplateAndCopyUnchanged $true
            $checks.Add([pscustomobject]@{name=('cad-decode-'+$encodingName+'-'+$newline.Length);ok=($decoded -ceq $original -and $assessment.ok)})
        }
    }
    foreach($badBytes in @(@(0xC3,0x28),@(0xFF,0xFE,0x41))){
        $rejected=$false
        try{[void](ConvertFrom-PassAiProCadBytes -Bytes ([byte[]]$badBytes))}catch{$rejected=$true}
        $checks.Add([pscustomobject]@{name=('cad-decode-invalid-'+$checks.Count);ok=$rejected})
    }
    $checks.Add([pscustomobject]@{name='cad-decode-empty-stderr';ok=((ConvertFrom-PassAiProCadBytes -Bytes ([byte[]]@())) -ceq '')})
    [ordered]@{scope='offline synthetic diagnostics; CAD NOT RUN; warning acceptance requires separate safe recovery';version=$Version;checks=$checks.ToArray();cases=$cases.ToArray()} | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $ArtifactRoot 'cad-diagnostics-tests.json') -Encoding utf8
    $checks.ToArray()
}
