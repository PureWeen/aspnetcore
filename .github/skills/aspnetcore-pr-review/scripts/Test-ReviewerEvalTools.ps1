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
    param(
        [string] $Root,

        [ValidateSet('bounded', 'full')]
        [string] $ReviewPath = 'bounded',

        [switch] $TargetedProven
    )

    $nonEmpty = @(
        'evidence/manifest.md', 'evidence/product-oracle.md', 'evidence/head-drift.md',
        'evidence/impact-map.md', 'candidates/candidate-a.md', 'candidates/candidate-b.md',
        'final/repository-oracle.md', 'final/review.md'
    )
    $existing = @('evidence/tracked.diff')
    if ($ReviewPath -eq 'bounded')
    {
        $nonEmpty += 'evidence/skipped-phases.md'
        if ($TargetedProven)
        {
            $nonEmpty += @('empirical/head.log', 'empirical/green.log', 'empirical/result.md')
        }
    }
    else
    {
        $nonEmpty += @(
            'candidates/candidate-c.md', 'candidates/candidate-d.md',
            'cross-examination/candidate-a.md', 'cross-examination/candidate-b.md',
            'cross-examination/candidate-c.md', 'cross-examination/candidate-d.md',
            'empirical/manifest.md', 'empirical/head.log', 'empirical/claim-matrix.md',
            'empirical/stress-matrix.md', 'empirical/result.md'
        )
        $existing += @(
            'empirical/before.diff', 'empirical/diagnostic.diff',
            'empirical/implementation.diff', 'empirical/red.log',
            'empirical/candidate.diff', 'empirical/green.log'
        )
    }
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

    $frozenHead = if ($TargetedProven) { 'behavioral-fail' } else { 'pass' }
    $findingProof = if ($TargetedProven) { 'empirical' } else { 'missing' }
    $scenarioProof = if ($TargetedProven) { 'empirical' } else { 'missing' }
    $candidateProof = if ($TargetedProven) { 'targeted-proven' } else { 'none' }
    $regression = if ($TargetedProven) { 'required-regression' } else { 'rejected' }
    $behavioralEvidence = if ($TargetedProven) { 'empirical' } else { 'missing' }

    @"
# Multi-Model Review
**Orchestrator:** gpt-test
**Path:** $ReviewPath
## Current fix
Current.
## Independent candidates
Candidates.
## Adversarial consensus
Consensus.
## Test assessment
Assessment.
## Proof status
**Frozen-head result:** $frozenHead
**Finding proof:** $findingProof
**Scenario proof:** $scenarioProof
**Candidate proof:** $candidateProof
**Product oracle:** documented
**Oracle fidelity:** authoritative
**Mechanism fidelity:** structural
**Scenario fidelity:** exact
**Regression assertion disposition:** $regression
**Diagnostic mutation disposition:** not-applicable
## Final recommendation
**Implementation verdict:** KEEP CURRENT FIX
**Behavioral evidence:** $behavioralEvidence
**Merge readiness:** recommendation only
**Implementation confidence:** medium
**Reason:** No material claim survived.
## Required follow-ups
None.
## Repository oracle gaps
None.
## Suggested review comments
None.
"@ | Set-Content -LiteralPath (Join-Path $Root 'final/review.md')
}

$configuration = Get-ReviewerEvalConfiguration
$expectedOutputs = [ordered]@{}
foreach ($path in $configuration.VallyOutputs.Values)
{
    $expectedOutputs[$path] = Get-Content -LiteralPath $path -Raw
}

