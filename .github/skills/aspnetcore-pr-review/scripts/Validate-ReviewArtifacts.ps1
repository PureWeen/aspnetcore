[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string] $ArtifactRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReviewerEvalTools.psm1') -Force

$errors = @(Test-ReviewArtifacts -Root $ArtifactRoot)
if ($errors.Count -gt 0)
{
    $errors | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host 'ASP.NET Core review artifacts are complete and calibrated.'
