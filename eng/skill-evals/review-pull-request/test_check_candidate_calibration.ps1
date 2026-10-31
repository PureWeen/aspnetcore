#requires -Version 7.0

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

$checker = Join-Path $PSScriptRoot 'check_candidate_calibration.ps1'
$fixtureRoot = Join-Path $PSScriptRoot 'fixtures/candidate-calibration'
$fakeRunId = '11111111-1111-1111-1111-111111111111'
$frozenSkillBlob = 'b11fe9fe79b5d848687ba1c93362f4aaf22bfe53'
$frozenNativeSkillBodyHash = '3a38f1385e455e104ebec8bffe280b6b90f6ef08f43131d4fe559c61d3ce1225'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$skillRelativePath = '.github/skills/review-pull-request/SKILL.md'
$actualSkillBlob = & git -C $repositoryRoot hash-object --path=$skillRelativePath -- $skillRelativePath
$skillHashExitCode = $LASTEXITCODE
if ($skillHashExitCode -ne 0 -or ($actualSkillBlob -join '') -ne $frozenSkillBlob) {
    throw "The working-tree review skill does not match frozen Git blob $frozenSkillBlob."
}
$skillText = (Get-Content (
    Join-Path $repositoryRoot $skillRelativePath
) -Raw).Replace("`r`n", "`n").Replace("`r", "`n")
$frozenNativeSkillBody = [regex]::Replace(
    $skillText,
    '\A---\n.*?\n---\n+',
    '',
    [Text.RegularExpressions.RegexOptions]::Singleline
)
$frozenNativeSkillBodyBytes = [Text.Encoding]::UTF8.GetBytes($frozenNativeSkillBody)
$actualFrozenNativeSkillBodyHash = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData($frozenNativeSkillBodyBytes)
).ToLowerInvariant()
if ($actualFrozenNativeSkillBodyHash -ne $frozenNativeSkillBodyHash) {
    throw 'The checkout review skill no longer matches the frozen calibration skill body.'
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'aspnetcore-candidate-calibration-test-' + [guid]::NewGuid().ToString('N')
)

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$ExpectedMessage,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )

    $threw = $false
    try {
        & $Action
    } catch {
        $threw = $true
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") {
            throw "Expected failure containing '$ExpectedMessage'; got '$($_.Exception.Message)'."
        }
    }
    if (-not $threw) {
        throw $FailureMessage
    }
}

