#requires -Version 7.0
param(
    [string]$FixtureRoot = (Join-Path $PSScriptRoot 'fixtures/candidate-calibration'),

    [string]$ResultsDirectory,

    [ValidateSet('baseline', 'treatment')]
    [string]$ExpectedArm,

    [string]$ExpectedRunId,

    [ValidateSet('Integrity', 'Acceptance')]
    [string]$ResultMode = 'Integrity'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

$head = '2edf3761692afe15475075eb2fc0088566162045'
$mergeBase = '10bc886bfa321718276619d1077cc14eaf48456f'
$baseTip = '4f556f73a610b386e5ec29355a300e493d30c4c5'
$candidateHash = 'c0d3eeb0a69a11cec80f6fae7bf939d19589122c409f7770a68aa89bdc270a6b'
$reviewSkillBlob = 'b11fe9fe79b5d848687ba1c93362f4aaf22bfe53'
$nativeReviewSkillBodyBytes = 18527
$nativeReviewSkillBodyHash = '3a38f1385e455e104ebec8bffe280b6b90f6ef08f43131d4fe559c61d3ce1225'
$treatmentBullet = "- For WebAssembly threading claims, verify Blazor's host/provider support contract at the target revision. Experimental runtime switches and thread-aware implementation alone do not establish a supported product guarantee."
$packets = @(
    'full-support-history',
    'support-evidence-withheld',
    'explicit-default-single-thread'
)

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -Algorithm SHA256 $Path).Hash.ToLowerInvariant()
}

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-FileReference {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$Reference,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $path = Join-Path $Root ([string]$Reference.path)
    Assert-Condition (Test-Path $path -PathType Leaf) "Missing $Description at '$path'."
    Assert-Condition ((Get-Item $path).Length -eq [long]$Reference.utf8Bytes) (
        "$Description has the wrong byte count: $($Reference.path)."
    )
    Assert-Condition ((Get-Sha256 $path) -eq [string]$Reference.sha256) (
        "$Description has the wrong SHA-256: $($Reference.path)."
    )
}

