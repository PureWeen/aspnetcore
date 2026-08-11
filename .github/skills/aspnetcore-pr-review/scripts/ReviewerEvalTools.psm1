Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
$script:ReviewerEvals = Join-Path $script:RepoRoot '.github/skills/aspnetcore-pr-review/evals/evals.json'
$script:TryFixEvals = Join-Path $script:RepoRoot '.github/skills/aspnetcore-try-fix/evals/evals.json'
$script:VallyPackage = '@microsoft/vally-cli@0.13.0'
$script:ModelGuardrailMechanism = 'orchestrator-model-guardrail'
$script:SanitizedSourcePaths = @(
    'eng/skill-evals/aspnetcore-pr-review'
    'eng/skill-evals/aspnetcore-try-fix'
)
$script:CommonSourcePaths = @(
    '.github/instructions'
    'eng/common/AGENTS.md'
    '.editorconfig'
    '.gitignore'
    '.globalconfig'
    'Directory.Build.props'
    'Directory.Build.targets'
    'global.json'
)
$script:VallyOutputs = [ordered]@{
    'aspnetcore-pr-review' = Join-Path $script:RepoRoot 'eng/skill-evals/aspnetcore-pr-review/regression.vally.yaml'
    'aspnetcore-pr-review-model-guardrail' = Join-Path $script:RepoRoot 'eng/skill-evals/aspnetcore-pr-review/model-guardrail.vally.yaml'
    'aspnetcore-try-fix' = Join-Path $script:RepoRoot 'eng/skill-evals/aspnetcore-try-fix/regression.vally.yaml'
}
$script:StagedSkillFiles = [ordered]@{
    'aspnetcore-pr-review' = @(
        'SKILL.md'
        'references/evidence-and-orchestration.md'
        'references/empirical-proof.md'
        'references/output-contract.md'
        'references/proof-calibration.md'
        'scripts/Validate-ReviewArtifacts.ps1'
        'scripts/ReviewerEvalTools.psm1'
    )
    'aspnetcore-try-fix' = @(
        'SKILL.md'
        'references/candidate-protocol.md'
        'references/empirical-protocol.md'
        'references/output-contract.md'
    )
}

function Get-ReviewerEvalConfiguration
{
    [CmdletBinding()]
    param()

    return @{
        RepoRoot = $script:RepoRoot
        ReviewerEvals = $script:ReviewerEvals
        TryFixEvals = $script:TryFixEvals
        VallyPackage = $script:VallyPackage
        ModelGuardrailMechanism = $script:ModelGuardrailMechanism
        SanitizedSourcePaths = $script:SanitizedSourcePaths
        CommonSourcePaths = $script:CommonSourcePaths
        VallyOutputs = $script:VallyOutputs
        StagedSkillFiles = $script:StagedSkillFiles
    }
}

function Read-JsonDocument
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
}

function ConvertTo-CanonicalJson
{
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        [AllowNull()]
        $InputObject
    )

    process
    {
        if ($null -eq $InputObject)
        {
            return 'null'
        }

        if ($InputObject -is [string])
        {
            return ConvertTo-Json -InputObject $InputObject -Compress
        }

        if ($InputObject -is [bool])
        {
            return $InputObject.ToString().ToLowerInvariant()
        }

        if ($InputObject -is [System.Collections.IDictionary])
        {
            $properties = foreach ($key in @($InputObject.Keys) | Sort-Object)
            {
                "$(ConvertTo-CanonicalJson ([string]$key)):$(ConvertTo-CanonicalJson $InputObject[$key])"
            }

            return "{$($properties -join ',')}"
        }

        if ($InputObject -is [pscustomobject])
        {
            $properties = [ordered]@{}
            foreach ($property in $InputObject.PSObject.Properties)
            {
                $properties[$property.Name] = $property.Value
            }

            return ConvertTo-CanonicalJson $properties
        }

        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string])
        {
            $items = foreach ($item in $InputObject)
            {
                ConvertTo-CanonicalJson $item
            }

            return "[$($items -join ',')]"
        }

        if ($InputObject -is [double] -or $InputObject -is [single] -or $InputObject -is [decimal])
        {
            return $InputObject.ToString('G', [Globalization.CultureInfo]::InvariantCulture)
        }

        return [Convert]::ToString($InputObject, [Globalization.CultureInfo]::InvariantCulture)
    }
}

function Get-Sha256
{
    [CmdletBinding(DefaultParameterSetName = 'Text')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Text')]
        [string] $Text,

        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [string] $Path
    )

    $sha = [Security.Cryptography.SHA256]::Create()
    try
    {
        if ($PSCmdlet.ParameterSetName -eq 'Path')
        {
            $stream = [IO.File]::OpenRead((Resolve-Path -LiteralPath $Path))
            try
            {
                $hash = $sha.ComputeHash($stream)
            }
            finally
            {
                $stream.Dispose()
            }
        }
        else
        {
            $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
        }

        return [Convert]::ToHexString($hash).ToLowerInvariant()
    }
    finally
    {
        $sha.Dispose()
    }
}

function Get-HeldOutHash
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Eval
    )

    $copy = $Eval | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
    if ($null -ne $copy.eval_metadata.PSObject.Properties['frozen_hash'])
    {
        $copy.eval_metadata.PSObject.Properties.Remove('frozen_hash')
    }

    return Get-Sha256 -Text (ConvertTo-CanonicalJson $copy)
}

function Resolve-EvalFixture
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $EvalPath,

        [Parameter(Mandatory)]
        [string] $Fixture
    )

    if ([IO.Path]::IsPathRooted($Fixture) -and (Test-Path -LiteralPath $Fixture -PathType Leaf))
    {
        return (Resolve-Path -LiteralPath $Fixture).Path
    }

    $directory = Split-Path -Parent (Resolve-Path -LiteralPath $EvalPath)
    while (-not [string]::IsNullOrEmpty($directory))
    {
        $candidate = Join-Path $directory $Fixture
        if (Test-Path -LiteralPath $candidate -PathType Leaf)
        {
            return (Resolve-Path -LiteralPath $candidate).Path
        }

        $parent = Split-Path -Parent $directory
        if ($parent -eq $directory)
        {
            break
        }

        $directory = $parent
    }

    return $null
}

function Test-NonEmptyString
{
    param($Value)

    return $Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value)
}

function Test-KebabCase
{
    param($Value)

    return (Test-NonEmptyString $Value) -and $Value -match '^[a-z0-9]+(?:-[a-z0-9]+)*$'
}

function Test-Integer
{
    param($Value)

    return $Value -is [sbyte] -or $Value -is [byte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]
}

function Get-PropertyValue
{
    param(
        $Object,
        [string] $Name
    )

    if ($null -eq $Object)
    {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property)
    {
        return $null
    }

    return $property.Value
}

