Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Assert-PlainPath {
    param([string]$Path)
    $cursor=[IO.Path]::GetFullPath($Path)
    while($cursor){
        $item=$null
        try{$item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop}catch [System.Management.Automation.ItemNotFoundException]{}
        if($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "Reparse point rejected: $cursor"}
        $parent=[IO.Directory]::GetParent($cursor)
        $cursor=if($null -eq $parent){''}else{$parent.FullName}
    }
}

function Get-RunWorkspace {
    param([string]$ArtifactRoot='')
    foreach($value in @($ArtifactRoot)){
        if($value -match '[^\p{L}\p{N} _.:\\/\-]'){throw 'Path contains unsupported MSBuild or shell metacharacters.'}
    }
    $root=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
    if($root -cne 'E:\CRAFT-DreamPlus'){throw 'This source checkout is assigned to E:\CRAFT-DreamPlus.'}
    Assert-PlainPath $root
    Assert-PlainTree $root
    if([string]::IsNullOrWhiteSpace($ArtifactRoot)){$ArtifactRoot=Join-Path 'D:\PASS_AI\TEST\automated' ('pass-ai-pro-build-'+[Guid]::NewGuid().ToString('N'))}
    $artifact=[IO.Path]::GetFullPath($ArtifactRoot).TrimEnd('\')
    if(-not $artifact.StartsWith('D:\PASS_AI\TEST\automated\pass-ai-pro-',[StringComparison]::OrdinalIgnoreCase)){throw 'Artifacts must remain in D:\PASS_AI\TEST\automated\pass-ai-pro-*.'}
    Assert-PlainPath $artifact
    Assert-PlainTree $artifact
    [pscustomobject]@{Root=$root;Artifacts=$artifact}
}

function Get-BuildContext {
    param([string]$ArtifactRoot='', [string]$AutoCADRoot='C:\Program Files\Autodesk\AutoCAD 2024', [string]$DotnetPath='E:\PASS_AI\.tools\pass-ai-pro\dotnet\8.0.426\dotnet.exe')
    foreach($value in @($AutoCADRoot,$DotnetPath)){
        if($value -match '[^\p{L}\p{N} _.:\\/\-]'){throw 'Path contains unsupported MSBuild or shell metacharacters.'}
    }
    $workspace=Get-RunWorkspace -ArtifactRoot $ArtifactRoot
    $root=$workspace.Root;$artifact=$workspace.Artifacts
    Assert-PlainPath $DotnetPath
    if(-not (Test-Path -LiteralPath $DotnetPath -PathType Leaf)){throw 'The approved .NET SDK 8.0.426 is missing.'}
    $version=Get-Content -LiteralPath (Join-Path $root 'version.json') -Raw | ConvertFrom-Json
    if($version.version -cnotmatch '^\d+\.\d+\.\d+$'){throw 'version.json must contain a three-part numeric version.'}
    $cad=[IO.Path]::GetFullPath($AutoCADRoot).TrimEnd('\')
    Assert-PlainPath $cad
    $refs=@()
    foreach($name in @('AcCoreMgd.dll','AcMgd.dll','AcDbMgd.dll')){
        $path=Join-Path $cad $name
        Assert-PlainPath $path
        if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw "AutoCAD managed reference is missing: $path"}
        $v=(Get-Item -LiteralPath $path).VersionInfo.FileVersion
        if($v -notlike '24.3.*'){throw "Only AutoCAD 2024 R24.3 references are supported: $path"}
        $refs+=Get-FileHash -LiteralPath $path -Algorithm SHA256 | Select-Object Path,Hash
    }
    [pscustomobject]@{Root=$root;Artifacts=$artifact;Dotnet=$DotnetPath;CadRoot=$cad;Version=[string]$version.version;References=$refs}
}

function Assert-RestoreSource {
    param([string]$ConfigPath)
    $settings=New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing=[System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver=$null
    $reader=[System.Xml.XmlReader]::Create($ConfigPath,$settings)
    try{$xml=New-Object System.Xml.XmlDocument;$xml.XmlResolver=$null;$xml.Load($reader)}finally{$reader.Dispose()}
    $sources=@($xml.SelectNodes('/configuration/packageSources/add'))
    $maps=@($xml.SelectNodes('/configuration/packageSourceMapping/packageSource'))
    if($sources.Count -ne 1 -or $sources[0].key -cne 'nuget.org' -or $sources[0].value -cne 'https://api.nuget.org/v3/index.json' -or $xml.SelectNodes('/configuration/packageSources/clear').Count -ne 1){throw 'Only the approved official NuGet source is allowed.'}
    if($maps.Count -ne 1 -or $maps[0].key -cne 'nuget.org' -or $maps[0].SelectNodes('package').Count -ne 1 -or $maps[0].package.pattern -cne 'Microsoft.NETFramework.ReferenceAssemblies.net48' -or $xml.SelectNodes('/configuration/packageSourceMapping/clear').Count -ne 1){throw 'Only the approved net48 package mapping is allowed.'}
}

function Assert-PackageLock {
    param([string]$LockPath)
    $lock=Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json
    if($lock.version -ne 1 -or @($lock.dependencies.PSObject.Properties).Count -notin @(1,2)){throw 'Unexpected NuGet lock format or target frameworks.'}
    foreach($framework in $lock.dependencies.PSObject.Properties){
        if($framework.Name -ceq '.NETFramework,Version=v4.8/win7-x64'){
            if(@($framework.Value.PSObject.Properties).Count -ne 0){throw 'The implicit executable RID entry must contain no packages.'}
            continue
        }
        if($framework.Name -cne '.NETFramework,Version=v4.8'){throw 'Only the net48 lock target is approved.'}
        $packages=0
        foreach($dependency in $framework.Value.PSObject.Properties){
            if($dependency.Value.type -eq 'Project'){
                if($dependency.Name -cne 'passaipro.core'){throw 'Unexpected project dependency.'}
                continue
            }
            $packages++
            if($dependency.Name -ine 'Microsoft.NETFramework.ReferenceAssemblies.net48' -or $dependency.Value.resolved -cne '1.0.3' -or [string]::IsNullOrWhiteSpace($dependency.Value.contentHash)){throw 'Unapproved package or absent content hash in lock file.'}
        }
        if($packages -ne 1){throw 'Exactly the approved net48 reference package is required.'}
    }
    if('.NETFramework,Version=v4.8' -cnotin @($lock.dependencies.PSObject.Properties | ForEach-Object Name)){throw 'The primary net48 lock target is missing.'}
}

function Assert-PlainTree {
    param([string]$Path)
    if(-not (Test-Path -LiteralPath $Path)){return}
    Assert-PlainPath $Path
    $queue=New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($Path)
    while($queue.Count -gt 0){
        $directory=$queue.Dequeue()
        foreach($entry in @(Get-ChildItem -LiteralPath $directory -Force)){
            if(($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "Nested reparse point rejected: $($entry.FullName)"}
            if($entry.PSIsContainer -and $entry.Name -ne '.git'){$queue.Enqueue($entry.FullName)}
        }
    }
}

function Assert-ProductLocks {
    param([Parameter(Mandatory=$true)][string]$SourceRoot)
    foreach($relative in @('src\PassAiPro.Core\packages.lock.json','src\PassAiPro.AutoCAD\packages.lock.json','tests\PassAiPro.Tests\packages.lock.json')){
        $path=Join-Path $SourceRoot $relative
        Assert-PlainPath $path
        if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw "Required package lock is missing; restore an explicitly reviewed copy before running: $relative"}
        Assert-PackageLock $path
        [pscustomobject]@{path=$path;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
    }
}

function Set-BuildEnvironment {
    param($Context)
    $values=@{
        DOTNET_CLI_HOME=(Join-Path $Context.Artifacts 'dotnet-home');DOTNET_CLI_TELEMETRY_OPTOUT='1';DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1';DOTNET_NOLOGO='1';DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='true';
        NUGET_PACKAGES=(Join-Path $Context.Artifacts 'packages');NUGET_HTTP_CACHE_PATH=(Join-Path $Context.Artifacts 'nuget-http');TEMP=(Join-Path $Context.Artifacts 'temp');TMP=(Join-Path $Context.Artifacts 'temp')
        MSBUILDDISABLENODEREUSE='1';DOTNET_CLI_USE_MSBUILD_SERVER='0'
    }
    [void][IO.Directory]::CreateDirectory($values.TEMP)
    $before=@{}
    foreach($key in $values.Keys){$before[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,$values[$key],'Process')}
    return $before
}

function Restore-BuildEnvironment {
    param([hashtable]$Before)
    foreach($key in $Before.Keys){[Environment]::SetEnvironmentVariable($key,$Before[$key],'Process')}
}

function Get-ProductSourcePins {
    param([string]$Root)
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Where-Object { $_.FullName -notmatch '\\(?:\.git|bin|obj|\.vs)\\' } | Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{path=$_.FullName.Substring($Root.Length+1).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
    })
}