function Get-RelativeFiles {
    param([Parameter(Mandatory = $true)][string]$Root)

    return @(
        Get-ChildItem $Root -Recurse -File |
            ForEach-Object { [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/') } |
            Sort-Object
    )
}

function Test-NumericValue {
    param($Value)

    return $null -ne $Value -and $Value.GetType().Name -in @(
        'Byte',
        'SByte',
        'Int16',
        'UInt16',
        'Int32',
        'UInt32',
        'Int64',
        'UInt64',
        'Single',
        'Double',
        'Decimal'
    )
}

function Test-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Packet,
        [Parameter(Mandatory = $true)][string]$Arm
    )

    $caseRoot = Join-Path $FixtureRoot "$Packet/$Arm"
    $bundleRoot = Join-Path $caseRoot 'bundle'
    Assert-Condition (Test-Path $bundleRoot -PathType Container) "Missing fixture case '$Packet/$Arm'."

    $manifestPath = Join-Path $bundleRoot 'manifest.json'
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json -Depth 100
    Assert-Condition ($manifest.version -eq 2 -and $manifest.ready -eq $true) (
        "$Packet/$Arm is not a ready version-2 bundle."
    )
    Assert-Condition (
        $manifest.target.head -eq $head -and
        $manifest.target.mergeBase -eq $mergeBase -and
        $manifest.target.baseTip -eq $baseTip
    ) "$Packet/$Arm has the wrong frozen target identities."
    Assert-Condition ($manifest.calibration.kind -eq 'supplied-candidate-acceptance-subtask') (
        "$Packet/$Arm has the wrong calibration role."
    )
    Assert-Condition ($manifest.calibration.packet -eq $Packet -and $manifest.calibration.arm -eq $Arm) (
        "$Packet/$Arm has mismatched calibration metadata."
    )

    Assert-FileReference $caseRoot $manifest.calibration.candidate "$Packet/$Arm candidate"
    Assert-Condition ($manifest.calibration.candidate.sha256 -eq $candidateHash) (
        "$Packet/$Arm does not use the frozen candidate body."
    )
    Assert-FileReference $caseRoot $manifest.calibration.case "$Packet/$Arm case metadata"
    Assert-FileReference $caseRoot $manifest.calibration.projectionMap "$Packet/$Arm projection map"

    $feedbackPath = Join-Path $bundleRoot 'feedback.json'
    $feedback = Get-Content $feedbackPath -Raw | ConvertFrom-Json -Depth 100
    Assert-Condition (
        @($feedback.comments).Count -eq 0 -and
        @($feedback.reviews).Count -eq 0 -and
        @($feedback.inline).Count -eq 0
    ) "$Packet/$Arm feedback projection is not explicitly empty."
    $feedbackText = Get-Content $feedbackPath -Raw
    Assert-Condition (
        -not $feedbackText.Contains('4431751648') -and
        -not $feedbackText.Contains('4431799752')
    ) "$Packet/$Arm leaks the supplied root or reply through feedback."

    foreach ($artifact in $manifest.artifacts.PSObject.Properties) {
        $path = Join-Path $bundleRoot $artifact.Name
        Assert-Condition (Test-Path $path -PathType Leaf) "$Packet/$Arm is missing $($artifact.Name)."
        Assert-Condition ((Get-Sha256 $path) -eq [string]$artifact.Value) (
            "$Packet/$Arm has a stale artifact hash for $($artifact.Name)."
        )
    }

    foreach ($guide in @($manifest.guides)) {
        foreach ($file in @($guide.assignment.files)) {
            Assert-FileReference $bundleRoot $file "$Packet/$Arm assigned $($file.kind)"
        }
    }
    foreach ($policy in @($manifest.policies)) {
        Assert-FileReference $bundleRoot $policy.body "$Packet/$Arm policy"
    }
    foreach ($exclusion in @($manifest.exclusions)) {
        foreach ($name in @('scope', 'reason', 'body')) {
            if ($exclusion.PSObject.Properties[$name]) {
                Assert-FileReference $bundleRoot $exclusion.$name "$Packet/$Arm exclusion"
            }
        }
    }

    foreach ($context in @($manifest.context)) {
        $path = Join-Path $bundleRoot "guidance/$($context.path).source"
        Assert-Condition (Test-Path $path -PathType Leaf) (
            "$Packet/$Arm is missing context '$($context.path)'."
        )
        Assert-Condition ((Get-Sha256 $path) -eq [string]$context.sha256) (
            "$Packet/$Arm has a stale context hash for '$($context.path)'."
        )
    }

    $guidePath = Join-Path $bundleRoot 'guidance/docs/BlazorComponentsGuidance.md.source'
    $guideText = Get-Content $guidePath -Raw
    $bulletCount = ([regex]::Matches($guideText, [regex]::Escape($treatmentBullet))).Count
    $expectedBulletCount = if ($Arm -eq 'treatment') { 1 } else { 0 }
    Assert-Condition ($bulletCount -eq $expectedBulletCount) (
        "$Packet/$Arm contains $bulletCount treatment bullets; expected $expectedBulletCount."
    )

    $contractRoot = Join-Path $bundleRoot 'guidance/contracts'
    if ($Packet -eq 'full-support-history') {
        Assert-Condition (Test-Path $contractRoot -PathType Container) (
            "$Packet/$Arm is missing the support-history contracts."
        )
        Assert-Condition (@(Get-ChildItem $contractRoot -File).Count -eq 4) (
            "$Packet/$Arm has the wrong support-history contract count."
        )
    } else {
        Assert-Condition (-not (Test-Path $contractRoot)) (
            "$Packet/$Arm leaks support-history contracts."
        )
    }

    Assert-Condition (
        -not (Get-ChildItem $caseRoot -Recurse -File |
            Where-Object Name -in @(
                'candidate-calibration-labels.json',
                'candidate-calibration-rubric.md',
                'candidate-calibration-anchors.md'
            ))
    ) "$Packet/$Arm stages grader-only answer material."
}