if ($Suite -in @('All', 'Reviewer'))
{
    Invoke-Test 'Reviewer Vally specs validate independently' {
        $result = Test-EvalSuites -Paths $configuration.ReviewerEvals
        Assert-Equal 0 $result.Errors.Count 'Reviewer validation failed.'
        Assert-True ($result.Records.Count -gt 0) 'Reviewer suite had no records.'
    }

    Invoke-Test 'Reviewer validator warns on prompt-answer overlap' {
        $fixture = Join-Path ([IO.Path]::GetTempPath()) "eval-overlap-$([guid]::NewGuid()).md"
        $spec = Join-Path ([IO.Path]::GetTempPath()) "eval-overlap-$([guid]::NewGuid()).vally.yaml"
        try
        {
            Set-Content -LiteralPath $fixture -Value 'fixture'
            @"
name: test
defaults:
  runs: 5
  model: gpt-5.6-sol
stimuli:
  - name: "eval-01-overlap-check"
    prompt: |-
      alpha-bravo charlie-delta echo-foxtrot
    tags:
      eval_id: "1"
      skill_name: "test"
      mechanism: "overlap-check"
      executor_model: "gpt-5.6-sol"
      expected_runs: "5"
      area: "Testing"
      score_family: "overlap"
      tier: "train"
      provenance_kind: "synthetic"
      provenance_source: "overlap"
      discovery_mode: "discovery"
      controls_positive: "0"
      controls_negative: "1"
      forbidden_prompt_terms: "[\"not-present\"]"
    environment:
      files:
        - src: "$fixture"
          dest: "eval-input/fixture-1.md"
    rubric:
      - "Overall response matches this expected outcome: bounded"
      - "alpha-bravo charlie-delta echo-foxtrot"
      - "unrelated negative"
"@ | Set-Content -LiteralPath $spec
            $result = Test-EvalSuites -Paths @($spec)
            Assert-Equal 0 $result.Errors.Count 'Synthetic overlap suite failed validation.'
            Assert-True (@($result.Warnings | Where-Object { $_ -match 'answer leakage' }).Count -eq 1) 'Prompt-answer overlap warning was not emitted.'
        }
        finally
        {
            Remove-Item -LiteralPath $fixture, $spec -Force -ErrorAction SilentlyContinue
        }
    }

    Invoke-Test 'Reviewer specs cover every eval exactly once' {
        $documents = @($configuration.ReviewerEvals | ForEach-Object { Read-VallyEvalDocument $_ })
        $content = $expectedOutputs[$configuration.VallyOutputs['aspnetcore-pr-review']] +
            $expectedOutputs[$configuration.VallyOutputs['aspnetcore-pr-review-model-guardrail']]
        foreach ($eval in @($documents.evals))
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

    Invoke-Test 'Bounded artifact schema accepts a minimal bundle' {
        $root = Join-Path ([IO.Path]::GetTempPath()) "review-artifacts-$([guid]::NewGuid())"
        try
        {
            New-ValidReviewArtifacts -Root $root -ReviewPath bounded
            Assert-Equal 0 @(Test-ReviewArtifacts -Root $root).Count 'Valid artifact bundle was rejected.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'candidates/candidate-c.md'))) 'Bounded bundle created candidate C boilerplate.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'cross-examination'))) 'Bounded bundle created cross-examination boilerplate.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'empirical'))) 'Bounded bundle created empirical boilerplate.'
        }
        finally
        {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }

    Invoke-Test 'Bounded artifact schema requires candidates A and B' {
        foreach ($candidate in @('candidate-a.md', 'candidate-b.md'))
        {
            $root = Join-Path ([IO.Path]::GetTempPath()) "review-artifacts-$([guid]::NewGuid())"
            try
            {
                New-ValidReviewArtifacts -Root $root -ReviewPath bounded
                Remove-Item -LiteralPath (Join-Path $root "candidates/$candidate")
                $errors = @(Test-ReviewArtifacts -Root $root)
                Assert-True ($errors -contains "missing required artifact: candidates/$candidate") "Missing $candidate was not rejected."
            }
            finally
            {
                if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
            }
        }
    }

    Invoke-Test 'Bounded targeted proof requires red and green evidence' {
        foreach ($artifact in @('empirical/head.log', 'empirical/green.log'))
        {
            $root = Join-Path ([IO.Path]::GetTempPath()) "review-artifacts-$([guid]::NewGuid())"
            try
            {
                New-ValidReviewArtifacts -Root $root -ReviewPath bounded -TargetedProven
                Assert-Equal 0 @(Test-ReviewArtifacts -Root $root).Count 'Valid bounded targeted proof was rejected.'
                Remove-Item -LiteralPath (Join-Path $root $artifact)
                $errors = @(Test-ReviewArtifacts -Root $root)
                Assert-True ($errors -contains "bounded targeted-proven missing required artifact: $artifact") "Missing $artifact was not rejected."
            }
            finally
            {
                if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
            }
        }
    }

    Invoke-Test 'Full artifact schema retains the complete contract' {
        $root = Join-Path ([IO.Path]::GetTempPath()) "review-artifacts-$([guid]::NewGuid())"
        try
        {
            New-ValidReviewArtifacts -Root $root -ReviewPath full
            Assert-Equal 0 @(Test-ReviewArtifacts -Root $root).Count 'Valid full artifact bundle was rejected.'
            foreach ($artifact in @('candidates/candidate-c.md', 'cross-examination/candidate-d.md', 'empirical/manifest.md'))
            {
                Remove-Item -LiteralPath (Join-Path $root $artifact)
            }
            $errors = @(Test-ReviewArtifacts -Root $root)
            Assert-True ($errors -contains 'missing required artifact: candidates/candidate-c.md') 'Full path accepted missing candidate C.'
            Assert-True ($errors -contains 'missing required artifact: cross-examination/candidate-d.md') 'Full path accepted missing cross-examination.'
            Assert-True ($errors -contains 'missing required artifact: empirical/manifest.md') 'Full path accepted missing empirical contract.'

            $reviewPath = Join-Path $root 'final/review.md'
            $review = Get-Content -LiteralPath $reviewPath -Raw
            $review = $review.Replace('**Frozen-head result:** pass', '**Frozen-head result:** behavioral-fail')
            $review = $review.Replace('**Finding proof:** missing', '**Finding proof:** empirical')
            $review = $review.Replace('**Scenario proof:** missing', '**Scenario proof:** empirical')
            $review = $review.Replace('**Candidate proof:** none', '**Candidate proof:** production-proven')
            $review = $review.Replace('**Regression assertion disposition:** rejected', '**Regression assertion disposition:** required-regression')
            $review = $review.Replace('**Behavioral evidence:** missing', '**Behavioral evidence:** empirical')
            Set-Content -LiteralPath $reviewPath -Value $review
            Remove-Item -LiteralPath (Join-Path $root 'empirical/stress-matrix.md')
            $productionErrors = @(Test-ReviewArtifacts -Root $root)
            Assert-True ($productionErrors -contains 'missing required artifact: empirical/stress-matrix.md') 'Full production proof did not report a missing stress matrix.'
        }
        finally
        {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }

    Invoke-Test 'Artifact path and proof labels must be consistent' {
        $root = Join-Path ([IO.Path]::GetTempPath()) "review-artifacts-$([guid]::NewGuid())"
        try
        {
            New-ValidReviewArtifacts -Root $root -ReviewPath bounded -TargetedProven
            $reviewPath = Join-Path $root 'final/review.md'
            (Get-Content -LiteralPath $reviewPath -Raw).Replace(
                '**Candidate proof:** targeted-proven',
                '**Candidate proof:** production-proven'
            ) | Set-Content -LiteralPath $reviewPath
            $errors = @(Test-ReviewArtifacts -Root $root)
            Assert-True ($errors -contains 'production-proven candidate proof requires the full review path') 'Bounded path accepted production-proven.'
        }
        finally
        {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }
}

if ($Suite -in @('All', 'TryFix'))
{
    Invoke-Test 'Try-fix Vally spec validates independently' {
        $result = Test-EvalSuites -Paths $configuration.TryFixEvals
        Assert-Equal 0 $result.Errors.Count 'Try-fix validation failed.'
        Assert-True ($result.Records.Count -gt 0) 'Try-fix suite had no records.'
    }

    Invoke-Test 'Try-fix spec covers every eval exactly once' {
        $document = Read-VallyEvalDocument $configuration.TryFixEvals[0]
        $content = $expectedOutputs[$configuration.VallyOutputs['aspnetcore-try-fix']]
        foreach ($eval in @($document.evals))
        {
            $marker = "name: `"eval-$(([int]$eval.id).ToString('00'))-"
            Assert-Equal 1 ([regex]::Matches($content, [regex]::Escape($marker))).Count "Try-fix eval $($eval.id) wiring mismatch."
        }
    }

    Invoke-Test 'Try-fix stimuli explicitly route to try-fix' {
        $document = Read-VallyEvalDocument $configuration.TryFixEvals[0]
        $content = $expectedOutputs[$configuration.VallyOutputs['aspnetcore-try-fix']]
        $marker = 'Invoke the aspnetcore-try-fix skill for this task.'
        Assert-Equal @($document.evals).Count ([regex]::Matches($content, [regex]::Escape($marker))).Count 'Try-fix stimuli are not routed explicitly.'
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
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $tryFixRoot 'evals'))) 'Try-fix eval assets leaked into staged runtime.'
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

    Invoke-Test 'Skill staging rejects repository-contained roots' {
        $destination = Join-Path $configuration.RepoRoot ".github/skills/reviewer-stage-test-$([guid]::NewGuid())"
        try
        {
            $rejected = $false
            try { Copy-SanitizedSkills -Destination $destination | Out-Null }
            catch { $rejected = $_.Exception.Message -match 'unsafe staging root' }
            Assert-True $rejected "Repository-contained staging root was accepted: $destination"
        }
        finally
        {
            if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
        }
    }

    Invoke-Test 'Skill staging rejects case-variant repository paths' {
        if ([OperatingSystem]::IsWindows() -or [OperatingSystem]::IsMacOS())
        {
            $variantRoot = if ([OperatingSystem]::IsWindows())
            {
                $configuration.RepoRoot.ToUpperInvariant()
            }
            else
            {
                $configuration.RepoRoot -replace '^/Users/', '/users/'
            }
            Assert-True ($variantRoot -cne $configuration.RepoRoot) 'Test did not create a case-variant repository path.'
            $relativeDestination = ".github/skills/reviewer-stage-test-$([guid]::NewGuid())"
            $destination = Join-Path $variantRoot $relativeDestination
            try
            {
                $rejected = $false
                try { Copy-SanitizedSkills -Destination $destination | Out-Null }
                catch { $rejected = $_.Exception.Message -match 'unsafe staging root' }
                Assert-True $rejected 'Case-variant repository staging root was accepted.'
            }
            finally
            {
                $canonicalDestination = Join-Path $configuration.RepoRoot $relativeDestination
                if (Test-Path -LiteralPath $canonicalDestination) { Remove-Item -LiteralPath $canonicalDestination -Recurse -Force }
            }
        }
    }

    Invoke-Test 'Skill staging resolves symbolic-link ancestors' {
        $root = Join-Path ([IO.Path]::GetTempPath()) "review-stage-ancestor-$([guid]::NewGuid())"
        try
        {
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $repoAlias = Join-Path $root 'repo-alias'
            New-Item -ItemType SymbolicLink -Path $repoAlias -Target $configuration.RepoRoot | Out-Null
            $link = Join-Path $root 'skills-link'
            New-Item -ItemType SymbolicLink -Path $link -Target (Join-Path $repoAlias '.github/skills') | Out-Null
            $relativeDestination = ".github/skills/reviewer-stage-test-$([guid]::NewGuid())"
            $destination = Join-Path $link (Split-Path -Leaf $relativeDestination)
            try
            {
                $rejected = $false
                try { Copy-SanitizedSkills -Destination $destination | Out-Null }
                catch { $rejected = $_.Exception.Message -match 'unsafe staging root' }
                Assert-True $rejected 'Repository staging through a symbolic-link ancestor was accepted.'
            }
            finally
            {
                $canonicalDestination = Join-Path $configuration.RepoRoot $relativeDestination
                if (Test-Path -LiteralPath $canonicalDestination) { Remove-Item -LiteralPath $canonicalDestination -Recurse -Force }
            }
        }
        finally
        {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }

    Invoke-Test 'Skill staging preflights every replacement before deletion' {
        $root = Join-Path ([IO.Path]::GetTempPath()) "review-stage-preflight-$([guid]::NewGuid())"
        try
        {
            $stage = Join-Path $root 'stage'
            $reviewer = Join-Path $stage 'aspnetcore-pr-review'
            $target = Join-Path $root 'target'
            New-Item -ItemType Directory -Path $reviewer -Force | Out-Null
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $reviewer 'sentinel.txt') -Value 'preserve'
            New-Item -ItemType SymbolicLink -Path (Join-Path $stage 'aspnetcore-try-fix') -Target $target | Out-Null

            $rejected = $false
            try { Copy-SanitizedSkills -Destination $stage | Out-Null }
            catch { $rejected = $_.Exception.Message -match 'symbolic-link skill destination' }
            Assert-True $rejected 'Symbolic-link skill destination was accepted.'
            Assert-True (Test-Path -LiteralPath (Join-Path $reviewer 'sentinel.txt') -PathType Leaf) 'A prior skill was deleted before staging preflight completed.'
        }
        finally
        {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }

    Invoke-Test 'Skill staging safely replaces regular-file occupants' {
        $root = Join-Path ([IO.Path]::GetTempPath()) "review-stage-file-$([guid]::NewGuid())"
        try
        {
            $stage = Join-Path $root 'stage'
            New-Item -ItemType Directory -Path $stage -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $stage 'aspnetcore-pr-review') -Value 'stale'
            $staged = Copy-SanitizedSkills -Destination $stage
            Assert-True (Test-Path -LiteralPath (Join-Path $staged 'aspnetcore-pr-review/SKILL.md') -PathType Leaf) 'Regular-file occupant was not safely replaced.'
            Assert-True (Test-Path -LiteralPath (Join-Path $staged 'aspnetcore-try-fix/SKILL.md') -PathType Leaf) 'Staging did not complete after replacing a regular file.'
        }
        finally
        {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }

    Invoke-Test 'Path containment honors directory boundaries' {
        $pathRoot = [IO.Path]::GetPathRoot($configuration.RepoRoot)
        Assert-True (Test-PathContainedBy -Path $configuration.RepoRoot -Root $pathRoot) 'Filesystem-root containment was not recognized.'
        Assert-True (Test-PathContainedBy -Path $configuration.RepoRoot -Root $configuration.RepoRoot -AllowEqual) 'Repository root equality was not recognized.'
        Assert-True (Test-PathContainedBy -Path (Join-Path $configuration.RepoRoot 'child') -Root $configuration.RepoRoot) 'Repository child was not recognized.'
        Assert-True (-not (Test-PathContainedBy -Path "$($configuration.RepoRoot)-sibling" -Root $configuration.RepoRoot)) 'Sibling prefix was treated as a repository child.'
    }
}