function Get-PromptExpectationOverlap
{
    param(
        [string] $Prompt,
        [object[]] $Expectations
    )

    $promptTokens = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $expectationTokens = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($match in [regex]::Matches($Prompt.ToLowerInvariant(), '[a-z0-9][a-z0-9_-]{3,}'))
    {
        $promptTokens.Add($match.Value) | Out-Null
    }
    foreach ($match in [regex]::Matches((($Expectations -join ' ').ToLowerInvariant()), '[a-z0-9][a-z0-9_-]{3,}'))
    {
        $expectationTokens.Add($match.Value) | Out-Null
    }
    if ($promptTokens.Count -eq 0 -or $expectationTokens.Count -eq 0)
    {
        return 0.0
    }

    $intersection = 0
    foreach ($token in $expectationTokens)
    {
        if ($promptTokens.Contains($token)) { $intersection++ }
    }
    return $intersection / $expectationTokens.Count
}

function Test-EvalSuites
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Paths
    )

    $errors = [Collections.Generic.List[string]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    $records = [Collections.Generic.List[object]]::new()

    foreach ($path in $Paths)
    {
        try
        {
            $document = Read-JsonDocument $path
        }
        catch
        {
            $errors.Add("$path`: unable to read evals: $($_.Exception.Message)")
            continue
        }

        $evals = @(Get-PropertyValue $document 'evals')
        if ($evals.Count -eq 0)
        {
            $errors.Add("$path.evals must be a nonempty array")
            continue
        }

        $duplicateIds = @($evals | Group-Object id | Where-Object Count -gt 1 | ForEach-Object Name)
        if ($duplicateIds.Count -gt 0)
        {
            $errors.Add("$path.evals contains duplicate ids: $($duplicateIds -join ', ')")
        }

        for ($index = 0; $index -lt $evals.Count; $index++)
        {
            $eval = $evals[$index]
            $name = "$path`: evals[$index]"
            $id = Get-PropertyValue $eval 'id'
            $prompt = Get-PropertyValue $eval 'prompt'
            $files = @(Get-PropertyValue $eval 'files')
            $expectations = @(Get-PropertyValue $eval 'expectations')
            $metadata = Get-PropertyValue $eval 'eval_metadata'

            if (-not (Test-Integer $id) -or $id -le 0)
            {
                $errors.Add("$name.id must be a positive integer")
            }
            if (-not (Test-NonEmptyString $prompt))
            {
                $errors.Add("$name.prompt must be a nonempty string")
            }
            if ($expectations.Count -eq 0 -or @($expectations | Where-Object { -not (Test-NonEmptyString $_) }).Count -gt 0)
            {
                $errors.Add("$name.expectations must be a nonempty array of strings")
            }
            if (@($files | Where-Object { -not (Test-NonEmptyString $_) }).Count -gt 0)
            {
                $errors.Add("$name.files must contain only nonempty strings")
            }
            foreach ($fixture in $files)
            {
                if ($null -eq (Resolve-EvalFixture -EvalPath $path -Fixture $fixture))
                {
                    $errors.Add("$name.files fixture does not exist: $fixture")
                }
            }
            if ($null -eq $metadata)
            {
                $errors.Add("$name.eval_metadata must be an object")
                continue
            }

            $mechanism = Get-PropertyValue $metadata 'mechanism'
            $area = Get-PropertyValue $metadata 'area'
            $family = Get-PropertyValue $metadata 'score_family'
            $tier = Get-PropertyValue $metadata 'tier'
            $discoveryMode = Get-PropertyValue $metadata 'discovery_mode'
            $provenance = Get-PropertyValue $metadata 'provenance'
            $controls = Get-PropertyValue $metadata 'controls'
            $forbiddenTerms = @(Get-PropertyValue $metadata 'forbidden_prompt_terms')
            $sourcePaths = @((Get-PropertyValue $metadata 'source_paths') | Where-Object { $null -ne $_ })

            if (-not (Test-KebabCase $mechanism))
            {
                $errors.Add("$name.eval_metadata.mechanism must be nonempty kebab-case")
            }
            if (-not (Test-NonEmptyString $area))
            {
                $errors.Add("$name.eval_metadata.area must be a nonempty string")
            }
            if (-not (Test-KebabCase $family))
            {
                $errors.Add("$name.eval_metadata.score_family must be nonempty kebab-case")
            }
            if ($tier -notin @('train', 'held_out'))
            {
                $errors.Add("$name.eval_metadata.tier must be train or held_out")
            }
            if ($discoveryMode -notin @('discovery', 'verification'))
            {
                $errors.Add("$name.eval_metadata.discovery_mode must be discovery or verification")
            }
            foreach ($sourcePath in $sourcePaths)
            {
                if (-not (Test-NonEmptyString $sourcePath))
                {
                    $errors.Add("$name.eval_metadata.source_paths must contain only nonempty strings")
                }
                elseif (-not (Test-Path -LiteralPath (Join-Path $script:RepoRoot $sourcePath)))
                {
                    $errors.Add("$name.eval_metadata.source_paths entry does not exist: $sourcePath")
                }
            }

            $provenanceKind = Get-PropertyValue $provenance 'kind'
            $provenanceSource = Get-PropertyValue $provenance 'source'
            if ($provenanceKind -notin @('pr', 'historical', 'synthetic'))
            {
                $errors.Add("$name.eval_metadata.provenance.kind must be pr, historical, or synthetic")
            }
            if (-not (Test-NonEmptyString $provenanceSource))
            {
                $errors.Add("$name.eval_metadata.provenance.source must be a nonempty string")
            }

            $positive = @(Get-PropertyValue $controls 'positive')
            $negative = @(Get-PropertyValue $controls 'negative')
            foreach ($control in @(@{ Name = 'positive'; Values = $positive }, @{ Name = 'negative'; Values = $negative }))
            {
                if ($control.Values.Count -eq 0 -or @($control.Values | Where-Object { -not (Test-Integer $_) }).Count -gt 0)
                {
                    $errors.Add("$name.eval_metadata.controls.$($control.Name) must be a nonempty integer array")
                    continue
                }
                if (@($control.Values | Sort-Object -Unique).Count -ne $control.Values.Count)
                {
                    $errors.Add("$name.eval_metadata.controls.$($control.Name) must not repeat indexes")
                }
                foreach ($value in $control.Values)
                {
                    if ($value -lt 0 -or $value -ge $expectations.Count)
                    {
                        $errors.Add("$name.eval_metadata.controls.$($control.Name) index $value must reference expectations")
                    }
                }
            }
            if (@($positive | Where-Object { $_ -in $negative }).Count -gt 0)
            {
                $errors.Add("$name.eval_metadata.controls positive and negative must be disjoint")
            }

            if (@($forbiddenTerms | Where-Object { -not (Test-NonEmptyString $_) }).Count -gt 0)
            {
                $errors.Add("$name.eval_metadata.forbidden_prompt_terms must contain only nonempty strings")
            }
            if ($discoveryMode -eq 'discovery' -and $forbiddenTerms.Count -eq 0)
            {
                $errors.Add("$name.eval_metadata.forbidden_prompt_terms must be nonempty for discovery")
            }
            if ($discoveryMode -eq 'discovery')
            {
                if ($files.Count -eq 0)
                {
                    $errors.Add("$name.files must provide a discovery fixture")
                }
                if ($prompt -match '(?i)(?:\b(?:pull request|pr|issue)\s*#?\d+|#\d{3,})' -or $prompt -match '(?i)\b(?=[0-9a-f]{7,40}\b)(?=[0-9a-f]*\d)[0-9a-f]{7,40}\b')
                {
                    $errors.Add("$name.prompt must not expose issue, pull request, or commit identities in discovery mode")
                }
            }
            foreach ($term in $forbiddenTerms)
            {
                if ($prompt.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0)
                {
                    $errors.Add("$name.eval_metadata.forbidden_prompt_terms contains prompt term: '$term'")
                }
            }

            if ($tier -eq 'held_out')
            {
                $fixtureHashes = Get-PropertyValue $metadata 'fixture_hashes'
                foreach ($fixture in $files)
                {
                    $expectedHash = Get-PropertyValue $fixtureHashes $fixture
                    if ($expectedHash -notmatch '^[0-9a-f]{64}$')
                    {
                        $errors.Add("$name.eval_metadata.fixture_hashes['$fixture'] must be a lowercase SHA-256")
                        continue
                    }
                    $fixturePath = Resolve-EvalFixture -EvalPath $path -Fixture $fixture
                    if ($null -ne $fixturePath -and (Get-Sha256 -Path $fixturePath) -ne $expectedHash)
                    {
                        $errors.Add("$name.eval_metadata.fixture_hashes['$fixture'] does not match the fixture")
                    }
                }

                $frozenHash = Get-PropertyValue $metadata 'frozen_hash'
                if ($frozenHash -notmatch '^[0-9a-f]{64}$' -or $frozenHash -ne (Get-HeldOutHash $eval))
                {
                    $errors.Add("$name.eval_metadata.frozen_hash does not match the held-out eval")
                }
            }

            $records.Add([pscustomobject]@{
                Source = $path
                Id = [string]$id
                Tier = $tier
                Family = $family
                Provenance = "$provenanceKind`:$provenanceSource"
                Area = $area
                PromptOverlap = Get-PromptExpectationOverlap -Prompt $prompt -Expectations $expectations
            })
        }
    }

    foreach ($sourceGroup in $records | Group-Object Source)
    {
        $train = @($sourceGroup.Group | Where-Object Tier -eq 'train' | ForEach-Object Provenance | Sort-Object -Unique)
        $heldOut = @($sourceGroup.Group | Where-Object Tier -eq 'held_out' | ForEach-Object Provenance | Sort-Object -Unique)
        $overlap = @($train | Where-Object { $_ -in $heldOut })
        if ($overlap.Count -gt 0)
        {
            $errors.Add("$($sourceGroup.Name): train and held_out provenance must be disjoint: $($overlap -join ', ')")
        }

        $total = $sourceGroup.Count
        $heldOutCount = @($sourceGroup.Group | Where-Object Tier -eq 'held_out').Count
        if ($heldOutCount / $total -lt 0.20 -or $heldOutCount / $total -gt 0.50)
        {
            $warnings.Add("$($sourceGroup.Name): held-out share is $heldOutCount/$total; review tier balance")
        }
        foreach ($tierGroup in $sourceGroup.Group | Group-Object Tier)
        {
            $family = $tierGroup.Group | Group-Object Family | Sort-Object Count -Descending | Select-Object -First 1
            if ($family.Count / $tierGroup.Count -gt 0.50)
            {
                $warnings.Add("$($sourceGroup.Name): $($tierGroup.Name) family concentration is $($family.Name) ($($family.Count)/$($tierGroup.Count)); review diversity")
            }
        }
        $provenance = $sourceGroup.Group | Group-Object Provenance | Sort-Object Count -Descending | Select-Object -First 1
        if ($provenance.Count / $total -gt 0.50)
        {
            $warnings.Add("$($sourceGroup.Name): provenance concentration is $($provenance.Name) ($($provenance.Count)/$total); review independence")
        }
        foreach ($record in $sourceGroup.Group | Where-Object PromptOverlap -ge 0.60)
        {
            $warnings.Add("$($record.Source): eval $($record.Id) prompt/expectation term overlap is $($record.PromptOverlap.ToString('P1')); review for answer leakage")
        }
    }

    $weights = foreach ($sourceTier in $records | Group-Object Source, Tier)
    {
        $families = @($sourceTier.Group | Group-Object Family)
        foreach ($family in $families)
        {
            foreach ($record in $family.Group)
            {
                [pscustomobject]@{
                    source = $record.Source
                    eval_id = $record.Id
                    tier = $record.Tier
                    score_family = $record.Family
                    weight = 1.0 / ($families.Count * $family.Count)
                }
            }
        }
    }

    return [pscustomobject]@{
        Errors = @($errors)
        Warnings = @($warnings)
        Records = @($records)
        Summary = [pscustomobject]@{
            raw_count = $records.Count
            held_out_count = @($records | Where-Object Tier -eq 'held_out').Count
            family_weights = @($weights)
        }
    }
}