foreach ($packet in $packets) {
    foreach ($arm in @('baseline', 'treatment')) {
        Test-Case $packet $arm
    }

    $baselineRoot = Join-Path $FixtureRoot "$packet/baseline"
    $treatmentRoot = Join-Path $FixtureRoot "$packet/treatment"
    $baselineFiles = Get-RelativeFiles $baselineRoot
    $treatmentFiles = Get-RelativeFiles $treatmentRoot
    Assert-Condition (
        ($baselineFiles -join "`n") -eq ($treatmentFiles -join "`n")
    ) "$packet baseline and treatment file layouts differ."

    $allowedDifferences = @(
        'bundle/guidance/docs/BlazorComponentsGuidance.md.source',
        'bundle/manifest.json'
    )
    foreach ($relative in $baselineFiles) {
        $baselinePath = Join-Path $baselineRoot $relative
        $treatmentPath = Join-Path $treatmentRoot $relative
        $different = (Get-Sha256 $baselinePath) -ne (Get-Sha256 $treatmentPath)
        Assert-Condition (
            -not $different -or $relative -in $allowedDifferences
        ) "$packet arm inputs differ outside the guide and manifest: $relative."
    }

    $baselineGuide = Get-Content (
        Join-Path $baselineRoot 'bundle/guidance/docs/BlazorComponentsGuidance.md.source'
    ) -Raw
    $treatmentGuide = Get-Content (
        Join-Path $treatmentRoot 'bundle/guidance/docs/BlazorComponentsGuidance.md.source'
    ) -Raw
    $withoutTreatment = $treatmentGuide.Replace("$treatmentBullet`r`n", '').Replace("$treatmentBullet`n", '')
    Assert-Condition ($withoutTreatment -eq $baselineGuide) (
        "$packet treatment guide differs by more than the preregistered bullet."
    )
}

Write-Host 'Candidate-calibration fixture integrity passed.'

Assert-Condition (
    $ResultMode -ne 'Acceptance' -or
    -not [string]::IsNullOrWhiteSpace($ResultsDirectory)
) '-ResultMode Acceptance requires -ResultsDirectory.'