function New-FakeResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Status = 'success',
        [string]$Output = 'PATH: single-reviewer',
        [switch]$NullScore,
        [switch]$FailPromptGrade,
        [switch]$FailToolGrade,
        [switch]$FailSkillResult,
        [switch]$OmitSkillActivation,
        [switch]$SkillNotFirst,
        [switch]$IncompleteGuideResult,
        [switch]$WrongSkillBody,
        [switch]$TruncatedSkillBody,
        [switch]$NullIndividualScore
    )

    $packet = $Name.Substring('line77-'.Length)
    $packet = $packet.Substring(0, $packet.Length - '-baseline'.Length)
    $manifest = Get-Content (
        Join-Path $fixtureRoot "$packet/baseline/bundle/manifest.json"
    ) -Raw | ConvertFrom-Json -Depth 100
    $events = [Collections.Generic.List[object]]::new()
    if ($SkillNotFirst) {
        $events.Add(@{
            type = 'tool_call'
            data = @{
                toolName = 'view'
                toolCallId = 'premature-view'
                turnId = '0'
                arguments = @{ path = 'C:\temp\calibration\bundle\manifest.json' }
            }
            turn = 0
        })
        $events.Add(@{
            type = 'tool_result'
            data = @{
                toolName = 'view'
                toolCallId = 'premature-view'
                success = $true
                result = @{ content = '{}' }
            }
            turn = 0
        })
    }
    $events.Add(@{
        type = 'tool_call'
        data = @{
            toolName = 'skill'
            toolCallId = 'skill-call'
            turnId = '0'
            arguments = @{ skill = 'review-pull-request' }
        }
        turn = 0
    })
    $events.Add(@{
        type = 'tool_result'
        data = @{
            toolName = 'skill'
            toolCallId = 'skill-call'
            success = -not $FailSkillResult
            result = @{ content = 'loaded' }
        }
        turn = 0
    })
    if (-not $OmitSkillActivation) {
        $skillBody = $frozenNativeSkillBody
        if ($WrongSkillBody) {
            $skillBody = $skillBody.Replace(
                '# Source-only pull request review',
                '# Wrong pull request review'
            )
        } elseif ($TruncatedSkillBody) {
            $skillBody = $skillBody.Substring(0, $skillBody.Length - 1)
        }
        $events.Add(@{
            type = 'skill_activation'
            data = @{
                name = 'review-pull-request'
                path = 'C:\temp\review-pull-request\SKILL.md'
                content = $skillBody
            }
            turn = 0
        })
    }
    $guideIndex = 0
    foreach ($reference in @(
        $manifest.guides |
            ForEach-Object {
                $_.assignment.files |
                    Where-Object kind -eq 'guide'
            }
    )) {
        $guideIndex++
        $toolCallId = "guide-$guideIndex"
        $events.Add(@{
            type = 'tool_call'
            data = @{
                toolName = 'view'
                toolCallId = $toolCallId
                turnId = '0'
                arguments = @{
                    path = 'C:\temp\calibration\bundle\' + ([string]$reference.path).Replace('/', '\')
                }
            }
            turn = 0
        })
        $content = Get-Content (
            Join-Path $fixtureRoot "$packet/baseline/bundle/$($reference.path)"
        ) -Raw
        if ($IncompleteGuideResult -and $guideIndex -eq 2) {
            $content = $content.Substring(0, $content.Length - 1)
        }
        $events.Add(@{
            type = 'tool_result'
            data = @{
                toolName = 'view'
                toolCallId = $toolCallId
                success = $true
                result = @{ content = $content }
            }
            turn = 0
        })
    }
    $events.Add(@{
        type = 'token_usage'
        data = @{ model = 'gpt-5.6-sol' }
    })
    $score = if ($FailPromptGrade) { 0 } else { 1 }
    if ($NullScore) {
        $score = $null
    }
    $result = [ordered]@{
        type = 'trial-result'
        runId = $fakeRunId
        itemId = "candidate-calibration::main::gpt-5.6-sol::$Name::trial-0"
        evalName = 'review-pull-request-candidate-calibration'
        variant = 'main'
        stimulus = $Name
        model = 'gpt-5.6-sol'
        status = $Status
        trajectory = [ordered]@{
            stimulus = @{ name = $Name }
            output = $Output
            events = @($events)
        }
        gradeResult = [ordered]@{
            passed = -not $FailPromptGrade
            score = $score
            details = @(
                @{
                    name = 'skill-invocation requires review-pull-request'
                    kind = 'code'
                    passed = $true
                    score = 1
                    metadata = @{
                        required = @('review-pull-request')
                        skills = @('review-pull-request')
                    }
                }
                @{
                    name = 'tool-calls forbids edit,create,task,powershell'
                    kind = 'code'
                    passed = -not $FailToolGrade
                    score = if ($FailToolGrade) { 0 } else { 1 }
                    metadata = @{
                        disallowed = @('edit', 'create', 'task', 'powershell')
                        tools = if ($FailToolGrade) { @('skill', 'view', 'edit') } else { @('skill', 'view') }
                    }
                }
                @{
                    name = 'prompt'
                    kind = 'llm'
                    passed = -not $FailPromptGrade
                    score = if ($NullIndividualScore) {
                        $null
                    } elseif ($FailPromptGrade) {
                        0
                    } else {
                        1
                    }
                    metadata = @{
                        model = 'gemini-4-argon'
                    }
                }
            )
        }
    }
    return $result
}

