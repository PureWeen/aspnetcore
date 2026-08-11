[CmdletBinding()]
param(
    [ValidateSet('All', 'Reviewer', 'TryFix')]
    [string] $Suite = 'All'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ReviewerEvalTools.psm1') -Force

$script:Passed = 0
$script:Failed = [Collections.Generic.List[string]]::new()

function Invoke-Test
{
    param(
        [string] $Name,
        [scriptblock] $Body
    )

    try
    {
        & $Body
        $script:Passed++
        Write-Host "PASS $Name"
    }
    catch
    {
        $script:Failed.Add("$Name`: $($_.Exception.Message)")
        Write-Host "FAIL $Name"
    }
}

function Assert-True
{
    param(
        [bool] $Condition,
        [string] $Message
    )

    if (-not $Condition)
    {
        throw $Message
    }
}

function Assert-Equal
{
    param(
        $Expected,
        $Actual,
        [string] $Message
    )

    if ($Expected -ne $Actual)
    {
        throw "$Message Expected '$Expected', actual '$Actual'."
    }
}

function New-ValidReviewArtifacts
{
    param([string] $Root)

    $nonEmpty = @(
        'evidence/manifest.md', 'evidence/product-oracle.md', 'evidence/head-drift.md',
        'evidence/impact-map.md', 'candidates/candidate-a.md', 'candidates/candidate-b.md',
        'candidates/candidate-c.md', 'candidates/candidate-d.md',
        'cross-examination/candidate-a.md', 'cross-examination/candidate-b.md',
        'cross-examination/candidate-c.md', 'cross-examination/candidate-d.md',
        'empirical/manifest.md', 'empirical/head.log', 'empirical/claim-matrix.md',
        'empirical/stress-matrix.md', 'empirical/result.md',
        'final/repository-oracle.md', 'final/review.md'
    )
    $existing = @(
        'evidence/tracked.diff', 'empirical/before.diff', 'empirical/diagnostic.diff',
        'empirical/implementation.diff', 'empirical/red.log', 'empirical/candidate.diff',
        'empirical/green.log'
    )
    foreach ($relativePath in $nonEmpty)
    {
        $path = Join-Path $Root $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        Set-Content -LiteralPath $path -Value 'evidence'
    }
    foreach ($relativePath in $existing)
    {
        $path = Join-Path $Root $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        New-Item -ItemType File -Path $path -Force | Out-Null
    }

    @'
# Multi-Model Review
**Orchestrator:** gpt-test
**Path:** bounded
## Current fix
Current.
## Independent candidates
Candidates.
## Adversarial consensus
Consensus.
## Test assessment
Assessment.
## Proof status
**Frozen-head result:** pass
**Finding proof:** missing
**Scenario proof:** missing
**Candidate proof:** none
**Product oracle:** documented
**Oracle fidelity:** authoritative
**Mechanism fidelity:** structural
**Scenario fidelity:** exact
**Regression assertion disposition:** rejected
**Diagnostic mutation disposition:** not-applicable
## Final recommendation
**Implementation verdict:** KEEP CURRENT FIX
**Behavioral evidence:** missing
**Merge readiness:** recommendation only
**Implementation confidence:** medium
**Reason:** No material claim survived.
## Required follow-ups
None.
## Repository oracle gaps
None.
## Suggested review comments
None.
'@ | Set-Content -LiteralPath (Join-Path $Root 'final/review.md')
}

$configuration = Get-ReviewerEvalConfiguration
$expectedOutputs = Get-ExpectedVallyOutputs

if ($Suite -in @('All', 'Reviewer'))
{
    Invoke-Test 'Reviewer manifest validates independently' {
        $result = Test-EvalSuites -Paths @($configuration.ReviewerEvals)
        Assert-Equal 0 $result.Errors.Count 'Reviewer validation failed.'
        Assert-True ($result.Records.Count -gt 0) 'Reviewer suite had no records.'
    }

    Invoke-Test 'Reviewer validator warns on prompt-answer overlap' {
        $fixture = Join-Path ([IO.Path]::GetTempPath()) "eval-overlap-$([guid]::NewGuid()).md"
        $manifest = Join-Path ([IO.Path]::GetTempPath()) "eval-overlap-$([guid]::NewGuid()).json"
        try
        {
            Set-Content -LiteralPath $fixture -Value 'fixture'
            $eval = @{
                skill_name = 'test'
                evals = @(@{
                    id = 1
                    prompt = 'alpha-bravo charlie-delta echo-foxtrot'
                    expected_output = 'bounded'
                    files = @($fixture)
                    expectations = @('alpha-bravo charlie-delta echo-foxtrot')
                    eval_metadata = @{
                        mechanism = 'overlap-check'
                        provenance = @{ kind = 'synthetic'; source = 'overlap' }
                        area = 'Testing'
                        score_family = 'overlap'
                        tier = 'train'
                        discovery_mode = 'discovery'
                        controls = @{ positive = @(0); negative = @(0) }
                        forbidden_prompt_terms = @('not-present')
                    }
                })
            }
            $eval.evals[0].eval_metadata.controls.negative = @(0)
            $eval.evals[0].expectations += 'unrelated negative'
            $eval.evals[0].eval_metadata.controls.negative = @(1)
            $eval | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifest
            $result = Test-EvalSuites -Paths @($manifest)
            Assert-True (@($result.Warnings | Where-Object { $_ -match 'answer leakage' }).Count -eq 1) 'Prompt-answer overlap warning was not emitted.'
        }
        finally
        {
            Remove-Item -LiteralPath $fixture, $manifest -Force -ErrorAction SilentlyContinue
        }
    }

    Invoke-Test 'Reviewer generation covers every eval exactly once' {
        $document = Read-JsonDocument $configuration.ReviewerEvals
        $content = $expectedOutputs[$configuration.VallyOutputs['aspnetcore-pr-review']] +
            $expectedOutputs[$configuration.VallyOutputs['aspnetcore-pr-review-model-guardrail']]
        foreach ($eval in @($document.evals))
        {
            $marker = "name: `"eval-$(([int]$eval.id).ToString('00'))-"
            Assert-Equal 1 ([regex]::Matches($content, [regex]::Escape($marker))).Count "Reviewer eval $($eval.id) wiring mismatch."
        }
    }

    Invoke-Test 'Reviewer model guardrail is isolated' {
        $main = $expectedOutputs[$configuration.VallyOutputs['aspnetcore-pr-review']]
        $guardrail = $expectedOutputs[$configuration.VallyOutputs['aspnetcore-pr-review-model-guardrail']]
        Assert-True ($guardrail.Contains('model: claude-sonnet-5')) 'Guardrail did not use the Anthropic model.'
        Assert-True ($guardrail.Contains('threshold: 1.0')) 'Guardrail did not require a perfect prompt grade.'
        Assert-True (-not $main.Contains('orchestrator-model-guardrail')) 'Guardrail leaked into the GPT suite.'
    }

    Invoke-Test 'Artifact validator accepts bounded not-applicable artifacts' {
        $root = Join-Path ([IO.Path]::GetTempPath()) "review-artifacts-$([guid]::NewGuid())"
        try
        {
            New-ValidReviewArtifacts $root
            Assert-Equal 0 @(Test-ReviewArtifacts -Root $root).Count 'Valid artifact bundle was rejected.'
            Remove-Item -LiteralPath (Join-Path $root 'evidence/impact-map.md')
            Assert-True (@(Test-ReviewArtifacts -Root $root) -contains 'missing required artifact: evidence/impact-map.md') 'Missing impact map was not rejected.'
        }
        finally
        {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }
}

if ($Suite -in @('All', 'TryFix'))
{
    Invoke-Test 'Try-fix manifest validates independently' {
        $result = Test-EvalSuites -Paths @($configuration.TryFixEvals)
        Assert-Equal 0 $result.Errors.Count 'Try-fix validation failed.'
        Assert-True ($result.Records.Count -gt 0) 'Try-fix suite had no records.'
    }

    Invoke-Test 'Try-fix generation covers every eval exactly once' {
        $document = Read-JsonDocument $configuration.TryFixEvals
        $content = $expectedOutputs[$configuration.VallyOutputs['aspnetcore-try-fix']]
        foreach ($eval in @($document.evals))
        {
            $marker = "name: `"eval-$(([int]$eval.id).ToString('00'))-"
            Assert-Equal 1 ([regex]::Matches($content, [regex]::Escape($marker))).Count "Try-fix eval $($eval.id) wiring mismatch."
        }
    }

    Invoke-Test 'Try-fix suite pins model runs and objective grading' {
        $content = $expectedOutputs[$configuration.VallyOutputs['aspnetcore-try-fix']]
        Assert-True ($content.Contains("# Validated with $($configuration.VallyPackage).")) 'Try-fix CLI pin is missing.'
        Assert-True ($content.Contains('model: gpt-5.6-sol')) 'Try-fix executor model is not pinned.'
        Assert-True ($content.Contains('expected_runs: "5"')) 'Try-fix trial count is not tagged.'
        Assert-True ($content.Contains('type: prompt')) 'Try-fix objective prompt grader is missing.'
        Assert-True (-not $content.Contains('type: pairwise')) 'Obsolete pairwise grader is present.'
    }

    Invoke-Test 'Try-fix source snapshot is isolated and no-push' {
        $content = $expectedOutputs[$configuration.VallyOutputs['aspnetcore-try-fix']]
        Assert-True ($content.Contains('git init --quiet')) 'Independent Git snapshot is missing.'
        Assert-True ($content.Contains('no-push://dotnet/aspnetcore')) 'Push URL is not disabled.'
        Assert-True (-not $content.Contains('type: worktree')) 'Host worktree isolation was misrepresented.'
        Assert-True (-not $content.Contains('dest: ".github/skills')) 'Skill answer keys leaked into the source snapshot.'
        Assert-True ($content.Contains('eval-input/fixture-1.md')) 'Neutral fixture alias is missing.'
    }

    Invoke-Test 'Try-fix staged runtime includes conditional references only' {
        $root = Join-Path ([IO.Path]::GetTempPath()) "review-skills-$([guid]::NewGuid())"
        try
        {
            New-Item -ItemType Directory -Path $root | Out-Null
            $staged = Copy-SanitizedSkills -Destination (Join-Path $root 'staged')
            $tryFixRoot = Join-Path $staged 'aspnetcore-try-fix'
            foreach ($relativePath in $configuration.StagedSkillFiles['aspnetcore-try-fix'])
            {
                Assert-True (Test-Path -LiteralPath (Join-Path $tryFixRoot $relativePath) -PathType Leaf) "Missing staged try-fix runtime file $relativePath."
            }
            Assert-True (-not (Get-ChildItem -LiteralPath $tryFixRoot -Recurse -File | Where-Object Name -eq 'evals.json')) 'Try-fix answer manifest leaked into staged runtime.'
        }
        finally
        {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }

    Invoke-Test 'Skill staging rejects symbolic-link roots' {
        $root = Join-Path ([IO.Path]::GetTempPath()) "review-stage-link-$([guid]::NewGuid())"
        try
        {
            $target = Join-Path $root 'target'
            $link = Join-Path $root 'link'
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            New-Item -ItemType SymbolicLink -Path $link -Target $target | Out-Null
            $rejected = $false
            try { Copy-SanitizedSkills -Destination $link | Out-Null }
            catch { $rejected = $_.Exception.Message -match 'symbolic-link' }
            Assert-True $rejected 'Symbolic-link staging root was accepted.'
        }
        finally
        {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }
}

Invoke-Test 'Checked-in Vally specs match PowerShell generation' {
    Assert-Equal 0 @(Sync-VallyEvalSpecs -Check).Count 'Generated Vally specs are stale.'
}

Invoke-Test 'Every generated suite uses independent snapshot guardrails' {
    foreach ($content in $expectedOutputs.Values)
    {
        foreach ($path in $configuration.CommonSourcePaths)
        {
            Assert-True ($content.Contains($path)) "Generated suite omitted common source path $path."
        }
        foreach ($path in $configuration.SanitizedSourcePaths)
        {
            Assert-True ($content.Contains($path)) "Generated suite omitted sanitization path $path."
        }
        Assert-True ($content.Contains('git remote set-url --push origin no-push://dotnet/aspnetcore')) 'Generated suite allows push.'
        Assert-True (-not $content.Contains('type: pairwise')) 'Generated suite uses obsolete pairwise grader.'
    }
}

Invoke-Test 'Reviewer workflow contains no legacy interpreter dependency' {
    $roots = @(
        (Join-Path $configuration.RepoRoot '.github/skills/aspnetcore-pr-review')
        (Join-Path $configuration.RepoRoot '.github/skills/aspnetcore-try-fix')
        (Join-Path $configuration.RepoRoot 'eng/skill-evals/aspnetcore-pr-review')
        (Join-Path $configuration.RepoRoot 'eng/skill-evals/aspnetcore-try-fix')
    )
    $files = @($roots | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File })
    $legacyExtension = '.p' + 'y'
    $legacyCommand = '(?i)(?:^|[^a-z])' + 'pyt' + 'hon3?' + '(?:[^a-z]|$)|\.' + 'p' + 'y\b'
    Assert-Equal 0 @($files | Where-Object Extension -eq $legacyExtension).Count 'Legacy interpreter files remain in reviewer workflow.'
    foreach ($file in $files)
    {
        $content = Get-Content -LiteralPath $file.FullName -Raw
        Assert-True ($content -notmatch $legacyCommand) "Legacy interpreter invocation remains in $($file.FullName)."
    }
}

Invoke-Test 'Score aggregation preserves family macro weighting' {
    $document = [pscustomobject]@{
        evals = @(
            [pscustomobject]@{ id = 1; eval_metadata = [pscustomobject]@{ tier = 'train'; score_family = 'a'; provenance = [pscustomobject]@{ kind = 'synthetic'; source = 'x' } } }
            [pscustomobject]@{ id = 2; eval_metadata = [pscustomobject]@{ tier = 'train'; score_family = 'a'; provenance = [pscustomobject]@{ kind = 'synthetic'; source = 'x' } } }
            [pscustomobject]@{ id = 3; eval_metadata = [pscustomobject]@{ tier = 'train'; score_family = 'b'; provenance = [pscustomobject]@{ kind = 'synthetic'; source = 'y' } } }
            [pscustomobject]@{ id = 4; eval_metadata = [pscustomobject]@{ tier = 'held_out'; score_family = 'c'; provenance = [pscustomobject]@{ kind = 'synthetic'; source = 'z' } } }
        )
    }
    $aggregate = Get-EvalScoreAggregate -Document $document -Scores @{ '1' = 1.0; '2' = 1.0; '3' = 0.0; '4' = 0.5 }
    Assert-Equal 0 $aggregate.Errors.Count 'Aggregation failed.'
    Assert-Equal 0.5 $aggregate.Result.tiers.train.family_macro 'Duplicate family cases changed macro weight.'
}

if ($script:Failed.Count -gt 0)
{
    $script:Failed | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host "$script:Passed deterministic reviewer eval tests passed."
