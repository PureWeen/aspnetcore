#!/usr/bin/env pwsh
#Requires -Version 7.0

$ErrorActionPreference = "Stop"

function Assert-True
{
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition)
    {
        throw $Message
    }
}

function Assert-Throws
{
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message
    )

    try
    {
        & $Action
    }
    catch
    {
        return
    }

    throw $Message
}

function Write-JsonFile
{
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    $json = $Value | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Invoke-Sanitizer
{
    param(
        [string]$FixtureName,
        [string]$SourcePath,
        [int]$CollectionExitCode = 0,
        [int]$MaxOutputBytes = 65536
    )

    $inputPath = Join-Path $tempRoot "input-$([guid]::NewGuid().ToString('N')).json"
    $outputPath = Join-Path $tempRoot "output-$([guid]::NewGuid().ToString('N')).json"
    if ($FixtureName)
    {
        Copy-Item (Join-Path $fixtureRoot $FixtureName) $inputPath
    }
    elseif ($SourcePath)
    {
        Copy-Item $SourcePath $inputPath
    }

    try
    {
        & $sanitizerPath `
            -InputPath $inputPath `
            -OutputPath $outputPath `
            -AttemptTimestamp $attemptTimestamp `
            -CollectionExitCode $CollectionExitCode `
            -MaxOutputBytes $MaxOutputBytes

        Assert-True (-not (Test-Path $inputPath)) "The raw input must always be deleted."
        return Get-Content -Raw $outputPath | ConvertFrom-Json -Depth 100
    }
    finally
    {
        Remove-Item $inputPath, $outputPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Renderer
{
    param([Parameter(Mandatory)][object]$Pulse)

    $inputPath = Join-Path $tempRoot "pulse-$([guid]::NewGuid().ToString('N')).json"
    $outputPath = Join-Path $tempRoot "body-$([guid]::NewGuid().ToString('N')).md"
    try
    {
        Write-JsonFile -Value $Pulse -Path $inputPath
        & $rendererPath -InputPath $inputPath -OutputPath $outputPath
        return Get-Content -Raw $outputPath
    }
    finally
    {
        Remove-Item $inputPath, $outputPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-PublicationValidator
{
    param(
        [Parameter(Mandatory)][object]$Pulse,
        [object]$AgentOutput,
        [string]$AgentOutputJson,
        [string]$ExpectedBody
    )

    $pulsePath = Join-Path $tempRoot "pulse-$([guid]::NewGuid().ToString('N')).json"
    $bodyPath = Join-Path $tempRoot "body-$([guid]::NewGuid().ToString('N')).md"
    $outputPath = Join-Path $tempRoot "agent-$([guid]::NewGuid().ToString('N')).json"
    $safeOutputsPath = Join-Path (Split-Path -Parent $outputPath) "safeoutputs.jsonl"
    try
    {
        if ($null -eq $ExpectedBody)
        {
            $ExpectedBody = Invoke-PinnedOutputSanitizer -Content (Invoke-Renderer -Pulse $Pulse)
        }

        Write-JsonFile -Value $Pulse -Path $pulsePath
        [IO.File]::WriteAllText($bodyPath, $ExpectedBody, [Text.UTF8Encoding]::new($false))
        if ($PSBoundParameters.ContainsKey("AgentOutputJson"))
        {
            [IO.File]::WriteAllText($outputPath, $AgentOutputJson, [Text.UTF8Encoding]::new($false))
        }
        else
        {
            Write-JsonFile -Value $AgentOutput -Path $outputPath
        }
        [IO.File]::WriteAllText($safeOutputsPath, '{"type":"update_issue"}' + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        try
        {
            $validatorMessages = @(& pwsh -NoProfile -File $validatorPath `
                -AgentOutputPath $outputPath `
                -PulseInputPath $pulsePath `
                -ExpectedBodyPath $bodyPath `
                -SanitizerModulePath $collectorSanitizerPath 2>&1)
            $validatorExitCode = $LASTEXITCODE
            if ($validatorExitCode -ne 0)
            {
                throw "The native publication validator exited with code $validatorExitCode`: $($validatorMessages -join ' ')"
            }

            $retainedOutput = Get-Content -Raw $outputPath | ConvertFrom-Json -Depth 100
            Assert-True (@($retainedOutput.items).Count -eq 1) "A valid publication payload must remain intact."
            Assert-True ([string]::Equals(@($retainedOutput.items)[0].body, $ExpectedBody, [StringComparison]::Ordinal)) "A valid publication body must remain byte-identical."
        }
        catch
        {
            $failedClosed = Get-Content -Raw $outputPath | ConvertFrom-Json -Depth 10
            Assert-True ($failedClosed.PSObject.Properties.Count -eq 2) "Rejected output must be replaced by the exact empty collector envelope."
            Assert-True ($failedClosed.items -is [array] -and $failedClosed.items.Count -eq 0) "Rejected output must leave no publishable item."
            Assert-True ($failedClosed.errors -is [array] -and $failedClosed.errors.Count -eq 0) "Rejected output must retain an empty collector errors array."
            Assert-True (-not (Test-Path $safeOutputsPath)) "Rejected output must remove the copied raw safe-output stream."
            Assert-True (-not (Test-Path "$outputPath.rejected")) "Rejected output quarantine must not be published as an artifact."
            throw
        }
    }
    finally
    {
        Remove-Item $pulsePath, $bodyPath, $outputPath, $safeOutputsPath -Force -ErrorAction SilentlyContinue
    }
}

function New-ValidAgentOutput
{
    param([Parameter(Mandatory)][string]$Body)

    return [pscustomobject]@{
        items = @(
            [pscustomobject]@{
                type = "update_issue"
                issue_number = 58
                operation = "replace"
                body = $Body
            }
        )
        errors = @()
    }
}

function Get-GhAwExtensionRoot
{
    $candidateRoots = @(
        $(if ($env:GH_CONFIG_DIR) { Join-Path $env:GH_CONFIG_DIR "extensions/gh-aw" }),
        $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "GitHub CLI/extensions/gh-aw" }),
        $(if ($env:XDG_DATA_HOME) { Join-Path $env:XDG_DATA_HOME "gh/extensions/gh-aw" }),
        $(if ($HOME) { Join-Path $HOME ".local/share/gh/extensions/gh-aw" }),
        $(if ($HOME) { Join-Path $HOME ".config/gh/extensions/gh-aw" })
    ) | Where-Object { $_ }
    foreach ($candidateRoot in $candidateRoots)
    {
        if (Test-Path -LiteralPath (Join-Path $candidateRoot "actions/setup/js/sanitize_content.cjs"))
        {
            return $candidateRoot
        }
    }

    $previousDebug = $env:GH_DEBUG
    try
    {
        $env:GH_DEBUG = "api"
        $debugOutput = @(& gh aw --version 2>&1)
        if ($LASTEXITCODE -ne 0)
        {
            throw "The installed gh-aw extension could not be inspected."
        }
    }
    finally
    {
        if ($null -eq $previousDebug)
        {
            Remove-Item Env:GH_DEBUG -ErrorAction SilentlyContinue
        }
        else
        {
            $env:GH_DEBUG = $previousDebug
        }
    }

    foreach ($line in $debugOutput)
    {
        $match = [regex]::Match([string]$line, "^\[git(?:\.exe)? -C (.+) config remote\.origin\.url\]$")
        if ($match.Success)
        {
            return $match.Groups[1].Value.Trim('"')
        }
    }

    throw "Could not locate the installed gh-aw extension."
}