function Write-FakeResults {
    param(
        [Parameter(Mandatory = $true)][object[]]$Results,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $Results |
        ForEach-Object { $_ | ConvertTo-Json -Depth 30 -Compress } |
        Set-Content $Path
}

& $checker
Assert-Throws {
    & $checker -ResultMode Acceptance
} 'requires -ResultsDirectory' 'Acceptance without a result set was accepted.'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $fixtures = Join-Path $testRoot 'fixtures'
    Copy-Item $fixtureRoot $fixtures -Recurse

    $guide = Join-Path $fixtures (
        'full-support-history/treatment/bundle/guidance/docs/BlazorComponentsGuidance.md.source'
    )
    (Get-Content $guide -Raw).Replace('For WebAssembly threading claims', 'For WASM threading claims') |
        Set-Content $guide -NoNewline
    Assert-Throws {
        & $checker -FixtureRoot $fixtures
    } 'wrong byte count' 'A stale treatment guide reference was accepted.'

    Remove-Item $fixtures -Recurse -Force
    Copy-Item $fixtureRoot $fixtures -Recurse
    $leak = Join-Path $fixtures (
        'support-evidence-withheld/baseline/bundle/guidance/contracts/leak.source'
    )
    New-Item -ItemType Directory -Path (Split-Path $leak -Parent) -Force | Out-Null
    Set-Content $leak 'leak'
    Assert-Throws {
        & $checker -FixtureRoot $fixtures
    } 'leaks support-history contracts' 'Withheld support evidence was accepted.'

    $resultsRoot = Join-Path $testRoot 'results/run'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
    $names = @(
        'line77-full-support-history-baseline',
        'line77-support-evidence-withheld-baseline',
        'line77-explicit-default-single-thread-baseline'
    )
    $resultsPath = Join-Path $resultsRoot 'results.jsonl'
    Write-FakeResults -Results @($names | ForEach-Object { New-FakeResult $_ }) -Path $resultsPath
    & $checker -ResultsDirectory (Split-Path $resultsRoot -Parent) -ExpectedArm baseline `
        -ExpectedRunId $fakeRunId -ResultMode Integrity
    & $checker -ResultsDirectory (Split-Path $resultsRoot -Parent) -ExpectedArm baseline `
        -ExpectedRunId $fakeRunId -ResultMode Acceptance

    Write-FakeResults -Results @(
        (New-FakeResult $names[0])
        (New-FakeResult $names[1])
        (New-FakeResult $names[2] -Status error)
    ) -Path $resultsPath
    Assert-Throws {
        & $checker -ResultsDirectory (Split-Path $resultsRoot -Parent) -ExpectedArm baseline `
            -ExpectedRunId $fakeRunId
    } 'incomplete or failed' 'A failed subject attempt was accepted.'

    Write-FakeResults -Results @(
        (New-FakeResult $names[0])
        (New-FakeResult $names[1])
        (New-FakeResult $names[2] -Output '')
    ) -Path $resultsPath
    Assert-Throws {
        & $checker -ResultsDirectory (Split-Path $resultsRoot -Parent) -ExpectedArm baseline `
            -ExpectedRunId $fakeRunId
    } 'empty subject output' 'An empty subject output was accepted.'

    Write-FakeResults -Results @(
        (New-FakeResult $names[0])
        (New-FakeResult $names[1])
        (New-FakeResult $names[2] -NullScore)
    ) -Path $resultsPath
    Assert-Throws {
        & $checker -ResultsDirectory (Split-Path $resultsRoot -Parent) -ExpectedArm baseline `
            -ExpectedRunId $fakeRunId
    } 'no numeric associated grader score' 'A null grader score was accepted.'

    Write-FakeResults -Results @(
        (New-FakeResult $names[0])
        (New-FakeResult $names[1])
        (New-FakeResult $names[2] -NullIndividualScore)
    ) -Path $resultsPath
    Assert-Throws {
        & $checker -ResultsDirectory (Split-Path $resultsRoot -Parent) -ExpectedArm baseline `
            -ExpectedRunId $fakeRunId
    } 'required grader without a numeric score' 'A null individual grader score was accepted.'

    Write-FakeResults -Results @(
        (New-FakeResult $names[0])
        (New-FakeResult $names[1])
        (New-FakeResult $names[2] -FailPromptGrade)
    ) -Path $resultsPath
    & $checker -ResultsDirectory (Split-Path $resultsRoot -Parent) -ExpectedArm baseline `
        -ExpectedRunId $fakeRunId -ResultMode Integrity
    Assert-Throws {
        & $checker -ResultsDirectory (Split-Path $resultsRoot -Parent) -ExpectedArm baseline `
            -ExpectedRunId $fakeRunId -ResultMode Acceptance
    } 'required grader that did not pass' 'A valid negative grade passed automated acceptance.'

    Write-FakeResults -Results @(
        (New-FakeResult $names[0])
        (New-FakeResult $names[1])
        (New-FakeResult $names[2] -FailToolGrade)
    ) -Path $resultsPath
    & $checker -ResultsDirectory (Split-Path $resultsRoot -Parent) -ExpectedArm baseline `
        -ExpectedRunId $fakeRunId -ResultMode Integrity
    Assert-Throws {
        & $checker -ResultsDirectory (Split-Path $resultsRoot -Parent) -ExpectedArm baseline `
            -ExpectedRunId $fakeRunId -ResultMode Acceptance
    } 'required grader that did not pass' 'A prohibited-tool failure passed automated acceptance.'

    foreach ($case in @(
        @{
            Arguments = @{ OmitSkillActivation = $true }
            Message = 'no complete native skill activation evidence'
            Failure = 'Missing native skill activation evidence passed automated acceptance.'
        }
        @{
            Arguments = @{ FailSkillResult = $true }
            Message = 'no successful result for its first native skill call'
            Failure = 'A failed native skill result passed automated acceptance.'
        }
        @{
            Arguments = @{ SkillNotFirst = $true }
            Message = 'did not invoke the native review skill first'
            Failure = 'A native skill call after another tool passed automated acceptance.'
        }
        @{
            Arguments = @{ IncompleteGuideResult = $true }
            Message = 'no successful complete read bound'
            Failure = 'An incomplete guide read passed automated acceptance.'
        }
        @{
            Arguments = @{ WrongSkillBody = $true }
            Message = 'did not activate the normalized body from frozen skill blob'
            Failure = 'The wrong native skill body passed automated acceptance.'
        }
        @{
            Arguments = @{ TruncatedSkillBody = $true }
            Message = 'did not activate the normalized body from frozen skill blob'
            Failure = 'A truncated native skill body passed automated acceptance.'
        }
    )) {
        $arguments = $case.Arguments
        Write-FakeResults -Results @(
            (New-FakeResult $names[0])
            (New-FakeResult $names[1])
            (New-FakeResult $names[2] @arguments)
        ) -Path $resultsPath
        Assert-Throws {
            & $checker -ResultsDirectory (Split-Path $resultsRoot -Parent) -ExpectedArm baseline `
                -ExpectedRunId $fakeRunId -ResultMode Acceptance
        } $case.Message $case.Failure
    }

    Write-Host 'Candidate-calibration checker self-test passed.'
} finally {
    Remove-Item $testRoot -Recurse -Force
}