Invoke-Test 'Every canonical suite uses independent snapshot guardrails' {
    foreach ($content in $expectedOutputs.Values)
    {
        foreach ($path in $configuration.CommonSourcePaths)
        {
            Assert-True ($content.Contains($path)) "Canonical suite omitted common source path $path."
        }
        foreach ($path in $configuration.SanitizedSourcePaths)
        {
            Assert-True ($content.Contains($path)) "Canonical suite omitted sanitization path $path."
        }
        Assert-True ($content.Contains('git remote set-url --push origin no-push://dotnet/aspnetcore')) 'Canonical suite allows push.'
        Assert-True (-not $content.Contains('type: pairwise')) 'Canonical suite uses obsolete pairwise grader.'
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

Invoke-Test 'Score aggregation combines split canonical specs' {
    $scoresPath = Join-Path ([IO.Path]::GetTempPath()) "review-scores-$([guid]::NewGuid()).json"
    try
    {
        $allEvalPaths = @($configuration.ReviewerEvals) + @($configuration.TryFixEvals)
        $scores = [ordered]@{}
        foreach ($path in $allEvalPaths)
        {
            $document = Read-VallyEvalDocument $path
            if (-not $scores.Contains($document.skill_name))
            {
                $scores[$document.skill_name] = [ordered]@{}
            }
            foreach ($eval in @($document.evals))
            {
                $scores[$document.skill_name][[string]$eval.id] = 1.0
            }
        }
        $scores | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $scoresPath

        $aggregateScript = Join-Path $PSScriptRoot 'Aggregate-EvalScores.ps1'
        $output = @(& pwsh -NoProfile -File $aggregateScript `
            -EvalPath ($allEvalPaths -join ',') `
            -Scores $scoresPath 2>&1)
        Assert-Equal 0 $LASTEXITCODE "Split-spec aggregation failed: $($output -join [Environment]::NewLine)"
        $aggregate = ($output -join [Environment]::NewLine) | ConvertFrom-Json
        Assert-Equal 17 ($aggregate.'aspnetcore-pr-review'.tiers.train.eval_count + $aggregate.'aspnetcore-pr-review'.tiers.held_out.eval_count) 'Reviewer guardrail spec was not merged with the main suite.'
        Assert-Equal 12 ($aggregate.'aspnetcore-try-fix'.tiers.train.eval_count + $aggregate.'aspnetcore-try-fix'.tiers.held_out.eval_count) 'Try-fix suite aggregation changed its eval count.'
    }
    finally
    {
        Remove-Item -LiteralPath $scoresPath -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'Documented multi-input commands bind every argument' {
    $root = Join-Path ([IO.Path]::GetTempPath()) "review-cli-$([guid]::NewGuid())"
    try
    {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $validateScript = Join-Path $PSScriptRoot 'Validate-Evals.ps1'
        $allEvalPaths = @($configuration.ReviewerEvals) + @($configuration.TryFixEvals)
        $validationOutput = @(& pwsh -NoProfile -File $validateScript -Path ($allEvalPaths -join ',') 2>&1)
        Assert-Equal 0 $LASTEXITCODE "Documented validation command failed: $($validationOutput -join [Environment]::NewLine)"
        $validation = ($validationOutput -join [Environment]::NewLine) | ConvertFrom-Json
        $expectedCount = @($allEvalPaths | ForEach-Object { (Read-VallyEvalDocument $_).evals }).Count
        Assert-Equal $expectedCount $validation.raw_count 'Documented validation command did not process every Vally spec.'

        $specs = [Collections.Generic.List[string]]::new()
        $results = [Collections.Generic.List[string]]::new()
        foreach ($skill in @('cli-reviewer', 'cli-try-fix'))
        {
            $specPath = Join-Path $root "$skill.vally.yaml"
            $resultPath = Join-Path $root "$skill.jsonl"
            @"
name: $skill
stimuli:
  - name: "eval-01-cli"
    prompt: |-
      Exercise the CLI aggregation path.
    tags:
      eval_id: "1"
      tier: "train"
      score_family: "cli"
      provenance_kind: "synthetic"
      provenance_source: "$skill"
    rubric:
      - "Overall response matches this expected outcome: success"
"@ | Set-Content -LiteralPath $specPath

            $records = for ($run = 1; $run -le 5; $run++)
            {
                @{
                    type = 'trial'
                    status = 'success'
                    gradeResult = @{ stimulusName = 'eval-01-cli'; score = 1.0 }
                    trajectory = @{
                        id = "$skill-$run"
                        stimulus = @{
                            name = 'eval-01-cli'
                            tags = @{
                                skill_name = $skill
                                expected_runs = '5'
                                executor_model = 'gpt-5.6-sol'
                            }
                        }
                        metadata = @{
                            model = 'gpt-5.6-sol'
                            skillsLoaded = @($skill)
                        }
                    }
                } | ConvertTo-Json -Depth 10 -Compress
            }
            Set-Content -LiteralPath $resultPath -Value $records
            $specs.Add($specPath)
            $results.Add("$skill=$resultPath")
        }

        $aggregateScript = Join-Path $PSScriptRoot 'Aggregate-EvalScores.ps1'
        $aggregateOutput = @(& pwsh -NoProfile -File $aggregateScript `
            -EvalPath ($specs -join ',') `
            -VallyResults ($results -join ',') 2>&1)
        Assert-Equal 0 $LASTEXITCODE "Documented aggregation command failed: $($aggregateOutput -join [Environment]::NewLine)"
        $aggregate = ($aggregateOutput -join [Environment]::NewLine) | ConvertFrom-Json
        Assert-Equal 1.0 $aggregate.'cli-reviewer'.raw_mean 'Reviewer Vally result mapping was not processed.'
        Assert-Equal 1.0 $aggregate.'cli-try-fix'.raw_mean 'Try-fix Vally result mapping was not processed.'

        $invalidOutput = @(& pwsh -NoProfile -File $aggregateScript -EvalPath ',,' -VallyResults ',,' 2>&1)
        Assert-True ($LASTEXITCODE -ne 0) 'Degenerate aggregation inputs returned success.'
        Assert-True (($invalidOutput -join [Environment]::NewLine) -match 'at least one eval path is required') 'Degenerate aggregation failure was not explicit.'
    }
    finally
    {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

if ($script:Failed.Count -gt 0)
{
    $script:Failed | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host "$script:Passed deterministic reviewer eval tests passed."