function Invoke-PinnedOutputSanitizer
{
    param([Parameter(Mandatory)][string]$Content)

    $inputPath = Join-Path $tempRoot "collector-input-$([guid]::NewGuid().ToString('N')).txt"
    $outputPath = Join-Path $tempRoot "collector-output-$([guid]::NewGuid().ToString('N')).txt"
    try
    {
        [IO.File]::WriteAllText($inputPath, $Content, [Text.UTF8Encoding]::new($false))
        $nodeScript = @'
const fs = require("fs");
global.core = { info() {}, warning() {}, error() {} };
const { sanitizeContent } = require(process.argv[2]);
const input = fs.readFileSync(process.argv[3], "utf8");
const output = sanitizeContent(input, {
  allowedAliases: [],
});
fs.writeFileSync(process.argv[4], output, "utf8");
'@
        $previousUrls = $env:GH_AW_SAFE_OUTPUTS_URLS
        $previousReferences = $env:GH_AW_ALLOWED_GITHUB_REFS
        try
        {
            $env:GH_AW_SAFE_OUTPUTS_URLS = "allowed-or-code-region"
            $env:GH_AW_ALLOWED_GITHUB_REFS = ""
            $nodeScript | node - $collectorSanitizerPath $inputPath $outputPath
            if ($LASTEXITCODE -ne 0)
            {
                throw "The pinned gh-aw output sanitizer failed."
            }
        }
        finally
        {
            if ($null -eq $previousUrls)
            {
                Remove-Item Env:GH_AW_SAFE_OUTPUTS_URLS -ErrorAction SilentlyContinue
            }
            else
            {
                $env:GH_AW_SAFE_OUTPUTS_URLS = $previousUrls
            }
            if ($null -eq $previousReferences)
            {
                Remove-Item Env:GH_AW_ALLOWED_GITHUB_REFS -ErrorAction SilentlyContinue
            }
            else
            {
                $env:GH_AW_ALLOWED_GITHUB_REFS = $previousReferences
            }
        }

        return Get-Content -LiteralPath $outputPath -Raw
    }
    finally
    {
        Remove-Item $inputPath, $outputPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-PinnedCollector
{
    param([Parameter(Mandatory)][string]$Body)

    $collectorRoot = Join-Path $tempRoot "collector-$([guid]::NewGuid().ToString('N'))"
    $safeOutputPath = Join-Path $collectorRoot "outputs.jsonl"
    $configPath = Join-Path $collectorRoot "config.json"
    $validationRoot = Join-Path $collectorRoot "gh-aw/safeoutputs"
    $validationPath = Join-Path $validationRoot "validation.json"
    $collectorOutputRoot = Join-Path $collectorRoot "collector-output"
    try
    {
        New-Item -ItemType Directory -Force $validationRoot, $collectorOutputRoot | Out-Null
        $rawItem = [ordered]@{
            type = "update_issue"
            issue_number = 58
            operation = "replace"
            body = $Body
        }
        [IO.File]::WriteAllText(
            $safeOutputPath,
            ($rawItem | ConvertTo-Json -Depth 10 -Compress),
            [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText(
            $configPath,
            '{"max_bot_mentions":"0","mentions":{"enabled":false},"update_issue":{"allow_body":true,"footer":false,"max":1,"required_title_prefix":"[pr-attention-pulse]","target":"58"}}',
            [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText(
            $validationPath,
            '{"mentions":{"enabled":false},"update_issue":{"defaultMax":1,"fields":{"assignees":{"type":"array","itemType":"string","itemSanitize":true,"itemMaxLength":39},"body":{"type":"string","sanitize":true,"maxLength":65000},"issue_number":{"issueOrPRNumber":true},"labels":{"type":"array"},"milestone":{"optionalPositiveInteger":true},"operation":{"type":"string","enum":["replace","append","prepend","replace-island"]},"repo":{"type":"string","maxLength":256},"status":{"type":"string","enum":["open","closed"]},"title":{"type":"string","sanitize":true,"maxLength":128}},"customValidation":"requiresOneOf:status,title,body,labels,assignees,milestone"}}',
            [Text.UTF8Encoding]::new($false))

        $collectorScript = @'
global.core = {
  info() {},
  warning() {},
  error() {},
  setOutput() {},
  exportVariable() {},
  setFailed(message) { throw new Error(message); },
};
global.context = {
  repo: { owner: "PureWeen", repo: "aspnetcore" },
  eventName: "workflow_dispatch",
  payload: {},
};
global.github = {};
const constants = require(process.argv[3]);
constants.TMP_GH_AW_PATH = process.argv[6];
process.env.GH_AW_SAFE_OUTPUTS = process.argv[4];
process.env.GH_AW_SAFE_OUTPUTS_CONFIG_PATH = process.argv[5];
process.env.RUNNER_TEMP = process.argv[7];
process.env.GH_AW_SAFE_OUTPUTS_URLS = "allowed-or-code-region";
process.env.GH_AW_ALLOWED_GITHUB_REFS = "";
require(process.argv[2]).main().catch(error => {
  console.error(error);
  process.exit(1);
});
'@
        $collectorScript |
            node - `
                (Join-Path $collectorJsRoot "collect_ndjson_output.cjs") `
                (Join-Path $collectorJsRoot "constants.cjs") `
                $safeOutputPath `
                $configPath `
                $collectorOutputRoot `
                $collectorRoot
        if ($LASTEXITCODE -ne 0)
        {
            throw "The pinned gh-aw output collector failed."
        }

        $collectorOutputPath = Join-Path $collectorOutputRoot "agent_output.json"
        if (-not (Test-Path -LiteralPath $collectorOutputPath))
        {
            throw "The pinned gh-aw output collector did not produce agent_output.json."
        }

        return Get-Content -LiteralPath $collectorOutputPath -Raw | ConvertFrom-Json -Depth 100
    }
    finally
    {
        Remove-Item -LiteralPath $collectorRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-RealQueueFixture
{
    param([Parameter(Mandatory)][string]$FixtureName)

    $queueOutput = Join-Path $tempRoot "queue-$([guid]::NewGuid().ToString('N')).json"
    try
    {
        & $queueScript `
            -Repository dotnet/aspnetcore `
            -AllRepo `
            -DisablePersonalInbox `
            -InputPath (Join-Path $queueFixtureRoot $FixtureName) `
            -Now $queueSnapshot `
            -OutputFormat Json > $queueOutput
        Assert-True $? "The real queue script failed for $FixtureName."

        return Invoke-Sanitizer -SourcePath $queueOutput
    }
    finally
    {
        Remove-Item $queueOutput -Force -ErrorAction SilentlyContinue
    }
}

$testRoot = $PSScriptRoot
$workflowRoot = Split-Path -Parent $testRoot
$supportRoot = Join-Path $workflowRoot "pr-attention-pulse"
$fixtureRoot = Join-Path $testRoot "fixtures"
$queueRoot = Join-Path (Split-Path -Parent $workflowRoot) "skills/pr-attention-queue"
$queueFixtureRoot = Join-Path $queueRoot "tests/fixtures"
$queueScript = Join-Path $queueRoot "scripts/Get-PRAttentionQueue.ps1"
$sanitizerPath = Join-Path $supportRoot "Sanitize-PRAttentionPulse.ps1"
$rendererPath = Join-Path $supportRoot "Render-PRAttentionPulse.ps1"
$validatorPath = Join-Path $supportRoot "Validate-PRAttentionPulseOutput.ps1"
$compilePath = Join-Path $supportRoot "Compile-PRAttentionPulse.ps1"
$workflowPath = Join-Path $workflowRoot "pr-attention-pulse.md"
$lockPath = Join-Path $workflowRoot "pr-attention-pulse.lock.yml"
$ghAwVersion = (& gh aw --version 2>&1) -join "`n"
Assert-True ($LASTEXITCODE -eq 0 -and $ghAwVersion.Contains("v0.88.7")) "Focused tests require the reviewed gh-aw v0.88.7 installation."
$collectorJsRoot = Join-Path (Get-GhAwExtensionRoot) "actions/setup/js"
$collectorSanitizerPath = Join-Path $collectorJsRoot "sanitize_content.cjs"
$attemptTimestamp = [datetime]"2026-09-10T20:04:56Z"
$queueSnapshot = [datetime]"2026-09-03T18:00:00Z"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "pr-attention-pulse-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $tempRoot | Out-Null

try
{
    & node (Join-Path $testRoot "Test-PulsePublicationCommand.cjs") $collectorJsRoot $workflowPath $tempRoot
    Assert-True ($LASTEXITCODE -eq 0) "The pinned CLI publication serialization must preserve the canonical body."

    $normal = Invoke-Sanitizer -FixtureName "normal-legacy.json"
    Assert-True ($normal.schemaVersion -eq "1.0.0") "The pulse envelope must be versioned."
    Assert-True ($normal.status -eq "complete") "A complete inventory must remain complete."
    Assert-True ($normal.candidateCountsAvailable -is [bool] -and $normal.candidateCountsAvailable) "Complete candidate counts must be available."
    Assert-True (@($normal.views.reviewNow).Count -eq 2) "Both Review now candidates must survive."
    Assert-True ($normal.views.reviewNow[0].number -eq 101) "Review now ordering must preserve digest rank."
    Assert-True ($normal.views.reviewNow[1].number -eq 102) "Review now ordering must preserve the second digest rank."
    Assert-True ($normal.views.reviewNow[1].rank -eq 2) "The engine-provided digest rank must be preserved."
    Assert-True (@($normal.views.verifyDiscussionBeforeReview).Count -eq 1) "Discussion verification must remain a separate legacy view."
    Assert-True (-not $normal.views.verifyDiscussionBeforeReview[0].discussionAssessment.complete) "Partial discussion evidence must remain incomplete."
    Assert-True ($normal.views.verifyDiscussionBeforeReview[0].discussionAssessment.signals -contains "discussion-incomplete") "Discussion completeness signals must be preserved."
    Assert-True ($normal.views.verifyDiscussionBeforeReview[0].discussionAssessment.threads.unresolvedCount -eq 2) "Thread assessment counts must be preserved."
    Assert-True ($normal.views.needsRescue[0].bucket -eq "NeedsRescue") "Needs rescue membership must not be reclassified."
    Assert-True ($normal.views.readyToMerge[0].bucket -eq "ReadyToMerge") "Ready to merge membership must not be reclassified."
    Assert-True ($normal.views.reviewNow[1].author -eq "second-author") "Authors must render without mentions."
    foreach ($viewName in @("reviewNow", "needsRescue", "readyToMerge"))
    {
        foreach ($candidate in @($normal.views.$viewName))
        {
            Assert-True ($null -eq $candidate.PSObject.Properties["discussionAssessment"]) "Discussion assessment data must cross only for the discussion verification view."
        }
    }

    $normalJson = $normal | ConvertTo-Json -Depth 100
    foreach ($prohibitedText in @(
        "RAW BODY",
        "RAW REVIEW",
        "RAW COMMENT",
        "RAW EVIDENCE",
        "RAW DISCUSSION",
        "src/Secret.cs",
        "https://",
        "@",
        '`',
        "|",
        "<b>",
        "#88",
        "example.com",
        "GH-77",
        "deadbee5"))
    {
        Assert-True (-not $normalJson.Contains($prohibitedText)) "Sanitized model input leaked prohibited text: $prohibitedText"
    }
    foreach ($prohibitedProperty in @('"body"', '"reviews"', '"comments"', '"files"', '"url"', '"excerpt"'))
    {
        Assert-True (-not $normalJson.Contains($prohibitedProperty)) "Sanitized model input leaked prohibited property: $prohibitedProperty"
    }

    $zero = Invoke-Sanitizer -FixtureName "complete-zero.json"
    Assert-True ($zero.status -eq "complete") "A complete zero inventory must be a normal successful result."
    Assert-True ($zero.source.census.openPullRequests -eq 0) "A complete zero inventory must preserve zero census counts."
    foreach ($viewName in @("reviewNow", "verifyDiscussionBeforeReview", "needsRescue", "readyToMerge"))
    {
        Assert-True (@($zero.views.$viewName).Count -eq 0) "A complete zero inventory must keep '$viewName' empty."
    }
    $zeroBody = Invoke-Renderer -Pulse $zero
    Assert-True ([regex]::Matches($zeroBody, "None in this complete inventory\.").Count -eq 4) "A complete zero inventory must render all four candidate sections as empty."

    $collectionFailure = Invoke-Sanitizer -CollectionExitCode 9
    Assert-True ($collectionFailure.status -eq "unavailable") "Collection failure must produce a failure envelope."
    Assert-True ($collectionFailure.errorCategory -eq "collection-failed") "Collection failure must preserve its bounded category."
    Assert-True (-not $collectionFailure.candidateCountsAvailable) "Failure candidate counts must be unavailable, not zero."
    Assert-True ($null -eq $collectionFailure.source.census) "A failure envelope must not manufacture zero census counts."
    $missingOutput = Invoke-Sanitizer
    Assert-True ($missingOutput.errorCategory -eq "collection-output-missing") "Missing collection output must produce a deterministic failure envelope."

    $malformed = Invoke-Sanitizer -FixtureName "malformed.json"
    Assert-True ($malformed.errorCategory -eq "malformed-json") "Malformed JSON must produce a deterministic failure envelope."
    $incompatible = Invoke-Sanitizer -FixtureName "incompatible.json"
    Assert-True ($incompatible.errorCategory -eq "incompatible-schema") "An incompatible schema must fail closed."
    $incomplete = Invoke-Sanitizer -FixtureName "incomplete.json"
    Assert-True ($incomplete.errorCategory -eq "incomplete-query") "A partial query must fail closed."
    $wrongRepository = Invoke-Sanitizer -FixtureName "wrong-repository.json"
    Assert-True ($wrongRepository.errorCategory -eq "unexpected-repository") "The sanitizer must reject the wrong source repository."

    $repositoryCasePath = Join-Path $tempRoot "repository-case.json"
    $repositoryCase = Get-Content -Raw (Join-Path $fixtureRoot "complete-zero.json") | ConvertFrom-Json -Depth 100
    $repositoryCase.repository = "DOTNET/ASPNETCORE"
    Write-JsonFile -Value $repositoryCase -Path $repositoryCasePath
    $repositoryCaseResult = Invoke-Sanitizer -SourcePath $repositoryCasePath
    Assert-True ($repositoryCaseResult.errorCategory -eq "unexpected-repository") "Repository identity must use an ordinal comparison."

    $strictBooleanPath = Join-Path $tempRoot "strict-boolean.json"
    $strictBoolean = Get-Content -Raw (Join-Path $fixtureRoot "complete-zero.json") | ConvertFrom-Json -Depth 100
    $strictBoolean.query.complete = "false"
    Write-JsonFile -Value $strictBoolean -Path $strictBooleanPath
    $strictBooleanResult = Invoke-Sanitizer -SourcePath $strictBooleanPath
    Assert-True ($strictBooleanResult.errorCategory -eq "invalid-contract") "String false must not be treated as boolean true."

    $missingFieldPath = Join-Path $tempRoot "missing-field.json"
    $missingField = Get-Content -Raw (Join-Path $fixtureRoot "complete-zero.json") | ConvertFrom-Json -Depth 100
    $missingField.census.PSObject.Properties.Remove("matched")
    Write-JsonFile -Value $missingField -Path $missingFieldPath
    $missingFieldResult = Invoke-Sanitizer -SourcePath $missingFieldPath
    Assert-True ($missingFieldResult.errorCategory -eq "invalid-contract") "Missing counts must not silently become zero."

    $mismatchedCensusPath = Join-Path $tempRoot "mismatched-census.json"
    $mismatchedCensus = Get-Content -Raw (Join-Path $fixtureRoot "complete-zero.json") | ConvertFrom-Json -Depth 100
    $mismatchedCensus.census.openPullRequests = 1
    Write-JsonFile -Value $mismatchedCensus -Path $mismatchedCensusPath
    $mismatchedCensusResult = Invoke-Sanitizer -SourcePath $mismatchedCensusPath
    Assert-True ($mismatchedCensusResult.errorCategory -eq "invalid-contract") "Query and census inventory counts must agree."

    $duplicateNumberPath = Join-Path $tempRoot "duplicate-number.json"
    $duplicateNumber = Get-Content -Raw (Join-Path $fixtureRoot "normal-legacy.json") | ConvertFrom-Json -Depth 100
    $duplicateNumber.items[1].number = $duplicateNumber.items[0].number
    Write-JsonFile -Value $duplicateNumber -Path $duplicateNumberPath
    $duplicateNumberResult = Invoke-Sanitizer -SourcePath $duplicateNumberPath
    Assert-True ($duplicateNumberResult.errorCategory -eq "invalid-contract") "Duplicate pull request numbers must fail closed."

    $duplicateRankPath = Join-Path $tempRoot "duplicate-rank.json"
    $duplicateRank = Get-Content -Raw (Join-Path $fixtureRoot "normal-legacy.json") | ConvertFrom-Json -Depth 100
    $duplicateRank.items[1].digestRank = $duplicateRank.items[0].digestRank
    Write-JsonFile -Value $duplicateRank -Path $duplicateRankPath
    $duplicateRankResult = Invoke-Sanitizer -SourcePath $duplicateRankPath
    Assert-True ($duplicateRankResult.errorCategory -eq "invalid-contract") "Duplicate view ranks must fail closed."

    $bucketCasePath = Join-Path $tempRoot "bucket-case.json"
    $bucketCase = Get-Content -Raw (Join-Path $fixtureRoot "normal-legacy.json") | ConvertFrom-Json -Depth 100
    $bucketCase.items[0].bucket = $bucketCase.items[0].bucket.ToLowerInvariant()
    Write-JsonFile -Value $bucketCase -Path $bucketCasePath
    $bucketCaseResult = Invoke-Sanitizer -SourcePath $bucketCasePath
    Assert-True ($bucketCaseResult.errorCategory -eq "invalid-contract") "Legacy bucket names must use ordinal comparisons."

    $reasonCasePath = Join-Path $tempRoot "reason-case.json"
    $reasonCase = Get-Content -Raw (Join-Path $fixtureRoot "normal-legacy.json") | ConvertFrom-Json -Depth 100
    $reasonCase.items[0].reasonCodes[0] = $reasonCase.items[0].reasonCodes[0].ToUpperInvariant()
    Write-JsonFile -Value $reasonCase -Path $reasonCasePath
    $reasonCaseResult = Invoke-Sanitizer -SourcePath $reasonCasePath
    Assert-True ($reasonCaseResult.errorCategory -eq "invalid-contract") "Stable reason codes must remain lowercase exact contract values."

    $discussionCountPath = Join-Path $tempRoot "discussion-count.json"
    $discussionCount = Get-Content -Raw (Join-Path $fixtureRoot "normal-legacy.json") | ConvertFrom-Json -Depth 100
    $discussionCount.discussion.verificationNeededCount = 2
    Write-JsonFile -Value $discussionCount -Path $discussionCountPath
    $discussionCountResult = Invoke-Sanitizer -SourcePath $discussionCountPath
    Assert-True ($discussionCountResult.errorCategory -eq "invalid-contract") "Discussion summary counts must match assessment states."

    $boundedDiscussionPath = Join-Path $tempRoot "bounded-discussion.json"
    $boundedDiscussion = Get-Content -Raw (Join-Path $fixtureRoot "normal-legacy.json") | ConvertFrom-Json -Depth 100
    $boundedDiscussion.items[2].shownInDiscussionVerification = $false
    $boundedDiscussion.items[2].discussionVerificationRank = $null
    Write-JsonFile -Value $boundedDiscussion -Path $boundedDiscussionPath
    $boundedDiscussionResult = Invoke-Sanitizer -SourcePath $boundedDiscussionPath
    Assert-True ($boundedDiscussionResult.status -eq "complete") "A bounded discussion view may show fewer candidates than the full verification-needed count."
    Assert-True (@($boundedDiscussionResult.views.verifyDiscussionBeforeReview).Count -eq 0) "The sanitizer must preserve bounded discussion-view membership without reclassification."
    Assert-True ($boundedDiscussionResult.source.discussion.verificationNeededCount -eq 1) "The full verification-needed count must remain distinct from shown membership."

    $unassessedDiscussionPath = Join-Path $tempRoot "unassessed-discussion.json"
    $unassessedDiscussion = Get-Content -Raw (Join-Path $fixtureRoot "normal-legacy.json") | ConvertFrom-Json -Depth 100
    $unassessedDiscussion.discussion.candidateLimit = 2
    $unassessedDiscussion.discussion.assessedCandidateCount = 2
    $unassessedDiscussion.discussion.verificationNeededCount = 0
    $unassessedDiscussion.discussion.unassessedReviewNowCount = 1
    $unassessedDiscussion.items[2].shownInDiscussionVerification = $false
    $unassessedDiscussion.items[2].discussionVerificationRank = $null
    $unassessedDiscussion.items[2].discussionAssessment.state = "not-assessed"
    $unassessedDiscussion.items[2].discussionAssessment.complete = $false
    $unassessedDiscussion.items[2].discussionAssessment.signals = @("discussion-not-assessed")
    $unassessedDiscussion.items[2].discussionAssessment.commentTotalCount = 0
    $unassessedDiscussion.items[2].discussionAssessment.commentEvidenceTruncated = $false
    $unassessedDiscussion.items[2].discussionAssessment.threads.totalCount = 0
    $unassessedDiscussion.items[2].discussionAssessment.threads.returnedCount = 0
    $unassessedDiscussion.items[2].discussionAssessment.threads.complete = $false
    $unassessedDiscussion.items[2].discussionAssessment.threads.unresolvedCount = 0
    $unassessedDiscussion.items[2].discussionAssessment.threads.outdatedUnresolvedCount = 0
    Write-JsonFile -Value $unassessedDiscussion -Path $unassessedDiscussionPath
    $unassessedDiscussionResult = Invoke-Sanitizer -SourcePath $unassessedDiscussionPath
    Assert-True ($unassessedDiscussionResult.status -eq "complete") "A bounded legacy queue with unassessed Review now candidates must remain valid."
    Assert-True ($unassessedDiscussionResult.source.discussion.unassessedReviewNowCount -eq 1) "The unassessed Review now count must be preserved."

    $unexpectedDiscussionPath = Join-Path $tempRoot "unexpected-discussion.json"
    $unexpectedDiscussion = Get-Content -Raw (Join-Path $fixtureRoot "normal-legacy.json") | ConvertFrom-Json -Depth 100
    $unexpectedDiscussion.items[3].discussionAssessment = $unexpectedDiscussion.items[0].discussionAssessment
    Write-JsonFile -Value $unexpectedDiscussion -Path $unexpectedDiscussionPath
    $unexpectedDiscussionResult = Invoke-Sanitizer -SourcePath $unexpectedDiscussionPath
    Assert-True ($unexpectedDiscussionResult.errorCategory -eq "invalid-contract") "Non-ReviewNow items must not carry unnecessary discussion data."

    $invalidAuthorPath = Join-Path $tempRoot "invalid-author.json"
    $invalidAuthor = Get-Content -Raw (Join-Path $fixtureRoot "normal-legacy.json") | ConvertFrom-Json -Depth 100
    $invalidAuthor.items[0].author = "invalid author"
    Write-JsonFile -Value $invalidAuthor -Path $invalidAuthorPath
    $invalidAuthorResult = Invoke-Sanitizer -SourcePath $invalidAuthorPath
    Assert-True ($invalidAuthorResult.errorCategory -eq "invalid-contract") "Invalid author identifiers must fail closed."

    $oversizedPath = Join-Path $tempRoot "oversized.json"
    $oversized = Get-Content -Raw (Join-Path $fixtureRoot "normal-legacy.json") | ConvertFrom-Json -Depth 100
    $oversized.warnings = @(1..20 | ForEach-Object { "warning-$_ " + ("x" * 500) })
    Write-JsonFile -Value $oversized -Path $oversizedPath
    $oversizedResult = Invoke-Sanitizer -SourcePath $oversizedPath -MaxOutputBytes 4096
    Assert-True ($oversizedResult.errorCategory -eq "sanitized-output-too-large") "Oversized sanitized output must become a bounded failure envelope."

    $realFixtureExpectations = [ordered]@{
        "pull-requests.json" = @(5, 0, 3, 1)
        "correctness-pull-requests.json" = @(4, 1, 2, 1)
        "discussion-pull-requests.json" = @(2, 5, 0, 0)
    }
    foreach ($fixtureName in $realFixtureExpectations.Keys)
    {
        $realPulse = Invoke-RealQueueFixture -FixtureName $fixtureName
        Assert-True ($realPulse.status -eq "complete") "The sanitizer must accept real legacy output from $fixtureName."
        Assert-True ($realPulse.source.query.returnedPullRequestCount -eq $realPulse.source.census.matched) "The real fixture inventory must remain complete."
        $expectedCounts = $realFixtureExpectations[$fixtureName]
        Assert-True (@($realPulse.views.reviewNow).Count -eq $expectedCounts[0]) "The real $fixtureName Review now membership changed."
        Assert-True (@($realPulse.views.verifyDiscussionBeforeReview).Count -eq $expectedCounts[1]) "The real $fixtureName discussion verification membership changed."
        Assert-True (@($realPulse.views.needsRescue).Count -eq $expectedCounts[2]) "The real $fixtureName Needs rescue membership changed."
        Assert-True (@($realPulse.views.readyToMerge).Count -eq $expectedCounts[3]) "The real $fixtureName Ready to merge membership changed."
        $realBody = Invoke-Renderer -Pulse $realPulse
        Invoke-PublicationValidator -Pulse $realPulse -AgentOutput (New-ValidAgentOutput -Body $realBody) -ExpectedBody $realBody
    }

    $normalBody = Invoke-Renderer -Pulse $normal
    Assert-True ([string]::Equals($normalBody, $normalBody.TrimEnd(), [StringComparison]::Ordinal)) "Canonical rendering must not contain collector-trimmed trailing whitespace."
    $postIngestionBody = Invoke-PinnedOutputSanitizer -Content $normalBody
    Assert-True ([string]::Equals($postIngestionBody, $normalBody, [StringComparison]::Ordinal)) "Pinned gh-aw output sanitization must preserve the complete canonical report byte-for-byte."
    Assert-True ([string]::Equals((Invoke-PinnedOutputSanitizer -Content $postIngestionBody), $postIngestionBody, [StringComparison]::Ordinal)) "Pinned output sanitization must be idempotent for the canonical report."
    $expectedHeadings = @(
        "### Freshness and scope",
        "### Summary counts",
        "### Review now",
        "### Verify discussion before review",
        "### Needs rescue",
        "### Ready to merge",
        "### Coverage and data quality"
    )
    $lastIndex = -1
    foreach ($heading in $expectedHeadings)
    {
        $index = $normalBody.IndexOf($heading, [StringComparison]::Ordinal)
        Assert-True ($index -gt $lastIndex) "Rendered section '$heading' is missing or out of order."
        $lastIndex = $index
    }
    Assert-True ($normalBody.Contains('`dotnet/aspnetcore#101`')) "Rendered identifiers must be fully qualified and non-linking."
    Assert-True ($normalBody.Contains("2026-09-10T20:04:56.0000000Z")) "Rendered timestamps must be deterministic invariant ISO values."
    Assert-True ($normalBody.Contains("Queue census: Review now 3; Needs rescue 1; Ready to merge 1")) "Rendered output must preserve the engine-provided bucket census."
    Assert-True (-not $normalBody.Contains("https://")) "Rendered output must not contain URLs."
    Assert-True (-not ($normalBody -match "(?<![\w])@[A-Za-z0-9]")) "Rendered output must not mention authors."
    $normalBodyWithoutAllowedReferences = [regex]::Replace($normalBody, "``dotnet/aspnetcore#[0-9]+``", "")
    Assert-True (-not ($normalBodyWithoutAllowedReferences -match "(?<!#)#[0-9]+")) "Rendered output must not contain bare issue references."

    $failureBody = Invoke-Renderer -Pulse $collectionFailure
    Assert-True ($failureBody.StartsWith("> [!WARNING]`n> Attention data unavailable")) "Failure rendering must prominently report unavailable data."
    Assert-True ($failureBody.Contains("Candidate counts unavailable.")) "Failure rendering must mark counts unavailable."
    Assert-True (-not $failureBody.Contains("Open pull requests: 0")) "Failure rendering must not present unavailable counts as zero."
    foreach ($heading in $expectedHeadings)
    {
        Assert-True ($failureBody.Contains($heading)) "Failure rendering must retain section '$heading'."
    }

    $validOutput = Invoke-PinnedCollector -Body $postIngestionBody
    Assert-True ($validOutput.errors -is [array] -and $validOutput.errors.Count -eq 0) "The pinned collector must accept the canonical report without errors."
    Assert-True (@($validOutput.items).Count -eq 1) "The pinned collector must emit exactly one update item."
    Assert-True ([string]::Equals($validOutput.items[0].body, $postIngestionBody, [StringComparison]::Ordinal)) "The pinned collector must preserve the trusted-normalized body byte-for-byte."
    Invoke-PublicationValidator -Pulse $normal -AgentOutput $validOutput -ExpectedBody $postIngestionBody
    $publicationBodyPath = Join-Path $tempRoot "publication-body.md"
    [IO.File]::WriteAllText($publicationBodyPath, $validOutput.items[0].body, [Text.UTF8Encoding]::new($false))
    & node (Join-Path $testRoot "Test-PulseIssueUpdate.cjs") $collectorJsRoot $lockPath $publicationBodyPath
    Assert-True ($LASTEXITCODE -eq 0) "The pinned issue handler must publish the validated body without mutation."
    Invoke-PublicationValidator -Pulse $zero -AgentOutput (New-ValidAgentOutput -Body $zeroBody) -ExpectedBody $zeroBody

    $failureEnvelopes = [ordered]@{
        "collection-failed" = $collectionFailure
        "collection-output-missing" = $missingOutput
        "malformed-json" = $malformed
        "incompatible-schema" = $incompatible
        "incomplete-query" = $incomplete
        "unexpected-repository" = $wrongRepository
        "invalid-contract" = $strictBooleanResult
        "sanitized-output-too-large" = $oversizedResult
    }
    foreach ($expectedCategory in $failureEnvelopes.Keys)
    {
        $failureEnvelope = $failureEnvelopes[$expectedCategory]
        Assert-True ($failureEnvelope.errorCategory -eq $expectedCategory) "The '$expectedCategory' failure fixture produced the wrong category."
        $canonicalFailureBody = Invoke-Renderer -Pulse $failureEnvelope
        Invoke-PublicationValidator `
            -Pulse $failureEnvelope `
            -AgentOutput (New-ValidAgentOutput -Body $canonicalFailureBody) `
            -ExpectedBody $canonicalFailureBody
    }

    foreach ($legitimateTitle in @(
        "Fix placeholder text in InputText",
        "Preserve TODO text in diagnostics",
        "Avoid test body regression",
        "Handle report_incomplete status text"))
    {
        $legitimateTitlePath = Join-Path $tempRoot "legitimate-title-$([guid]::NewGuid().ToString('N')).json"
        $legitimateTitleInput = Get-Content -Raw (Join-Path $fixtureRoot "normal-legacy.json") | ConvertFrom-Json -Depth 100
        $legitimateTitleInput.items[0].title = $legitimateTitle
        Write-JsonFile -Value $legitimateTitleInput -Path $legitimateTitlePath
        $legitimateTitlePulse = Invoke-Sanitizer -SourcePath $legitimateTitlePath
        Assert-True ($legitimateTitlePulse.status -eq "complete") "A legitimate pull request title containing '$legitimateTitle' must remain publishable."
        $legitimateTitleBody = Invoke-PinnedOutputSanitizer -Content (Invoke-Renderer -Pulse $legitimateTitlePulse)
        Invoke-PublicationValidator `
            -Pulse $legitimateTitlePulse `
            -AgentOutput (New-ValidAgentOutput -Body $legitimateTitleBody) `
            -ExpectedBody $legitimateTitleBody
    }

    foreach ($unicodeTitle in @(
        "Handle soft$([char]0x00AD)hyphen input",
        "Support woman$([char]0x200D)technologist input",
        "Normalize Greek $([char]0x0391) input"))
    {
        $unicodeTitlePath = Join-Path $tempRoot "unicode-title-$([guid]::NewGuid().ToString('N')).json"
        $unicodeTitleInput = Get-Content -Raw (Join-Path $fixtureRoot "normal-legacy.json") | ConvertFrom-Json -Depth 100
        $unicodeTitleInput.items[0].title = $unicodeTitle
        Write-JsonFile -Value $unicodeTitleInput -Path $unicodeTitlePath
        $unicodeTitlePulse = Invoke-Sanitizer -SourcePath $unicodeTitlePath
        $preIngestionBody = Invoke-Renderer -Pulse $unicodeTitlePulse
        $unicodeTitleBody = Invoke-PinnedOutputSanitizer -Content $preIngestionBody
        Assert-True (-not [string]::Equals($unicodeTitleBody, $preIngestionBody, [StringComparison]::Ordinal)) "The pinned normalizer must exercise the Unicode mutation case '$unicodeTitle'."
        Assert-True ([string]::Equals((Invoke-PinnedOutputSanitizer -Content $unicodeTitleBody), $unicodeTitleBody, [StringComparison]::Ordinal)) "Pinned output sanitization must be idempotent after normalizing '$unicodeTitle'."
        Invoke-PublicationValidator `
            -Pulse $unicodeTitlePulse `
            -AgentOutput (Invoke-PinnedCollector -Body $unicodeTitleBody) `
            -ExpectedBody $unicodeTitleBody
    }

    $wrongIssue = New-ValidAgentOutput -Body $normalBody
    $wrongIssue.items[0].issue_number = 59
    Assert-Throws { Invoke-PublicationValidator -Pulse $normal -AgentOutput $wrongIssue -ExpectedBody $normalBody } "The publication boundary must reject the wrong fixed issue."

    $append = New-ValidAgentOutput -Body $normalBody
    $append.items[0].operation = "append"
    Assert-Throws { Invoke-PublicationValidator -Pulse $normal -AgentOutput $append -ExpectedBody $normalBody } "The publication boundary must reject append operations."

    $multiple = New-ValidAgentOutput -Body $normalBody
    $multiple.items += $multiple.items[0]
    Assert-Throws { Invoke-PublicationValidator -Pulse $normal -AgentOutput $multiple -ExpectedBody $normalBody } "The publication boundary must reject multiple outputs."

    $missingErrors = New-ValidAgentOutput -Body $normalBody
    $missingErrors.PSObject.Properties.Remove("errors")
    Assert-Throws { Invoke-PublicationValidator -Pulse $normal -AgentOutput $missingErrors -ExpectedBody $normalBody } "The publication boundary must require the collector errors array."

    $collectorErrors = New-ValidAgentOutput -Body $normalBody
    $collectorErrors.errors = @("Line 1: rejected")
    Assert-Throws { Invoke-PublicationValidator -Pulse $normal -AgentOutput $collectorErrors -ExpectedBody $normalBody } "The publication boundary must reject collector validation errors."

    $wrongType = New-ValidAgentOutput -Body $normalBody
    $wrongType.items[0].type = "report_incomplete"
    Assert-Throws { Invoke-PublicationValidator -Pulse $normal -AgentOutput $wrongType -ExpectedBody $normalBody } "The publication boundary must reject other output types."

    $wrongTypeCase = New-ValidAgentOutput -Body $normalBody
    $wrongTypeCase.items[0].type = "UPDATE_ISSUE"
    Assert-Throws { Invoke-PublicationValidator -Pulse $normal -AgentOutput $wrongTypeCase -ExpectedBody $normalBody } "The publication boundary must reject alternate output type casing."

    $wrongOperationCase = New-ValidAgentOutput -Body $normalBody
    $wrongOperationCase.items[0].operation = "REPLACE"
    Assert-Throws { Invoke-PublicationValidator -Pulse $normal -AgentOutput $wrongOperationCase -ExpectedBody $normalBody } "The publication boundary must reject alternate operation casing."

    $forbiddenMutation = New-ValidAgentOutput -Body $normalBody
    $forbiddenMutation.items[0] | Add-Member -NotePropertyName labels -NotePropertyValue @("bug")
    Assert-Throws { Invoke-PublicationValidator -Pulse $normal -AgentOutput $forbiddenMutation -ExpectedBody $normalBody } "The publication boundary must reject fields that could mutate anything except the body."

    $placeholder = New-ValidAgentOutput -Body "test body"
    Assert-Throws { Invoke-PublicationValidator -Pulse $normal -AgentOutput $placeholder -ExpectedBody $normalBody } "The publication boundary must reject placeholder reports."

    Assert-Throws { Invoke-PublicationValidator -Pulse $normal -AgentOutputJson "{not-json" -ExpectedBody $normalBody } "Malformed agent output must fail closed."

    $alteredBody = New-ValidAgentOutput -Body ($normalBody.Replace("Review now", "Review later"))
    Assert-Throws { Invoke-PublicationValidator -Pulse $normal -AgentOutput $alteredBody -ExpectedBody $normalBody } "The publication boundary must reject altered reports."

    $invisibleMutation = New-ValidAgentOutput -Body ($normalBody.Replace("These views", "These$([char]0x00AD) views"))
    Assert-Throws { Invoke-PublicationValidator -Pulse $normal -AgentOutput $invisibleMutation -ExpectedBody $normalBody } "The publication boundary must use ordinal equality and reject invisible mutations."

    $wrongExpectedBody = $normalBody + "extra"
    Assert-Throws { Invoke-PublicationValidator -Pulse $normal -AgentOutput $validOutput -ExpectedBody $wrongExpectedBody } "The publication boundary must reject a body not derived from sanitized input."

    Assert-True (Test-Path $workflowPath) "The Pulse workflow source must exist."
    $workflow = Get-Content -Raw $workflowPath
    Assert-True ($workflow.Contains("github.repository == 'PureWeen/aspnetcore'")) "The workflow must reject every repository except the fork."
    Assert-True ($workflow.Contains("checkout: false")) "The compiler-managed checkout must be disabled."
    $preStepsIndex = [regex]::Match($workflow, "(?m)^pre-steps:").Index
    $stepsIndex = $workflow.IndexOf("steps:", $preStepsIndex + "pre-steps:".Length, [StringComparison]::Ordinal)
    $checkoutIndex = $workflow.IndexOf("uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", [StringComparison]::Ordinal)
    Assert-True ($preStepsIndex -ge 0 -and $checkoutIndex -gt $preStepsIndex -and $checkoutIndex -lt $stepsIndex) "The explicit trusted checkout must run only in top-level pre-steps."
    Assert-True ($workflow.Contains("persist-credentials: false")) "The trusted checkout must not persist credentials."
    Assert-True ($workflow.Contains(".github/skills/pr-attention-queue")) "The trusted checkout must include the legacy queue implementation."
    Assert-True ($workflow.Contains(".github/workflows/pr-attention-pulse")) "The trusted checkout must include the Pulse support scripts."
    Assert-True (-not $workflow.Contains("contents/`$path")) "Trusted source acquisition must not use an additional token-backed Contents API path."
    Assert-True ([regex]::Matches($workflow, "Assert-PrivateValidatorRoot -Path").Count -eq 2) "Private validator storage must be checked before canonical copy and before validation."
    Assert-True ($workflow.Contains('Get-CanonicalPath -Path $env:GITHUB_WORKSPACE')) "The private validator root must be outside the symlink-resolved workspace."
    Assert-True ($workflow.Contains('Get-CanonicalPath -Path "/tmp"')) "The private validator root must be outside symlink-resolved /tmp."
    Assert-True ($workflow.Contains('Join-Path $env:RUNNER_TEMP "gh-aw"')) "The private validator root must be outside the symlink-resolved AWF runtime directory."
    Assert-True ($workflow.Contains("Normalize the trusted Pulse body for ingestion")) "The trusted renderer output must pass through the pinned runtime output sanitizer."
    Assert-True ($workflow.Contains('require(path.join(actionsDir, "sanitize_content.cjs"))')) "Trusted normalization must reuse the pinned gh-aw sanitizer."
    Assert-True ($workflow.Contains('GH_AW_SANITIZER_MODULE_PATH: ${{ runner.temp }}/gh-aw/actions/sanitize_content.cjs')) "Post-agent canonical verification must receive the same pinned sanitizer path."
    Assert-True ($workflow.Contains("-SanitizerModulePath `$env:GH_AW_SANITIZER_MODULE_PATH")) "Post-agent canonical verification must use the pinned sanitizer path."
    Assert-True ($workflow.Contains('bash: ["cat"]')) "Publication must not expand the shell allowlist."
    Assert-True ($workflow.Contains('Remove-Item .pr-attention-pulse/pulse-request.json')) "The serialized request must be removed after inference."
    Assert-True ($workflow.Contains("issue_number: 58")) "The emitted payload must use the fixed dashboard issue."
    Assert-True ($workflow.Contains('target: "58"')) "The safe-output handler must reject a different issue target."
    Assert-True ($workflow.Contains("operation: replace")) "The payload contract must replace the issue body."
    Assert-True (($workflow | Select-String -Pattern "type: update_issue" -AllMatches).Matches.Count -eq 1) "The prompt must define exactly one update_issue payload."
    Assert-True ($workflow.Contains("github: false")) "The inference sandbox must not mount GitHub tools."
    Assert-True ($workflow -match "network:\s+allowed:\s+\[\]") "The inference sandbox must have no network."
    Assert-True ($workflow.Contains("max-ai-credits: -1")) "Detector token steering must be disabled by removing its credit budget."
    Assert-True ($workflow.Contains("if: always()")) "The trusted publication validator must run even after an earlier agent-job failure."
    Assert-True ($workflow.Contains('pr-attention-pulse-validator/pulse-input.json')) "Post-validation must use the pre-agent trusted input copy."
    Assert-True ($workflow.Contains('pr-attention-pulse-validator/pulse-body.md')) "Post-validation must use the pre-agent trusted body copy."
    Assert-True (-not $workflow.Contains("reviewLifecycle")) "The workflow must not use post-legacy lifecycle fields."
    Assert-True (-not $workflow.Contains("groupOrder")) "The workflow must not use post-legacy group ordering."
    Assert-True (-not $workflow.Contains("merge-candidates")) "The workflow must not use merge-candidate semantics."
    Assert-True ($workflow.Contains("mentions: false")) "Safe output mentions must be disabled."
    Assert-True ($workflow.Contains("allowed-github-references: []")) "GitHub references must be non-linking."
    Assert-True (-not ($workflow -match "https://github\.com/dotnet/aspnetcore")) "Fork artifacts must not contain an upstream backlink."
    Assert-True (Test-Path $compilePath) "The scoped compiler helper must be present."
    $compileHelper = Get-Content -Raw $compilePath
    Assert-True ($compileHelper.Contains('SetEnvironmentVariable($policyVariable, "gpt-5.6-sol", "Process")')) "The compile helper must scope the singleton model policy to its process."
    Assert-True ($compileHelper.Contains("finally")) "The compile helper must restore the caller's process environment."

    Assert-True (Test-Path $lockPath) "The generated Pulse lock must exist."
    $lock = Get-Content -Raw $lockPath
    $normalizedLock = $lock.Replace("\", "")
    $metadataLine = (Get-Content $lockPath | Select-Object -First 1)
    Assert-True ($metadataLine.Contains('"agent_model":"gpt-5.6-sol"')) "The main agent metadata must pin gpt-5.6-sol."
    Assert-True ($metadataLine.Contains('"detection_agent_model":"gpt-5.6-sol"')) "Threat detection metadata must pin gpt-5.6-sol."
    Assert-True (($lock | Select-String -Pattern "COPILOT_MODEL: gpt-5\.6-sol" -AllMatches).Matches.Count -eq 2) "Both inference stages must receive exactly gpt-5.6-sol."

    $awfConfigLines = @(
        Get-Content $lockPath |
            Where-Object {
                $_.Contains("printf '%s\n'") -and
                $_.Contains("awf-config.schema.json") -and
                $_.Contains('> "${RUNNER_TEMP}/gh-aw/awf-config.json"')
            }
    )
    Assert-True ($awfConfigLines.Count -eq 2) "Exactly two inference AWF configurations are expected."
    foreach ($line in $awfConfigLines)
    {
        $normalizedLine = $line.Replace("\", "")
        Assert-True ($normalizedLine.Contains('"allowedModels":["gpt-5.6-sol"]')) "Every inference stage must enforce the singleton model allowlist."
        Assert-True ($normalizedLine.Contains("v0.28.14")) "Every inference stage must use the reviewed AWF v0.28.14 runtime."
    }
    $mainConfigLine = $awfConfigLines[0].Replace("\", "")
    $detectorConfigLine = $awfConfigLines[1].Replace("\", "")
    Assert-True ($mainConfigLine.Contains('"enableTokenSteering":false')) "Main-agent token steering must be explicitly disabled."
    Assert-True ($mainConfigLine.Contains('"modelFallback":{"enabled":false}')) "Main-agent model fallback must be explicitly disabled."
    Assert-True (-not $detectorConfigLine.Contains("enableTokenSteering")) "Detector token steering must be absent, which is false in AWF."
    Assert-True (-not $detectorConfigLine.Contains("maxAiCredits")) "Detector credit budgeting must be absent to keep token steering disabled."
    Assert-True (-not $detectorConfigLine.Contains("modelFallback")) "Detector fallback is enforced behaviorally by the singleton post-rewrite model policy, not a literal field."
    Assert-True (-not $lock.Contains("GH_AW_EVALS_MODEL")) "No evaluation inference stage may be introduced."
    $publicationPreparationIndex = $lock.IndexOf("name: Preserve canonical Pulse body on publication", [StringComparison]::Ordinal)
    $publicationJobIndex = $lock.IndexOf("`n  safe_outputs:", [StringComparison]::Ordinal)
    $publicationHandlerIndex = $lock.IndexOf("name: Process Safe Outputs", [StringComparison]::Ordinal)
    Assert-True ($publicationPreparationIndex -gt $publicationJobIndex -and $publicationPreparationIndex -lt $publicationHandlerIndex) "Workflow-id decoration must be disabled only in the publication job before the real handler."
    Assert-True ([regex]::Matches($lock, 'core\.exportVariable\("GH_AW_WORKFLOW_ID", ""\)').Count -eq 1) "Only one publication-scoped workflow-id override is allowed."
    Assert-True (-not $lock.Contains("Configure Git credentials")) "No generated git credential step may run without a checkout."
    Assert-True ([regex]::Matches($lock, "(?m)^  safe-outputs:").Count -eq 0) "The hyphenated job alias must not create a custom mutation-capable job."
    Assert-True ([regex]::Matches($lock, "(?m)^  safe_outputs:").Count -eq 1) "Exactly one built-in safe-output job must be generated."
    $checkoutCount = [regex]::Matches($lock, "uses: actions/checkout@").Count
    Assert-True ($checkoutCount -gt 0) "Generated framework checkouts must remain inspectable."
    Assert-True ([regex]::Matches($lock, "persist-credentials: false").Count -eq $checkoutCount) "Every generated checkout must discard its credential."
    Assert-True (-not $lock.Contains('"name":"github","tools"')) "The inference sandbox must not mount the GitHub MCP server."
    Assert-True ($normalizedLock.Contains('"mcp_servers":[{"name":"safeoutputs","tools":["update_issue"]}]')) "Only the fixed update_issue safe-output tool may be mounted."
    Assert-True (($lock | Select-String -Pattern "--exclude-env COPILOT_GITHUB_TOKEN" -AllMatches).Matches.Count -eq 2) "Provider authentication must be excluded from both inference containers."
    $agentStepStart = $lock.IndexOf("- name: Execute GitHub Copilot CLI", [StringComparison]::Ordinal)
    $agentStepEnd = $lock.IndexOf("- name: Detect agent errors", $agentStepStart, [StringComparison]::Ordinal)
    Assert-True ($agentStepStart -ge 0 -and $agentStepEnd -gt $agentStepStart) "The generated main inference step could not be isolated."
    $agentStep = $lock.Substring($agentStepStart, $agentStepEnd - $agentStepStart)
    Assert-True (-not ($agentStep -match "(?m)^\s+(?:GH_TOKEN|GH_AW_GITHUB_TOKEN|GITHUB_MCP_SERVER_TOKEN|GITHUB_TOKEN):")) "GitHub credentials must not be present in the main inference step environment."
    Assert-True ($normalizedLock.Contains('"target":"58"')) "The generated safe-output policy must pin issue 58."
    Assert-True ($normalizedLock.Contains('"required_title_prefix":"[pr-attention-pulse]"')) "The generated safe-output policy must require the dashboard title prefix."
    Assert-True (-not $normalizedLock.Contains('"create_issue"')) "The generated workflow must not expose issue creation."
    Assert-True ($lock.IndexOf("Remove-Item -Recurse -Force .github", [StringComparison]::Ordinal) -lt $agentStepStart) "Repository workflow sources and raw data must be removed before inference."
    $validatorStepIndex = $lock.IndexOf("name: Validate the sole publication payload", [StringComparison]::Ordinal)
    $evidenceStepIndex = $lock.IndexOf("name: Upload validated Pulse publication evidence", [StringComparison]::Ordinal)
    $cleanupStepIndex = $lock.IndexOf("name: Remove sanitized Pulse data", [StringComparison]::Ordinal)
    Assert-True ($evidenceStepIndex -gt $validatorStepIndex -and $evidenceStepIndex -lt $cleanupStepIndex) "Canonical audit evidence must be retained only after validation and before cleanup."
    $evidenceStep = $lock.Substring($evidenceStepIndex, $cleanupStepIndex - $evidenceStepIndex)
    Assert-True ($evidenceStep.Contains('pr-attention-pulse-validator/pulse-input.json') -and $evidenceStep.Contains('pr-attention-pulse-validator/pulse-body.md')) "Publication evidence must use the private canonical copies, not model-visible files."
    Assert-True (-not $lock.Contains("--allow-tool shell(jq)")) "Publication must not grant jq permission."
    $fallbackArtifactIndex = $lock.IndexOf("name: Upload agent output fallback artifact", [StringComparison]::Ordinal)
    Assert-True ($validatorStepIndex -gt $agentStepStart -and $validatorStepIndex -lt $fallbackArtifactIndex) "Trusted validation must run before either publication artifact is uploaded."
    Assert-True ($lock.Substring([Math]::Max(0, $validatorStepIndex - 40), [Math]::Min(120, $lock.Length - [Math]::Max(0, $validatorStepIndex - 40))).Contains("if: always()")) "Trusted validation must run after any earlier agent-job failure."
    $canonicalCopyIndex = $lock.IndexOf("Copy-Item .pr-attention-pulse/pulse-input.json", [StringComparison]::Ordinal)
    $normalizationStepIndex = $lock.IndexOf("name: Normalize the trusted Pulse body for ingestion", [StringComparison]::Ordinal)
    $firstPrivateRootCheckIndex = $lock.IndexOf("Assert-PrivateValidatorRoot -Path `$validatorRoot", [StringComparison]::Ordinal)
    $secondPrivateRootCheckIndex = $lock.LastIndexOf("Assert-PrivateValidatorRoot -Path", [StringComparison]::Ordinal)
    $validatorInvocationIndex = $lock.IndexOf("Validate-PRAttentionPulseOutput.ps1", $secondPrivateRootCheckIndex, [StringComparison]::Ordinal)
    Assert-True ($normalizationStepIndex -ge 0 -and $normalizationStepIndex -lt $firstPrivateRootCheckIndex) "Pinned output normalization must run before the canonical body is protected."
    Assert-True ($firstPrivateRootCheckIndex -ge 0 -and $firstPrivateRootCheckIndex -lt $canonicalCopyIndex) "The private validator root must be checked before canonical data is copied."
    Assert-True ($secondPrivateRootCheckIndex -gt $validatorStepIndex -and $secondPrivateRootCheckIndex -lt $validatorInvocationIndex) "The private validator root must be checked again immediately before validation."
    Assert-True (-not ($lock -match "--mount[^\r\n]*pr-attention-pulse-validator")) "The private validator root must not be mounted into either inference sandbox."
    Assert-True ($lock.Contains('(always() && needs.agent.result != ''skipped'') && (needs.agent.result == ''success'')')) "Threat detection must require successful trusted validation."
    Assert-True ($lock.Contains('(needs.agent.result == ''success'')')) "Safe-output publication must require successful trusted validation."
    Assert-True ($lock.Contains('daily_ai_credits_exceeded == ''true'')) && (false)')) "The conclusion job must be unreachable so detector/failure tracking cannot mutate GitHub."
    Assert-True ($lock.Contains("GH_AW_VALIDATION_JSON")) "The generated lock must expose the exact collector validation contract."
    Assert-True ($lock -match '"body":\s*\{\s*"type": "string",\s*"sanitize": true,\s*"maxLength": 65000') "The generated collector must sanitize and bound the issue body."
    Assert-True ($lock -match '"operation":\s*\{\s*"type": "string",\s*"enum":\s*\[\s*"replace"') "The generated collector must preserve the replacement operation contract."
    Assert-True ($lock -match "permissions:\s+contents: read") "The generated agent job must keep minimum read-only repository permissions."
    Assert-True ($lock -match "permissions:\s+issues: write") "Only the safe-output publication job may receive issue write permission."

    Write-Output "PR Attention Pulse tests passed."
}
finally
{
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
