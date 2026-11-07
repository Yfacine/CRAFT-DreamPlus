[CmdletBinding()]
param([string]$AutoCADRoot='C:\Program Files\Autodesk\AutoCAD 2024', [string]$DotnetPath='E:\PASS_AI\.tools\pass-ai-pro\dotnet\8.0.426\dotnet.exe')
$ErrorActionPreference='Stop'
[ordered]@{product='PASS_AI_PRO';source_root=(Split-Path -Parent $PSScriptRoot);sdk_exists=(Test-Path -LiteralPath $DotnetPath -PathType Leaf);sdk_path=$DotnetPath;cad_exists=(Test-Path -LiteralPath (Join-Path $AutoCADRoot 'acad.exe') -PathType Leaf);cad_root=$AutoCADRoot;cad_execution='NOT RUN';target='net48 / AutoCAD 2024 R24.3 / x64'} | ConvertTo-Json