if ($ResultsDirectory) {
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($ExpectedArm)) (
        '-ExpectedArm is required with -ResultsDirectory.'
    )
    $parsedExpectedRunId = [guid]::Empty
    Assert-Condition ([guid]::TryParse($ExpectedRunId, [ref]$parsedExpectedRunId)) (
        '-ExpectedRunId must identify the exact run being checked.'
    )
    $resultFiles = @(Get-ChildItem $ResultsDirectory -Recurse -File -Filter 'results.jsonl')
    Assert-Condition ($resultFiles.Count -eq 1) (
        "Expected exactly one results.jsonl under '$ResultsDirectory'; found $($resultFiles.Count)."
    )
    $results = @(
        Get-Content $resultFiles[0].FullName |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_ | ConvertFrom-Json -Depth 100 } |
            Where-Object type -eq 'trial-result'
    )
    Assert-Condition ($results.Count -eq 3) (
        "Expected exactly three $ExpectedArm attempts; found $($results.Count)."
    )

    $expectedNames = @($packets | ForEach-Object { "line77-$_-$ExpectedArm" } | Sort-Object)
    $actualNames = [Collections.Generic.List[string]]::new()
    $runIds = [Collections.Generic.List[string]]::new()
    foreach ($result in $results) {
        Assert-Condition ($result.status -eq 'success') (
            "The $ExpectedArm result set contains an incomplete or failed attempt."
        )
        $trajectory = $result.trajectory
        Assert-Condition ($null -ne $trajectory) 'A trial result omits its trajectory.'
        $name = if ($trajectory.stimulus.name) {
            [string]$trajectory.stimulus.name
        } elseif ($result.stimulusName) {
            [string]$result.stimulusName
        } else {
            ''
        }
        Assert-Condition (-not [string]::IsNullOrWhiteSpace($name)) (
            'A trial result omits its stimulus name.'
        )
        $actualNames.Add($name)
        Assert-Condition ($result.evalName -eq 'review-pull-request-candidate-calibration') (
            "$name has the wrong eval identity."
        )
        Assert-Condition ($result.variant -eq 'main') "$name has the wrong eval variant."
        Assert-Condition ($result.model -eq 'gpt-5.6-sol') "$name has the wrong result model."
        Assert-Condition ($result.stimulus -eq $name) "$name has mismatched result stimulus metadata."
        Assert-Condition (
            [string]$result.itemId -like "*::main::gpt-5.6-sol::$name::trial-0"
        ) "$name has the wrong item identity."
        $parsedRunId = [guid]::Empty
        Assert-Condition ([guid]::TryParse([string]$result.runId, [ref]$parsedRunId)) (
            "$name has an invalid run ID."
        )
        Assert-Condition ([string]$result.runId -eq $ExpectedRunId) (
            "$name belongs to the wrong run."
        )
        $runIds.Add([string]$result.runId)
        Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$trajectory.output)) (
            "$name has an empty subject output."
        )
        $gradeResultProperty = $result.PSObject.Properties['gradeResult']
        $scoreProperty = if ($gradeResultProperty -and $null -ne $gradeResultProperty.Value) {
            $gradeResultProperty.Value.PSObject.Properties['score']
        }
        Assert-Condition (
            $scoreProperty -and (Test-NumericValue $scoreProperty.Value)
        ) "$name has no numeric associated grader score."
        Assert-Condition (@($gradeResultProperty.Value.details).Count -eq 3) (
            "$name does not retain all three grader outcomes."
        )
        $details = @($gradeResultProperty.Value.details)
        $skillGrade = @(
            $details |
                Where-Object {
                    $_.metadata -and
                    $_.metadata.PSObject.Properties['required'] -and
                    @($_.metadata.required) -contains 'review-pull-request'
                }
        )
        $toolGrade = @(
            $details |
                Where-Object {
                    $_.metadata -and
                    $_.metadata.PSObject.Properties['disallowed'] -and
                    @($_.metadata.disallowed).Count -gt 0
                }
        )
        $promptGrade = @($details | Where-Object { $_.kind -eq 'llm' -and $_.name -eq 'prompt' })
        Assert-Condition (
            $skillGrade.Count -eq 1 -and
            $toolGrade.Count -eq 1 -and
            $promptGrade.Count -eq 1
        ) "$name is missing a required grader outcome."
        foreach ($grade in @($skillGrade[0], $toolGrade[0], $promptGrade[0])) {
            $individualScore = $grade.PSObject.Properties['score']
            Assert-Condition (
                $individualScore -and (Test-NumericValue $individualScore.Value)
            ) "$name has a required grader without a numeric score."
        }
        $models = @(
            $trajectory.events |
                Where-Object type -eq 'token_usage' |
                ForEach-Object { $_.data.model } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
        Assert-Condition ($models.Count -eq 1 -and $models[0] -eq 'gpt-5.6-sol') (
            "$name did not retain the exact gpt-5.6-sol subject identity."
        )

        if ($ResultMode -eq 'Acceptance') {
            foreach ($grade in @($skillGrade[0], $toolGrade[0], $promptGrade[0])) {
                Assert-Condition ($grade.passed -eq $true) (
                    "$name has a required grader that did not pass."
                )
            }
            Assert-Condition ($gradeResultProperty.Value.passed -eq $true) (
                "$name does not have an accepted aggregate verdict."
            )
            Assert-Condition ($promptGrade[0].metadata.model -eq 'gemini-4-argon') (
                "$name did not retain the exact gemini-4-argon judge identity."
            )
            Assert-Condition (
                @($skillGrade[0].metadata.skills).Count -eq 1 -and
                $skillGrade[0].metadata.skills[0] -eq 'review-pull-request'
            ) "$name has the wrong graded skill activation."
            Assert-Condition (
                @($toolGrade[0].metadata.disallowed) -contains 'edit' -and
                @($toolGrade[0].metadata.disallowed) -contains 'create' -and
                @($toolGrade[0].metadata.disallowed) -contains 'task' -and
                @($toolGrade[0].metadata.disallowed) -contains 'powershell'
            ) "$name does not retain the prohibited-tool grader."

            $events = @($trajectory.events)
            $toolCalls = @($events | Where-Object type -eq 'tool_call')
            Assert-Condition ($toolCalls.Count -gt 0) "$name has no tool-call evidence."
            $skillCall = $toolCalls[0]
            Assert-Condition (
                $skillCall.data.toolName -eq 'skill' -and
                $skillCall.data.arguments.skill -eq 'review-pull-request'
            ) "$name did not invoke the native review skill first."
            $skillResult = @(
                $events |
                    Where-Object {
                        $_.type -eq 'tool_result' -and
                        $_.data.toolCallId -eq $skillCall.data.toolCallId
                    }
            )
            Assert-Condition (
                $skillResult.Count -eq 1 -and
                $skillResult[0].data.toolName -eq 'skill' -and
                $skillResult[0].data.success -eq $true
            ) "$name has no successful result for its first native skill call."
            $skillActivations = @(
                $events |
                    Where-Object {
                        $_.type -eq 'skill_activation' -and
                        $_.data.name -eq 'review-pull-request' -and
                        -not [string]::IsNullOrWhiteSpace([string]$_.data.content)
                    }
            )
            Assert-Condition ($skillActivations.Count -eq 1) (
                "$name has no complete native skill activation evidence."
            )
            $skillCallIndex = [Array]::IndexOf($events, $skillCall)
            $skillResultIndex = [Array]::IndexOf($events, $skillResult[0])
            $skillActivationIndex = [Array]::IndexOf($events, $skillActivations[0])
            $nextToolCallIndex = -1
            for ($eventIndex = $skillCallIndex + 1; $eventIndex -lt $events.Count; $eventIndex++) {
                if ($events[$eventIndex].type -eq 'tool_call') {
                    $nextToolCallIndex = $eventIndex
                    break
                }
            }
            Assert-Condition (
                $skillResultIndex -gt $skillCallIndex -and
                $skillActivationIndex -gt $skillResultIndex -and
                ($nextToolCallIndex -eq -1 -or $skillActivationIndex -lt $nextToolCallIndex) -and
                $skillCall.turn -eq $skillResult[0].turn -and
                $skillCall.turn -eq $skillActivations[0].turn
            ) "$name does not associate native activation with its first successful skill call."
            $activationPath = ([string]$skillActivations[0].data.path).Replace('\', '/')
            Assert-Condition (
                $activationPath.EndsWith(
                    '/review-pull-request/SKILL.md',
                    [StringComparison]::OrdinalIgnoreCase
                )
            ) "$name activated the wrong native skill path."
            $nativeBody = ([string]$skillActivations[0].data.content).
                Replace("`r`n", "`n").
                Replace("`r", "`n")
            $nativeBodyBytes = [Text.Encoding]::UTF8.GetBytes($nativeBody)
            $nativeBodyHash = [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData($nativeBodyBytes)
            ).ToLowerInvariant()
            Assert-Condition (
                $nativeBodyBytes.Length -eq $nativeReviewSkillBodyBytes -and
                $nativeBodyHash -eq $nativeReviewSkillBodyHash
            ) (
                "$name did not activate the normalized body from frozen skill blob $reviewSkillBlob."
            )

            $packet = $name.Substring('line77-'.Length)
            $packet = $packet.Substring(0, $packet.Length - "-$ExpectedArm".Length)
            $manifestPath = Join-Path $FixtureRoot "$packet/$ExpectedArm/bundle/manifest.json"
            $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json -Depth 100
            $guideReferences = @(
                $manifest.guides |
                    ForEach-Object {
                        $_.assignment.files |
                            Where-Object kind -eq 'guide'
                    }
            )
            Assert-Condition ($guideReferences.Count -eq 2) (
                "$name fixture does not assign exactly two routed guides."
            )
            foreach ($reference in $guideReferences) {
                $expectedSuffix = (
                    '/calibration/bundle/' + ([string]$reference.path).Replace('\', '/')
                ).ToLowerInvariant()
                $matchingReads = @(
                    $toolCalls |
                        Where-Object {
                            $_.data.toolName -in @('view', 'read_file') -and
                            $_.data.arguments -and
                            ([string]$_.data.arguments.path).Replace('\', '/').ToLowerInvariant().EndsWith(
                                $expectedSuffix,
                                [StringComparison]::Ordinal
                            )
                        }
                )
                $completeReads = @()
                foreach ($read in $matchingReads) {
                    $readResult = @(
                        $events |
                            Where-Object {
                                $_.type -eq 'tool_result' -and
                                $_.data.toolCallId -eq $read.data.toolCallId
                            }
                    )
                    if ($readResult.Count -ne 1 -or $readResult[0].data.success -ne $true) {
                        continue
                    }
                    $contentProperty = $readResult[0].data.result.PSObject.Properties['content']
                    if (-not $contentProperty -or $null -eq $contentProperty.Value) {
                        continue
                    }
                    $content = [string]$contentProperty.Value
                    $bytes = [Text.Encoding]::UTF8.GetBytes($content)
                    $hash = [Convert]::ToHexString(
                        [Security.Cryptography.SHA256]::HashData($bytes)
                    ).ToLowerInvariant()
                    if ($bytes.Length -eq [long]$reference.utf8Bytes -and
                        $hash -eq [string]$reference.sha256) {
                        $completeReads += $read
                    }
                }
                Assert-Condition ($completeReads.Count -gt 0) (
                    "$name has no successful complete read bound to '$($reference.path)'."
                )
            }
        }
    }
    Assert-Condition (
        (($actualNames | Sort-Object) -join "`n") -eq ($expectedNames -join "`n")
    ) "The $ExpectedArm result set has missing or duplicate cases."
    Assert-Condition (@($runIds | Sort-Object -Unique).Count -eq 1) (
        "The $ExpectedArm result set spans multiple run IDs."
    )
    if ($ResultMode -eq 'Acceptance') {
        Write-Host "Candidate-calibration $ExpectedArm automated acceptance passed."
    } else {
        Write-Host "Candidate-calibration $ExpectedArm result integrity passed."
    }
}