function ConvertTo-YamlString
{
    param([string] $Value)

    return ConvertTo-Json -InputObject $Value -Compress
}

function Add-YamlLiteral
{
    param(
        [Collections.Generic.List[string]] $Lines,
        [string] $Key,
        [string] $Value,
        [int] $Indent
    )

    $prefix = ' ' * $Indent
    $Lines.Add("$prefix$Key`: |-")
    foreach ($line in $Value -split "`r?`n")
    {
        $Lines.Add($(if ($line) { "$prefix  $line" } else { '' }))
    }
}

function Add-FileOverlay
{
    param(
        [Collections.Generic.List[string]] $Lines,
        [string] $Source,
        [string] $Destination,
        [int] $Indent
    )

    $prefix = ' ' * $Indent
    $Lines.Add("$prefix- src: $(ConvertTo-YamlString "../../../$Source")")
    $Lines.Add("$prefix  dest: $(ConvertTo-YamlString $Destination)")
}

function Get-ProjectedPrompt
{
    param($Eval)

    $prompt = [string]$Eval.prompt
    $files = @($Eval.files)
    if ($files.Count -gt 0)
    {
        $fixtureList = for ($index = 1; $index -le $files.Count; $index++)
        {
            "- eval-input/fixture-$index.md"
        }
        $prompt += "`n`nFixture files:`n$($fixtureList -join "`n")"
    }

    foreach ($term in @($Eval.eval_metadata.forbidden_prompt_terms))
    {
        if ($prompt.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        {
            throw "eval $($Eval.id) projected prompt leaks forbidden term: $term"
        }
    }

    return $prompt
}

function ConvertTo-VallySpec
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Document,

        [Parameter(Mandatory)]
        [string] $SourcePath,

        [Parameter(Mandatory)]
        [object[]] $Evals,

        [Parameter(Mandatory)]
        [string] $Model
    )

    $skillName = [string]$Document.skill_name
    $lines = [Collections.Generic.List[string]]::new()
    @(
        '# Generated by .github/skills/aspnetcore-pr-review/scripts/Sync-VallyEvals.ps1.'
        "# Source of truth: $SourcePath."
        "# Validated with $script:VallyPackage."
        '# Run the generator with -Check to detect drift.'
        "name: $skillName"
        "description: $(ConvertTo-YamlString "Vally evals for the $skillName skill.")"
        'type: capability'
        'defaults:'
        '  runs: 5'
        '  timeout: 1200s'
        "  model: $Model"
        '  judge_model: claude-opus-5'
        'environment:'
        '  files:'
    ) | ForEach-Object { $lines.Add($_) }

    foreach ($path in $script:CommonSourcePaths)
    {
        Add-FileOverlay -Lines $lines -Source $path -Destination $path -Indent 4
    }

    @(
        '  commands:'
        '    - git init --quiet'
        '    - git clean -fdX'
        "    - git clean -fd -- $($script:SanitizedSourcePaths -join ' ')"
        '    - git remote add origin https://github.com/dotnet/aspnetcore.git'
        '    - git remote set-url --push origin no-push://dotnet/aspnetcore'
        '    - git add .'
        '    - git -c user.name=Vally -c user.email=vally@example.invalid commit --quiet --allow-empty -m "Vally fixture"'
        'scoring:'
        '  weights:'
        '    prompt: 1.0'
        '  threshold: 0.7'
        'stimuli:'
    ) | ForEach-Object { $lines.Add($_) }

    foreach ($eval in $Evals)
    {
        $metadata = $eval.eval_metadata
        $mechanism = [string]$metadata.mechanism
        $name = "eval-$(([int]$eval.id).ToString('00'))-$mechanism"
        $prompt = Get-ProjectedPrompt $eval
        if ($skillName -eq 'aspnetcore-try-fix')
        {
            $prompt = "Invoke the aspnetcore-try-fix skill for this task.`n`n$prompt"
        }
        $lines.Add("  - name: $(ConvertTo-YamlString $name)")
        Add-YamlLiteral -Lines $lines -Key 'prompt' -Value $prompt -Indent 4
        @(
            '    tags:'
            "      eval_id: $(ConvertTo-YamlString ([string]$eval.id))"
            "      skill_name: $(ConvertTo-YamlString $skillName)"
            "      executor_model: $(ConvertTo-YamlString $Model)"
            '      expected_runs: "5"'
            "      area: $(ConvertTo-YamlString ([string]$metadata.area))"
            "      score_family: $(ConvertTo-YamlString ([string]$metadata.score_family))"
            "      tier: $(ConvertTo-YamlString ([string]$metadata.tier))"
            "      provenance_kind: $(ConvertTo-YamlString ([string]$metadata.provenance.kind))"
            "      provenance_source: $(ConvertTo-YamlString ([string]$metadata.provenance.source))"
            "      discovery_mode: $(ConvertTo-YamlString ([string]$metadata.discovery_mode))"
        ) | ForEach-Object { $lines.Add($_) }

        $sourcePaths = @((Get-PropertyValue $metadata 'source_paths') | Where-Object { $null -ne $_ })
        $files = @($eval.files)
        if ($sourcePaths.Count -gt 0 -or $files.Count -gt 0)
        {
            $lines.Add('    environment:')
            $lines.Add('      files:')
            foreach ($sourcePath in $sourcePaths)
            {
                Add-FileOverlay -Lines $lines -Source $sourcePath -Destination $sourcePath -Indent 8
            }
            for ($index = 0; $index -lt $files.Count; $index++)
            {
                Add-FileOverlay -Lines $lines -Source $files[$index] -Destination "eval-input/fixture-$($index + 1).md" -Indent 8
            }
        }

        $threshold = if ($mechanism -eq $script:ModelGuardrailMechanism) { '1.0' } else { '0.7' }
        @(
            '    graders:'
            '      - type: prompt'
            '        config:'
            "          threshold: $threshold"
            '    rubric:'
            "      - $(ConvertTo-YamlString "Overall response matches this expected outcome: $($eval.expected_output)")"
        ) | ForEach-Object { $lines.Add($_) }
        foreach ($expectation in @($eval.expectations))
        {
            $lines.Add("      - $(ConvertTo-YamlString ([string]$expectation))")
        }
    }

    return ($lines -join "`n") + "`n"
}

function Get-ExpectedVallyOutputs
{
    [CmdletBinding()]
    param()

    $reviewer = Read-JsonDocument $script:ReviewerEvals
    $tryFix = Read-JsonDocument $script:TryFixEvals
    $reviewerMain = @($reviewer.evals | Where-Object { $_.eval_metadata.mechanism -ne $script:ModelGuardrailMechanism })
    $reviewerGuardrail = @($reviewer.evals | Where-Object { $_.eval_metadata.mechanism -eq $script:ModelGuardrailMechanism })

    return [ordered]@{
        $script:VallyOutputs['aspnetcore-pr-review'] = ConvertTo-VallySpec -Document $reviewer -SourcePath '.github/skills/aspnetcore-pr-review/evals/evals.json' -Evals $reviewerMain -Model 'gpt-5.6-sol'
        $script:VallyOutputs['aspnetcore-pr-review-model-guardrail'] = ConvertTo-VallySpec -Document $reviewer -SourcePath '.github/skills/aspnetcore-pr-review/evals/evals.json' -Evals $reviewerGuardrail -Model 'claude-sonnet-5'
        $script:VallyOutputs['aspnetcore-try-fix'] = ConvertTo-VallySpec -Document $tryFix -SourcePath '.github/skills/aspnetcore-try-fix/evals/evals.json' -Evals @($tryFix.evals) -Model 'gpt-5.6-sol'
    }
}

function Sync-VallyEvalSpecs
{
    [CmdletBinding()]
    param(
        [switch] $Check
    )

    $errors = [Collections.Generic.List[string]]::new()
    foreach ($entry in (Get-ExpectedVallyOutputs).GetEnumerator())
    {
        $path = [string]$entry.Key
        $expected = [string]$entry.Value
        if ($Check)
        {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Content -LiteralPath $path -Raw) -cne $expected)
            {
                $errors.Add("$([IO.Path]::GetRelativePath($script:RepoRoot, $path)) is out of date; run Sync-VallyEvals.ps1")
            }
        }
        else
        {
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            [IO.File]::WriteAllText($path, $expected, [Text.UTF8Encoding]::new($false))
        }
    }

    return @($errors)
}

function Normalize-DirectoryPath
{
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -eq $root.Length)
    {
        return $root
    }

    return $fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Resolve-CanonicalDirectoryPath
{
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Collections.Generic.HashSet[string]] $Visited
    )

    $fullPath = Normalize-DirectoryPath $Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container))
    {
        throw "directory does not exist: $fullPath"
    }

    if ($null -eq $Visited)
    {
        $comparer = if ([OperatingSystem]::IsWindows() -or [OperatingSystem]::IsMacOS())
        {
            [StringComparer]::OrdinalIgnoreCase
        }
        else
        {
            [StringComparer]::Ordinal
        }
        $Visited = [Collections.Generic.HashSet[string]]::new($comparer)
    }

    if (-not $Visited.Add($fullPath))
    {
        throw "symbolic-link cycle detected while resolving: $fullPath"
    }

    try
    {
        $root = [IO.Path]::GetPathRoot($fullPath)
        $current = Get-Item -LiteralPath $root -Force
        $relativePath = [IO.Path]::GetRelativePath($root, $fullPath)
        if ($relativePath -eq '.')
        {
            return Normalize-DirectoryPath $current.FullName
        }

        foreach ($segment in $relativePath.Split(
            [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
            [StringSplitOptions]::RemoveEmptyEntries))
        {
            $item = Get-Item -LiteralPath (Join-Path $current.FullName $segment) -Force
            if ($item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) -or $null -ne $item.LinkType)
            {
                $target = $item.ResolveLinkTarget($true)
                if ($null -eq $target)
                {
                    throw "unable to resolve symbolic-link path component: $($item.FullName)"
                }

                $canonicalTarget = Resolve-CanonicalDirectoryPath -Path $target.FullName -Visited $Visited
                $item = Get-Item -LiteralPath $canonicalTarget -Force
            }

            if (-not $item.Attributes.HasFlag([IO.FileAttributes]::Directory))
            {
                throw "path component is not a directory: $($item.FullName)"
            }

            $current = $item
        }

        return Normalize-DirectoryPath $current.FullName
    }
    finally
    {
        $Visited.Remove($fullPath) | Out-Null
    }
}

function Get-PathComparison
{
    if ([OperatingSystem]::IsWindows() -or [OperatingSystem]::IsMacOS())
    {
        return [StringComparison]::OrdinalIgnoreCase
    }

    return [StringComparison]::Ordinal
}

function Test-PathContainedBy
{
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Root,

        [switch] $AllowEqual
    )

    $candidate = Normalize-DirectoryPath $Path
    $container = Normalize-DirectoryPath $Root
    $comparison = Get-PathComparison
    if ([string]::Equals($candidate, $container, $comparison))
    {
        return $AllowEqual.IsPresent
    }

    $boundary = if ($container.EndsWith([IO.Path]::DirectorySeparatorChar))
    {
        $container
    }
    else
    {
        "$container$([IO.Path]::DirectorySeparatorChar)"
    }

    return $candidate.StartsWith($boundary, $comparison)
}

function Copy-SanitizedSkills
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Destination
    )

    $destinationPath = [IO.Path]::GetFullPath($Destination)
    $resolvedParent = Resolve-CanonicalDirectoryPath (Split-Path -Parent $destinationPath)
    $resolvedDestination = Normalize-DirectoryPath (Join-Path $resolvedParent (Split-Path -Leaf $destinationPath))
    if (Test-Path -LiteralPath $resolvedDestination)
    {
        $destinationItem = Get-Item -LiteralPath $resolvedDestination -Force
        if ($destinationItem.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) -or $null -ne $destinationItem.LinkType)
        {
            throw "refusing symbolic-link staging root: $resolvedDestination"
        }
        $resolvedDestination = Resolve-CanonicalDirectoryPath $resolvedDestination
    }

    $canonicalRepoRoot = Resolve-CanonicalDirectoryPath $script:RepoRoot
    $homePath = [Environment]::GetFolderPath('UserProfile')
    $forbidden = @(
        Normalize-DirectoryPath ([IO.Path]::GetPathRoot($canonicalRepoRoot))
        Resolve-CanonicalDirectoryPath $homePath
        $canonicalRepoRoot
    )
    $candidate = Normalize-DirectoryPath $resolvedDestination
    $comparison = Get-PathComparison
    if (@($forbidden | Where-Object { [string]::Equals($candidate, $_, $comparison) }).Count -gt 0 -or
        (Test-PathContainedBy -Path $candidate -Root $canonicalRepoRoot))
    {
        throw "refusing unsafe staging root: $candidate"
    }

    New-Item -ItemType Directory -Path $candidate -Force | Out-Null
    $destinations = [ordered]@{}
    foreach ($skill in $script:StagedSkillFiles.Keys)
    {
        $skillDestination = Normalize-DirectoryPath (Join-Path $candidate $skill)
        if (-not (Test-PathContainedBy -Path $skillDestination -Root $candidate))
        {
            throw "refusing staging path outside root: $skillDestination"
        }
        if (Test-Path -LiteralPath $skillDestination)
        {
            $destinationItem = Get-Item -LiteralPath $skillDestination -Force
            if ($destinationItem.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) -or $null -ne $destinationItem.LinkType)
            {
                throw "refusing symbolic-link skill destination: $skillDestination"
            }

            if ($destinationItem.Attributes.HasFlag([IO.FileAttributes]::Directory))
            {
                $skillDestination = Resolve-CanonicalDirectoryPath $skillDestination
                if (-not (Test-PathContainedBy -Path $skillDestination -Root $candidate))
                {
                    throw "refusing staging path outside root: $skillDestination"
                }
            }
        }
        $destinations[$skill] = $skillDestination
    }

    foreach ($skill in $script:StagedSkillFiles.Keys)
    {
        $skillDestination = $destinations[$skill]
        if (Test-Path -LiteralPath $skillDestination)
        {
            Remove-Item -LiteralPath $skillDestination -Recurse -Force
        }

        foreach ($relativePath in $script:StagedSkillFiles[$skill])
        {
            $source = Join-Path $script:RepoRoot ".github/skills/$skill/$relativePath"
            $destinationPath = Join-Path $skillDestination $relativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $destinationPath) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $destinationPath
        }
    }

    return $candidate
}

function Get-Mean
{
    param([double[]] $Values)

    if ($Values.Count -eq 0)
    {
        return 0.0
    }

    return ($Values | Measure-Object -Average).Average
}

function Get-MacroAverage
{
    param(
        [object[]] $Evals,
        [hashtable] $Scores,
        [string] $Field
    )

    $groups = $Evals | Group-Object {
        if ($Field -eq 'provenance')
        {
            "$($_.eval_metadata.provenance.kind):$($_.eval_metadata.provenance.source)"
        }
        else
        {
            $_.eval_metadata.$Field
        }
    }
    $means = foreach ($group in $groups)
    {
        Get-Mean @($group.Group | ForEach-Object { [double]$Scores[[string]$_.id] })
    }

    return Get-Mean @($means)
}

function Get-EvalScoreAggregate
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Document,

        [Parameter(Mandatory)]
        [hashtable] $Scores
    )

    $errors = [Collections.Generic.List[string]]::new()
    $expectedIds = @($Document.evals | ForEach-Object { [string]$_.id })
    foreach ($id in $Scores.Keys)
    {
        if ($Scores[$id] -isnot [ValueType] -or [double]$Scores[$id] -lt 0 -or [double]$Scores[$id] -gt 1)
        {
            $errors.Add("score for eval $id must be numeric between 0 and 1")
        }
    }
    $missing = @($expectedIds | Where-Object { -not $Scores.ContainsKey($_) })
    $extra = @($Scores.Keys | Where-Object { $_ -notin $expectedIds })
    if ($missing.Count -gt 0) { $errors.Add("missing eval scores: $($missing -join ', ')") }
    if ($extra.Count -gt 0) { $errors.Add("unknown eval scores: $($extra -join ', ')") }
    if ($errors.Count -gt 0)
    {
        return [pscustomobject]@{ Result = $null; Errors = @($errors) }
    }

    $tiers = [ordered]@{}
    foreach ($tier in @('train', 'held_out'))
    {
        $tierEvals = @($Document.evals | Where-Object { $_.eval_metadata.tier -eq $tier })
        if ($tierEvals.Count -gt 0)
        {
            $tiers[$tier] = [ordered]@{
                eval_count = $tierEvals.Count
                raw_mean = Get-Mean @($tierEvals | ForEach-Object { [double]$Scores[[string]$_.id] })
                family_macro = Get-MacroAverage -Evals $tierEvals -Scores $Scores -Field 'score_family'
                provenance_macro = Get-MacroAverage -Evals $tierEvals -Scores $Scores -Field 'provenance'
            }
        }
    }
    $familyGap = $null
    $provenanceGap = $null
    if ($tiers.Contains('train') -and $tiers.Contains('held_out'))
    {
        $familyGap = $tiers.train.family_macro - $tiers.held_out.family_macro
        $provenanceGap = $tiers.train.provenance_macro - $tiers.held_out.provenance_macro
    }

    return [pscustomobject]@{
        Result = [ordered]@{
            raw_mean = Get-Mean @($Scores.Values | ForEach-Object { [double]$_ })
            tiers = $tiers
            transfer_gap = [ordered]@{
                family_macro = $familyGap
                provenance_macro = $provenanceGap
            }
        }
        Errors = @()
    }
}

function Test-GraderError
{
    param($Grade)

    if ($null -eq $Grade)
    {
        return $false
    }
    if ($null -ne (Get-PropertyValue (Get-PropertyValue $Grade 'metadata') 'error'))
    {
        return $true
    }
    return @((Get-PropertyValue $Grade 'details') | Where-Object { Test-GraderError $_ }).Count -gt 0
}

function Read-VallyScores
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Paths,

        [string] $ExpectedSkillName
    )

    $errors = [Collections.Generic.List[string]]::new()
    $scores = @{}
    $expectedRuns = @{}
    $trajectoryStates = @{}
    $graderErrors = @{}

    foreach ($path in $Paths)
    {
        $lineNumber = 0
        foreach ($line in Get-Content -LiteralPath $path)
        {
            $lineNumber++
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $outcome = $line | ConvertFrom-Json -Depth 100 }
            catch
            {
                $errors.Add("$path`:$lineNumber`: invalid JSON")
                continue
            }
            if ($outcome.type -eq 'run-summary') { continue }

            $grade = Get-PropertyValue $outcome 'gradeResult'
            $trajectory = Get-PropertyValue $outcome 'trajectory'
            $stimulus = Get-PropertyValue $trajectory 'stimulus'
            $stimulusName = Get-PropertyValue $grade 'stimulusName'
            if (-not (Test-NonEmptyString $stimulusName)) { $stimulusName = Get-PropertyValue $outcome 'stimulus' }
            if (-not (Test-NonEmptyString $stimulusName)) { $stimulusName = Get-PropertyValue $stimulus 'name' }
            if ($stimulusName -notmatch '^eval-(\d+)(?:-.+)?$')
            {
                $errors.Add("$path`:$lineNumber`: unsupported or missing stimulus name")
                continue
            }
            $id = [string][int]$Matches[1]
            if ($outcome.status -ne 'success')
            {
                $errors.Add("$path`:$lineNumber`: $stimulusName did not complete successfully")
                continue
            }
            $trajectoryId = Get-PropertyValue $trajectory 'id'
            if (-not (Test-NonEmptyString $trajectoryId))
            {
                $errors.Add("$path`:$lineNumber`: missing trajectory id")
                continue
            }

            $tags = Get-PropertyValue $stimulus 'tags'
            if (Test-NonEmptyString $ExpectedSkillName)
            {
                $taggedSkill = Get-PropertyValue $tags 'skill_name'
                $runCountText = Get-PropertyValue $tags 'expected_runs'
                $expectedModel = Get-PropertyValue $tags 'executor_model'
                if ($taggedSkill -ne $ExpectedSkillName -or $runCountText -notmatch '^\d+$' -or [int]$runCountText -le 0 -or -not (Test-NonEmptyString $expectedModel))
                {
                    $errors.Add("$path`:$lineNumber`: $stimulusName has missing or invalid Vally governance tags")
                    continue
                }
                $expectedRuns[$id] = [int]$runCountText
                if ((Get-PropertyValue (Get-PropertyValue $trajectory 'metadata') 'model') -ne $expectedModel)
                {
                    $errors.Add("$path`:$lineNumber`: $stimulusName ran with the wrong model")
                    continue
                }
                $loadedSkills = @(Get-PropertyValue (Get-PropertyValue $trajectory 'metadata') 'skillsLoaded')
                if ($ExpectedSkillName -notin $loadedSkills)
                {
                    $errors.Add("$path`:$lineNumber`: $stimulusName did not load skill '$ExpectedSkillName'")
                    continue
                }
            }

            if ($null -eq $grade)
            {
                $errors.Add("$path`:$lineNumber`: $stimulusName has no grade")
                continue
            }
            if ($trajectoryStates[$trajectoryId] -eq 'success')
            {
                $errors.Add("$path`:$lineNumber`: duplicate trajectory id '$trajectoryId'")
                continue
            }
            if (Test-GraderError $grade)
            {
                $trajectoryStates[$trajectoryId] = 'grader-error'
                $graderErrors[$trajectoryId] = "$path`:$lineNumber`: $stimulusName"
                continue
            }
            if ($trajectoryStates[$trajectoryId] -eq 'grader-error')
            {
                $graderErrors.Remove($trajectoryId)
            }
            $trajectoryStates[$trajectoryId] = 'success'
            $score = Get-PropertyValue $grade 'score'
            if ($score -isnot [ValueType] -or [double]$score -lt 0 -or [double]$score -gt 1)
            {
                $errors.Add("$path`:$lineNumber`: $stimulusName has invalid score")
                continue
            }
            if (-not $scores.ContainsKey($id)) { $scores[$id] = [Collections.Generic.List[double]]::new() }
            $scores[$id].Add([double]$score)
        }
    }

    foreach ($source in $graderErrors.Values) { $errors.Add("$source contains a grader infrastructure error") }
    foreach ($id in $expectedRuns.Keys)
    {
        $actual = if ($scores.ContainsKey($id)) { $scores[$id].Count } else { 0 }
        if ($actual -ne $expectedRuns[$id])
        {
            $errors.Add("eval $id has $actual completed trials; expected $($expectedRuns[$id])")
        }
    }
    if ($errors.Count -gt 0)
    {
        return [pscustomobject]@{ Scores = @{}; Errors = @($errors) }
    }

    $averages = @{}
    foreach ($id in $scores.Keys) { $averages[$id] = Get-Mean @($scores[$id]) }
    return [pscustomobject]@{ Scores = $averages; Errors = @() }
}

function Test-ReviewArtifacts
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )

    $errors = [Collections.Generic.List[string]]::new()
    $reviewPath = Join-Path $Root 'final/review.md'
    $declaredPath = $null
    if (-not (Test-Path -LiteralPath $reviewPath -PathType Leaf))
    {
        $errors.Add('missing required artifact: final/review.md')
    }
    else
    {
        $reviewContent = Get-Content -LiteralPath $reviewPath -Raw
        if ([string]::IsNullOrWhiteSpace($reviewContent))
        {
            $errors.Add('required artifact is empty: final/review.md')
        }
        else
        {
            $pathMatches = [regex]::Matches($reviewContent, '(?m)^\*\*Path:\*\*\s*(.+?)\s*$')
            if ($pathMatches.Count -eq 0)
            {
                $errors.Add('final review missing marker: **Path:**')
            }
            elseif ($pathMatches.Count -gt 1)
            {
                $errors.Add('final review contains duplicate marker: **Path:**')
            }
            else
            {
                $candidatePath = $pathMatches[0].Groups[1].Value.Trim().ToLowerInvariant()
                if ($candidatePath -notin @('bounded', 'full'))
                {
                    $errors.Add("invalid calibrated value for Path: $candidatePath")
                }
                else
                {
                    $declaredPath = $candidatePath
                }
            }
        }
    }

    $requiredNonEmpty = [Collections.Generic.List[string]]::new()
    @(
        'evidence/manifest.md', 'evidence/product-oracle.md', 'evidence/head-drift.md',
        'evidence/impact-map.md', 'candidates/candidate-a.md', 'candidates/candidate-b.md',
        'final/repository-oracle.md', 'final/review.md'
    ) | ForEach-Object { $requiredNonEmpty.Add($_) }
    $requiredExisting = [Collections.Generic.List[string]]::new()
    $requiredExisting.Add('evidence/tracked.diff')

    if ($declaredPath -eq 'bounded')
    {
        $requiredNonEmpty.Add('evidence/skipped-phases.md')
    }
    elseif ($declaredPath -eq 'full')
    {
        @(
            'candidates/candidate-c.md', 'candidates/candidate-d.md',
            'cross-examination/candidate-a.md', 'cross-examination/candidate-b.md',
            'cross-examination/candidate-c.md', 'cross-examination/candidate-d.md',
            'empirical/manifest.md', 'empirical/head.log', 'empirical/claim-matrix.md',
            'empirical/stress-matrix.md', 'empirical/result.md'
        ) | ForEach-Object { $requiredNonEmpty.Add($_) }
        @(
            'empirical/before.diff', 'empirical/diagnostic.diff',
            'empirical/implementation.diff', 'empirical/red.log',
            'empirical/candidate.diff', 'empirical/green.log'
        ) | ForEach-Object { $requiredExisting.Add($_) }
    }

    foreach ($relativePath in $requiredNonEmpty)
    {
        $path = Join-Path $Root $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $errors.Add("missing required artifact: $relativePath") }
        elseif ([string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $path -Raw))) { $errors.Add("required artifact is empty: $relativePath") }
    }
    foreach ($relativePath in $requiredExisting)
    {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $relativePath) -PathType Leaf)) { $errors.Add("missing required artifact: $relativePath") }
    }

    if (-not (Test-Path -LiteralPath $reviewPath -PathType Leaf)) { return @($errors) }
    $content = Get-Content -LiteralPath $reviewPath -Raw
    foreach ($heading in @(
        '# Multi-Model Review',
        '## Current fix',
        '## Independent candidates',
        '## Adversarial consensus',
        '## Test assessment',
        '## Proof status',
        '## Final recommendation',
        '## Required follow-ups',
        '## Repository oracle gaps',
        '## Suggested review comments'
    ))
    {
        $matches = [regex]::Matches($content, "(?m)^$([regex]::Escape($heading))\s*$")
        if ($matches.Count -eq 0) { $errors.Add("final review missing marker: $heading") }
        elseif ($matches.Count -gt 1) { $errors.Add("final review contains duplicate marker: $heading") }
    }

    $orchestratorMatches = [regex]::Matches($content, '(?m)^\*\*Orchestrator:\*\*\s*(.+?)\s*$')
    if ($orchestratorMatches.Count -eq 0)
    {
        $errors.Add('final review missing marker: **Orchestrator:**')
    }
    elseif ($orchestratorMatches.Count -gt 1)
    {
        $errors.Add('final review contains duplicate marker: **Orchestrator:**')
    }
    else
    {
        $orchestrator = $orchestratorMatches[0].Groups[1].Value.Trim()
        if ($orchestrator -notmatch '(?i)^gpt(?:-|$)')
        {
            $errors.Add("final review orchestrator must be GPT-family: $orchestrator")
        }
    }

    $labels = [ordered]@{
        'Frozen-head result' = @('behavioral-fail', 'structural-defect', 'pass', 'blocked', 'not-applicable')
        'Finding proof' = @('empirical', 'structural', 'missing')
        'Scenario proof' = @('empirical', 'structural', 'missing')
        'Candidate proof' = @('production-proven', 'targeted-proven', 'diagnostic-only', 'rejected', 'blocked', 'none')
        'Product oracle' = @('documented', 'author-confirmed', 'test-encoded', 'inferred', 'unknown')
        'Oracle fidelity' = @('authoritative', 'corroborated', 'hypothesis', 'unknown')
        'Mechanism fidelity' = @('reproduced', 'structural', 'inferred', 'unknown')
        'Scenario fidelity' = @('exact', 'proxy', 'synthetic', 'missing')
        'Regression assertion disposition' = @('required-regression', 'optional-regression', 'rejected')
        'Diagnostic mutation disposition' = @('diagnostic-only', 'rejected', 'not-applicable')
        'Implementation verdict' = @('keep current fix', 'revise', 'replace')
        'Behavioral evidence' = @('empirical', 'structural', 'missing')
        'Merge readiness' = @('ready', 'recommendation only', 'blocked on evidence', 'blocked on product oracle', 'blocked on implementation')
        'Implementation confidence' = @('high', 'medium', 'low')
    }
    $values = @{}
    foreach ($label in $labels.Keys)
    {
        $matches = [regex]::Matches($content, "(?m)^\*\*$([regex]::Escape($label)):\*\*\s*(.+?)\s*$")
        if ($matches.Count -eq 0) { $errors.Add("final review missing marker: **$label`:**"); continue }
        if ($matches.Count -gt 1) { $errors.Add("final review contains duplicate marker: **$label`:**"); continue }
        $value = $matches[0].Groups[1].Value.Trim().ToLowerInvariant()
        $values[$label] = $value
        if ($value -notin $labels[$label]) { $errors.Add("invalid calibrated value for $label`: $value") }
    }

    if ($values.Count -eq $labels.Count)
    {
        $weak = $values['Oracle fidelity'] -in @('hypothesis', 'unknown') -or
            $values['Mechanism fidelity'] -in @('inferred', 'unknown') -or
            $values['Scenario fidelity'] -in @('synthetic', 'missing')
        $provenHead = $values['Frozen-head result'] -in @('behavioral-fail', 'structural-defect')
        $proofMatches = ($values['Frozen-head result'] -eq 'behavioral-fail' -and $values['Finding proof'] -eq 'empirical' -and $values['Scenario proof'] -eq 'empirical') -or
            ($values['Frozen-head result'] -eq 'structural-defect' -and $values['Finding proof'] -in @('empirical', 'structural') -and $values['Scenario proof'] -in @('empirical', 'structural'))
        if ($values['Merge readiness'] -eq 'blocked on implementation' -and ($weak -or -not $provenHead -or -not $proofMatches))
        {
            $errors.Add('blocked on implementation requires a proven frozen-head defect and stronger oracle, mechanism, scenario, and finding proof')
        }
        if ($values['Implementation confidence'] -eq 'high' -and $weak) { $errors.Add('high confidence is incompatible with weak oracle, mechanism, or scenario fidelity') }
        if ($values['Candidate proof'] -eq 'diagnostic-only' -and $values['Implementation confidence'] -eq 'high') { $errors.Add('diagnostic-only candidate proof is incompatible with high confidence') }
        if ($values['Candidate proof'] -eq 'diagnostic-only' -and $values['Merge readiness'] -eq 'ready') { $errors.Add('diagnostic-only candidate proof is incompatible with ready') }
        if ($declaredPath -eq 'bounded' -and $values['Candidate proof'] -eq 'production-proven')
        {
            $errors.Add('production-proven candidate proof requires the full review path')
        }
        if ($declaredPath -eq 'bounded' -and $values['Candidate proof'] -eq 'targeted-proven')
        {
            if (
                $values['Frozen-head result'] -ne 'behavioral-fail' -or
                $values['Finding proof'] -ne 'empirical' -or
                $values['Scenario proof'] -ne 'empirical' -or
                $values['Behavioral evidence'] -ne 'empirical' -or
                $values['Regression assertion disposition'] -ne 'required-regression'
            )
            {
                $errors.Add('bounded targeted-proven requires empirical behavioral red/green and a required-regression assertion')
            }
            foreach ($relativePath in @('empirical/head.log', 'empirical/green.log', 'empirical/result.md'))
            {
                $path = Join-Path $Root $relativePath
                if (-not (Test-Path -LiteralPath $path -PathType Leaf))
                {
                    $errors.Add("bounded targeted-proven missing required artifact: $relativePath")
                }
                elseif ([string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $path -Raw)))
                {
                    $errors.Add("bounded targeted-proven artifact is empty: $relativePath")
                }
            }
        }
        if ($values['Candidate proof'] -eq 'production-proven' -and $declaredPath -eq 'full')
        {
            if (-not $provenHead) { $errors.Add('production-proven requires a proven frozen-head defect') }
            if ($weak) { $errors.Add('production-proven is incompatible with weak oracle, mechanism, or scenario fidelity') }
            if ($values['Finding proof'] -ne 'empirical' -or $values['Scenario proof'] -ne 'empirical') { $errors.Add('production-proven requires empirical finding and scenario proof') }
            if ($values['Regression assertion disposition'] -ne 'required-regression') { $errors.Add('production-proven requires a required-regression assertion disposition') }
            $stressPath = Join-Path $Root 'empirical/stress-matrix.md'
            if (Test-Path -LiteralPath $stressPath -PathType Leaf)
            {
                $stress = Get-Content -LiteralPath $stressPath -Raw
                foreach ($dimension in @('Real producer/runtime boundary', 'Varied falsification dimensions', 'Applicable configurations/platforms', 'Neighboring suite', 'Cleanup/interruption paths'))
                {
                    if ($stress -notmatch "(?im)^\*\*$([regex]::Escape($dimension)):\*\*\s*(?:passed|not applicable\s*[-:]\s*\S)")
                    {
                        $errors.Add("production-proven requires an explicit passed or justified not-applicable status for: $dimension")
                    }
                }
                $sections = [regex]::Matches($stress, '(?ms)^## Executed cases\s*(.*?)(?=^## |\z)')
                if ($sections.Count -ne 1)
                {
                    $errors.Add('production-proven requires exactly one Executed cases section')
                }
                $rows = if ($sections.Count -eq 1) { @($sections[0].Groups[1].Value -split "`r?`n" | Where-Object { $_.Trim().StartsWith('|') -and $_ -notmatch '---' }) } else { @() }
                if ($rows.Count -lt 3 -or @($rows[1..($rows.Count - 1)] | Sort-Object -Unique).Count -lt 2)
                {
                    $errors.Add('production-proven requires multiple distinct executed cases')
                }
            }
        }
    }

    return @($errors)
}

Export-ModuleMember -Function @(
    'ConvertTo-CanonicalJson'
    'Copy-SanitizedSkills'
    'Get-EvalScoreAggregate'
    'Get-ExpectedVallyOutputs'
    'Get-HeldOutHash'
    'Get-ReviewerEvalConfiguration'
    'Get-Sha256'
    'Read-JsonDocument'
    'Read-VallyScores'
    'Resolve-EvalFixture'
    'Test-PathContainedBy'
    'Sync-VallyEvalSpecs'
    'Test-EvalSuites'
    'Test-ReviewArtifacts'
)
