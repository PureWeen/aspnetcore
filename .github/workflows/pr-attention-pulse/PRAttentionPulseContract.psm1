Set-StrictMode -Version Latest

function Format-PulseTimestamp
{
    param([Parameter(Mandatory)][object]$Value)

    if ($Value -is [datetimeoffset])
    {
        return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Value -is [datetime])
    {
        return ([datetimeoffset]$Value).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    }

    $timestamp = [datetimeoffset]::MinValue
    if ($Value -isnot [string] -or
        -not [datetimeoffset]::TryParse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$timestamp))
    {
        throw "Pulse timestamp is invalid."
    }

    return $timestamp.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function Add-PulseSection
{
    param(
        [AllowEmptyCollection()][AllowEmptyString()][Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Lines.Count -gt 0)
    {
        $Lines.Add("")
    }

    $Lines.Add("### $Name")
}

function Add-PulseCandidateView
{
    param(
        [AllowEmptyCollection()][AllowEmptyString()][Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [switch]$IncludeDiscussion
    )

    if ($Items.Count -eq 0)
    {
        $Lines.Add("None in this complete inventory.")
        return
    }

    foreach ($item in $Items)
    {
        $Lines.Add("$($item.rank). ``dotnet/aspnetcore#$($item.number)`` - $($item.title)")
        $Lines.Add("   - Author: $($item.author)")
        $Lines.Add("   - Next actor: $($item.nextActor)")
        $reasons = if (@($item.reasonCodes).Count -eq 0)
        {
            "None."
        }
        else
        {
            (@($item.reasonCodes) | ForEach-Object { "``$_``" }) -join ", "
        }
        $Lines.Add("   - Stable reasons: $reasons")
        $blockers = if (@($item.blockers).Count -eq 0)
        {
            "None."
        }
        else
        {
            @($item.blockers) -join "; "
        }
        $Lines.Add("   - Blockers: $blockers")
        $Lines.Add("   - Age and activity: $($item.ageDays) day(s) open; $($item.idleDays) day(s) idle.")
        $Lines.Add("   - Scope match: $($item.scopeMatch)")

        if ($IncludeDiscussion)
        {
            $assessment = $item.discussionAssessment
            $signals = if (@($assessment.signals).Count -eq 0)
            {
                "None."
            }
            else
            {
                (@($assessment.signals) | ForEach-Object { "``$_``" }) -join ", "
            }
            $Lines.Add("   - Discussion assessment: state $($assessment.state); complete $($assessment.complete.ToString().ToLowerInvariant()); signals $signals")
            $Lines.Add("   - Discussion comments: $($assessment.commentTotalCount) total; evidence truncated $($assessment.commentEvidenceTruncated.ToString().ToLowerInvariant()).")
            $threads = $assessment.threads
            $Lines.Add("   - Discussion threads: $($threads.returnedCount) of $($threads.totalCount) returned; complete $($threads.complete.ToString().ToLowerInvariant()); $($threads.unresolvedCount) unresolved; $($threads.outdatedUnresolvedCount) outdated unresolved.")
        }
    }
}

function ConvertTo-PRAttentionPulseBody
{
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Pulse)

    $lines = [Collections.Generic.List[string]]::new()

    if ([string]::Equals([string]$Pulse.status, "unavailable", [StringComparison]::Ordinal))
    {
        $lines.Add("> [!WARNING]")
        $lines.Add("> Attention data unavailable")
        Add-PulseSection -Lines $lines -Name "Freshness and scope"
        $lines.Add("- Attempted: ``$(Format-PulseTimestamp -Value $Pulse.attemptedAt)``")
        $lines.Add("- Error category: ``$($Pulse.errorCategory)``")
        $lines.Add("- Source repository: ``$($Pulse.source.repository)``")
        Add-PulseSection -Lines $lines -Name "Summary counts"
        $lines.Add("Candidate counts unavailable.")
        foreach ($name in @(
            "Review now",
            "Verify discussion before review",
            "Needs rescue",
            "Ready to merge"))
        {
            Add-PulseSection -Lines $lines -Name $name
            $lines.Add("Unavailable because collection did not produce a complete compatible inventory.")
        }
        Add-PulseSection -Lines $lines -Name "Coverage and data quality"
        $lines.Add("No complete source coverage was available.")

        return $lines -join "`n"
    }

    if (-not [string]::Equals([string]$Pulse.status, "complete", [StringComparison]::Ordinal))
    {
        throw "Unsupported Pulse status '$($Pulse.status)'."
    }

    $source = $Pulse.source
    $lines.Add("> [!IMPORTANT]")
    $lines.Add("> These views identify pull requests worth inspecting. They do not certify readiness, prove that feedback was addressed, authorize merge or review, or reliably establish completion.")
    Add-PulseSection -Lines $lines -Name "Freshness and scope"
    $lines.Add("- Attempted: ``$(Format-PulseTimestamp -Value $Pulse.attemptedAt)``")
    $lines.Add("- Source generated: ``$(Format-PulseTimestamp -Value $source.generatedAt)``")
    $lines.Add("- Source repository: ``$($source.repository)``")
    $lines.Add("- Scope: $($source.filter.description); coverage ``$($source.filter.coverage)``; selection $($source.filter.selection).")

    Add-PulseSection -Lines $lines -Name "Summary counts"
    $lines.Add("- Open pull requests: $($source.census.openPullRequests)")
    $lines.Add("- Matched pull requests: $($source.census.matched)")
    $lines.Add("- Review now candidates shown: $(@($Pulse.views.reviewNow).Count)")
    $lines.Add("- Discussion verification candidates shown: $(@($Pulse.views.verifyDiscussionBeforeReview).Count)")
    $lines.Add("- Needs rescue candidates shown: $(@($Pulse.views.needsRescue).Count)")
    $lines.Add("- Ready to merge candidates shown: $(@($Pulse.views.readyToMerge).Count)")
    $lines.Add("- Queue census: Review now $($source.census.byBucket.ReviewNow); Needs rescue $($source.census.byBucket.NeedsRescue); Ready to merge $($source.census.byBucket.ReadyToMerge); Waiting on author $($source.census.byBucket.WaitingOnAuthor); Waiting on CI $($source.census.byBucket.WaitingOnCI); Design decision $($source.census.byBucket.DesignDecision); Draft $($source.census.byBucket.Draft); Excluded $($source.census.byBucket.Excluded).")

    Add-PulseSection -Lines $lines -Name "Review now"
    Add-PulseCandidateView -Lines $lines -Items @($Pulse.views.reviewNow)
    Add-PulseSection -Lines $lines -Name "Verify discussion before review"
    Add-PulseCandidateView -Lines $lines -Items @($Pulse.views.verifyDiscussionBeforeReview) -IncludeDiscussion
    Add-PulseSection -Lines $lines -Name "Needs rescue"
    Add-PulseCandidateView -Lines $lines -Items @($Pulse.views.needsRescue)
    Add-PulseSection -Lines $lines -Name "Ready to merge"
    Add-PulseCandidateView -Lines $lines -Items @($Pulse.views.readyToMerge)

    Add-PulseSection -Lines $lines -Name "Coverage and data quality"
    $lines.Add("- Query coverage: $($source.query.returnedPullRequestCount) of $($source.query.openPullRequestCount) open pull requests returned; complete true.")
    $lines.Add("- Discussion coverage: $($source.discussion.assessedCandidateCount) of limit $($source.discussion.candidateLimit) assessed; $($source.discussion.verificationNeededCount) need verification; $($source.discussion.unassessedReviewNowCount) Review now candidates unassessed.")
    $lines.Add("- Scope census: $($source.census.labelOnly) label-only; $($source.census.pathOnly) path-only; $($source.census.labelAndPath) label-and-path; $($source.census.incidentalPathExcluded) incidental paths excluded; $($source.census.unresolvedMergeable) unresolved mergeability.")
    $lines.Add("- Overflow: Review now $($source.overflow.reviewNow); Needs rescue $($source.overflow.needsRescue); Ready to merge $($source.overflow.readyToMerge).")
    $lines.Add("- Caps: Review now $($source.caps.reviewNow); Review now per author $($source.caps.reviewNowPerAuthor); Needs rescue $($source.caps.needsRescue); Ready to merge $($source.caps.readyToMerge).")
    if (@($source.warnings).Count -eq 0)
    {
        $lines.Add("- Warnings: None.")
    }
    else
    {
        foreach ($warning in @($source.warnings))
        {
            $lines.Add("- Warning: $warning")
        }
    }

    return $lines -join "`n"
}

function Assert-PRAttentionPulseOutput
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$AgentOutput,
        [Parameter(Mandatory)][object]$Pulse,
        [Parameter(Mandatory)][string]$ExpectedBody,
        [int]$ExpectedIssueNumber = 58
    )

    $topProperties = @($AgentOutput.PSObject.Properties.Name)
    $expectedTopProperties = @("errors", "items")
    if ($topProperties.Count -ne 2 -or
        -not [string]::Equals(
            (($topProperties | Sort-Object) -join ","),
            ($expectedTopProperties -join ","),
            [StringComparison]::Ordinal))
    {
        throw "Agent output must contain only the items and errors arrays."
    }

    if ($AgentOutput.errors -isnot [array] -or @($AgentOutput.errors).Count -ne 0)
    {
        throw "Agent output ingestion must contain an empty errors array."
    }

    if ($AgentOutput.items -isnot [array] -or @($AgentOutput.items).Count -ne 1)
    {
        throw "Agent output must contain exactly one item."
    }

    $item = @($AgentOutput.items)[0]
    $itemProperties = @($item.PSObject.Properties.Name | Sort-Object)
    $expectedProperties = @("body", "issue_number", "operation", "type")
    if (-not [string]::Equals(
        ($itemProperties -join ","),
        ($expectedProperties -join ","),
        [StringComparison]::Ordinal))
    {
        throw "The update payload must contain only type, issue_number, operation, and body; actual properties: $($itemProperties -join ',')."
    }

    if (-not [string]::Equals([string]$item.type, "update_issue", [StringComparison]::Ordinal))
    {
        throw "The only permitted payload type is update_issue."
    }

    if ($item.issue_number -isnot [byte] -and
        $item.issue_number -isnot [int16] -and
        $item.issue_number -isnot [int32] -and
        $item.issue_number -isnot [int64])
    {
        throw "The issue number must be numeric."
    }

    if ([int64]$item.issue_number -ne $ExpectedIssueNumber)
    {
        throw "The update payload targeted the wrong issue."
    }

    if (-not [string]::Equals([string]$item.operation, "replace", [StringComparison]::Ordinal))
    {
        throw "The update payload must replace the issue body."
    }

    if ($item.body -isnot [string] -or
        -not [string]::Equals($item.body, $ExpectedBody, [StringComparison]::Ordinal))
    {
        throw "The emitted body does not exactly match the deterministic Pulse rendering."
    }

    $body = $item.body
    if ($body.Length -lt 200 -or $body.Length -gt 65000)
    {
        throw "The issue body is outside the allowed size range."
    }

    foreach ($pattern in @(
        "(?i)\b(?:https?|ftp)://",
        "(?i)\bwww\.",
        "(?i)(?<![\w.-])(?:[A-Z0-9-]+\.)+[A-Z]{2,}(?::[0-9]+)?(?:[/#?]\S*)?",
        "\]\(",
        "(?i)<\s*a\b",
        "(?<![\w])@[A-Za-z0-9]",
        "(?i)\bGH-[0-9]+\b",
        "(?i)(?<![0-9A-Z])(?=[0-9A-F]{7,40}(?![0-9A-Z]))(?=[0-9A-F]{0,39}[A-F])(?=[0-9A-F]{0,39}[0-9])[0-9A-F]{7,40}(?![0-9A-Z])"))
    {
        if ($body -match $pattern)
        {
            throw "The issue body contains prohibited content matching '$pattern'."
        }
    }

    $expectedReferences = if ([string]::Equals([string]$Pulse.status, "complete", [StringComparison]::Ordinal))
    {
        @(
            foreach ($viewName in @(
                "reviewNow",
                "verifyDiscussionBeforeReview",
                "needsRescue",
                "readyToMerge"))
            {
                foreach ($candidate in @($Pulse.views.$viewName))
                {
                    "dotnet/aspnetcore#$($candidate.number)"
                }
            }
        )
    }
    elseif ([string]::Equals([string]$Pulse.status, "unavailable", [StringComparison]::Ordinal))
    {
        @()
    }
    else
    {
        throw "Unsupported Pulse status '$($Pulse.status)'."
    }
    $actualReferences = @(
        [regex]::Matches($body, "``(dotnet/aspnetcore#[0-9]+)``") |
            ForEach-Object { $_.Groups[1].Value }
    )
    if (-not [string]::Equals(
        ($actualReferences -join ","),
        ($expectedReferences -join ","),
        [StringComparison]::Ordinal))
    {
        throw "The body did not preserve the exact legacy candidate membership and order. Expected '$($expectedReferences -join ',')'; actual '$($actualReferences -join ',')'."
    }

    $withoutAllowedReferences = [regex]::Replace($body, "``dotnet/aspnetcore#[0-9]+``", "")
    if ($withoutAllowedReferences -match "(?<!#)#[0-9]+" -or
        $withoutAllowedReferences -match "\b[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+")
    {
        throw "The body contains a backlink-producing GitHub reference."
    }
}

Export-ModuleMember -Function ConvertTo-PRAttentionPulseBody, Assert-PRAttentionPulseOutput
