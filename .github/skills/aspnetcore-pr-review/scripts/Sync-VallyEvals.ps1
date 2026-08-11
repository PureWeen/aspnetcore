[CmdletBinding(DefaultParameterSetName = 'Sync')]
param(
    [Parameter(ParameterSetName = 'Check')]
    [switch] $Check,

    [Parameter(Mandatory, ParameterSetName = 'Stage')]
    [string] $StageSkills
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReviewerEvalTools.psm1') -Force

if ($PSCmdlet.ParameterSetName -eq 'Stage')
{
    $destination = Copy-SanitizedSkills -Destination $StageSkills
    Write-Host "Staged sanitized skills in $destination"
    exit 0
}

$errors = @(Sync-VallyEvalSpecs -Check:$Check)
if ($errors.Count -gt 0)
{
    $errors | ForEach-Object { Write-Error $_ }
    exit 1
}

if ($Check)
{
    Write-Host 'Vally eval specs are synchronized.'
}
else
{
    Write-Host 'Wrote reviewer and try-fix Vally eval specs.'
}
