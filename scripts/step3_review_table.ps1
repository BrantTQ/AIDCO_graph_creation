[CmdletBinding()]
param(
    [string]$PairwiseSimilarityPath = "",
    [string]$CutoffSelectionPath = "",
    [string]$ReviewPairsPath = "",
    [string]$ReviewSummaryPath = "",
    [string]$ReviewTemplatePath = "",
    [switch]$AutoMarkRetainedPairsAsEquivalent,
    [string]$AutoReviewNote = "automatic_equivalence_by_cutoff",
    [double]$DefaultNameOnlyCutoff = 0.70622,
    [double]$DefaultNameDescriptionCutoff = 0.701394,
    [string]$DefaultChosenRepresentation = "both"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $PSCommandPath

if ([string]::IsNullOrWhiteSpace($PairwiseSimilarityPath)) {
    $PairwiseSimilarityPath = Join-Path $scriptRoot "..\outputs\similarity_tables\02_global_pairwise_similarity.csv"
}

if ([string]::IsNullOrWhiteSpace($CutoffSelectionPath)) {
    $CutoffSelectionPath = Join-Path $scriptRoot "..\outputs\similarity_tables\02_cutoff_selection.csv"
}

if ([string]::IsNullOrWhiteSpace($ReviewPairsPath)) {
    $ReviewPairsPath = Join-Path $scriptRoot "..\outputs\review\03_review_pairs_unique_skills.csv"
}

if ([string]::IsNullOrWhiteSpace($ReviewSummaryPath)) {
    $ReviewSummaryPath = Join-Path $scriptRoot "..\outputs\review\03_review_summary.csv"
}

if ([string]::IsNullOrWhiteSpace($ReviewTemplatePath)) {
    $ReviewTemplatePath = Join-Path $scriptRoot "..\outputs\review\03_review_template_unique_skills.csv"
}

function Resolve-NumericCutoff {
    param(
        [string]$RawValue,
        [double]$Fallback
    )

    if ([string]::IsNullOrWhiteSpace($RawValue)) {
        return $Fallback
    }

    return [double]::Parse($RawValue, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-BooleanFlag {
    param([bool]$Value)
    if ($Value) {
        return "true"
    }

    return "false"
}

$resolvedPairwisePath = [System.IO.Path]::GetFullPath($PairwiseSimilarityPath)
$resolvedCutoffPath = [System.IO.Path]::GetFullPath($CutoffSelectionPath)
$resolvedReviewPairsPath = [System.IO.Path]::GetFullPath($ReviewPairsPath)
$resolvedReviewSummaryPath = [System.IO.Path]::GetFullPath($ReviewSummaryPath)
$resolvedReviewTemplatePath = [System.IO.Path]::GetFullPath($ReviewTemplatePath)

foreach ($requiredPath in @($resolvedPairwisePath, $resolvedCutoffPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required input file not found: $requiredPath"
    }
}

$cutoffRow = Import-Csv -LiteralPath $resolvedCutoffPath | Select-Object -First 1
if ($null -eq $cutoffRow) {
    throw "Cutoff selection file is empty: $resolvedCutoffPath"
}

$nameOnlyCutoff = Resolve-NumericCutoff -RawValue $cutoffRow.chosen_cutoff_name_only -Fallback $DefaultNameOnlyCutoff
$nameDescriptionCutoff = Resolve-NumericCutoff -RawValue $cutoffRow.chosen_cutoff_name_description -Fallback $DefaultNameDescriptionCutoff
$chosenRepresentation = if ([string]::IsNullOrWhiteSpace($cutoffRow.chosen_representation)) {
    $DefaultChosenRepresentation
} else {
    $cutoffRow.chosen_representation
}

$reviewDirectory = Split-Path -Parent $resolvedReviewPairsPath
if (-not (Test-Path -LiteralPath $reviewDirectory)) {
    New-Item -ItemType Directory -Path $reviewDirectory -Force | Out-Null
}

$retainedPairs = New-Object System.Collections.Generic.List[object]
$passNameOnlyCount = 0
$passNameDescriptionCount = 0
$passBothCount = 0

foreach ($row in Import-Csv -LiteralPath $resolvedPairwisePath) {
    $cosineNameOnly = [double]::Parse($row.cosine_name_only, [System.Globalization.CultureInfo]::InvariantCulture)
    $cosineNameDescription = [double]::Parse($row.cosine_name_description, [System.Globalization.CultureInfo]::InvariantCulture)

    $passNameOnly = $cosineNameOnly -ge $nameOnlyCutoff
    $passNameDescription = $cosineNameDescription -ge $nameDescriptionCutoff

    if (-not ($passNameOnly -or $passNameDescription)) {
        continue
    }

    if ($passNameOnly) {
        $passNameOnlyCount++
    }

    if ($passNameDescription) {
        $passNameDescriptionCount++
    }

    if ($passNameOnly -and $passNameDescription) {
        $passBothCount++
    }

    $retainedPairs.Add([pscustomobject]@{
        pair_id = $row.pair_id
        unique_skill_id_1 = $row.skill_id_1
        unique_skill_id_2 = $row.skill_id_2
        name_1 = $row.name_1
        name_2 = $row.name_2
        cosine_name_only = $row.cosine_name_only
        cosine_name_description = $row.cosine_name_description
        pass_name_only_cutoff = Format-BooleanFlag -Value $passNameOnly
        pass_name_description_cutoff = Format-BooleanFlag -Value $passNameDescription
    }) | Out-Null
}

$retainedPairs | Export-Csv -LiteralPath $resolvedReviewPairsPath -NoTypeInformation -Encoding UTF8

$reviewTemplateRows = foreach ($row in $retainedPairs) {
    [pscustomobject]@{
        pair_id = $row.pair_id
        unique_skill_id_1 = $row.unique_skill_id_1
        unique_skill_id_2 = $row.unique_skill_id_2
        name_1 = $row.name_1
        name_2 = $row.name_2
        cosine_name_only = $row.cosine_name_only
        cosine_name_description = $row.cosine_name_description
        review_decision = if ($AutoMarkRetainedPairsAsEquivalent) { "equivalent" } else { "" }
        review_notes = if ($AutoMarkRetainedPairsAsEquivalent) { $AutoReviewNote } else { "" }
    }
}

$reviewTemplateRows | Export-Csv -LiteralPath $resolvedReviewTemplatePath -NoTypeInformation -Encoding UTF8

$summaryRows = @(
    [pscustomobject]@{ summary_metric = "chosen_cutoff_name_only"; value = $nameOnlyCutoff.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture) }
    [pscustomobject]@{ summary_metric = "chosen_cutoff_name_description"; value = $nameDescriptionCutoff.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture) }
    [pscustomobject]@{ summary_metric = "chosen_representation"; value = $chosenRepresentation }
    [pscustomobject]@{ summary_metric = "pairs_passing_name_only_cutoff"; value = $passNameOnlyCount }
    [pscustomobject]@{ summary_metric = "pairs_passing_name_description_cutoff"; value = $passNameDescriptionCount }
    [pscustomobject]@{ summary_metric = "pairs_passing_both_cutoffs"; value = $passBothCount }
    [pscustomobject]@{ summary_metric = "total_review_pairs"; value = $retainedPairs.Count }
)

$summaryRows | Export-Csv -LiteralPath $resolvedReviewSummaryPath -NoTypeInformation -Encoding UTF8

Write-Host ("Loaded cutoffs: name_only={0}, name_description={1}, representation={2}" -f
    $nameOnlyCutoff.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture),
    $nameDescriptionCutoff.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture),
    $chosenRepresentation)
Write-Host ("Retained review pairs: {0}" -f $retainedPairs.Count)
Write-Host ("Pairs passing name-only cutoff: {0}" -f $passNameOnlyCount)
Write-Host ("Pairs passing name-description cutoff: {0}" -f $passNameDescriptionCount)
Write-Host ("Pairs passing both cutoffs: {0}" -f $passBothCount)
if ($AutoMarkRetainedPairsAsEquivalent) {
    Write-Host ("Auto-filled review_decision='equivalent' for all retained pairs with note '{0}'." -f $AutoReviewNote)
}
