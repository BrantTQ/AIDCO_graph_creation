[CmdletBinding()]
param(
    [string]$PairwiseSimilarityPath = "",
    [string]$ScreeningCutoffPath = "",
    [string]$ReviewPairsPath = "",
    [string]$ReviewSummaryPath = "",
    [string]$ReviewTemplatePath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $PSCommandPath

if ([string]::IsNullOrWhiteSpace($PairwiseSimilarityPath)) {
    $PairwiseSimilarityPath = Join-Path $scriptRoot "..\outputs\similarity_tables\02_candidate_pairwise_similarity.csv"
}

if ([string]::IsNullOrWhiteSpace($ScreeningCutoffPath)) {
    $ScreeningCutoffPath = Join-Path $scriptRoot "..\outputs\similarity_tables\02_screening_cutoff_selection.csv"
}

if ([string]::IsNullOrWhiteSpace($ReviewPairsPath)) {
    $ReviewPairsPath = Join-Path $scriptRoot "..\outputs\review\03_review_pairs_textual_instances.csv"
}

if ([string]::IsNullOrWhiteSpace($ReviewSummaryPath)) {
    $ReviewSummaryPath = Join-Path $scriptRoot "..\outputs\review\03_review_summary.csv"
}

if ([string]::IsNullOrWhiteSpace($ReviewTemplatePath)) {
    $ReviewTemplatePath = Join-Path $scriptRoot "..\outputs\review\03_review_template_textual_instances.csv"
}

function Resolve-NumericCutoff {
    param([string]$RawValue)

    if ([string]::IsNullOrWhiteSpace($RawValue)) {
        throw "Missing required screening cutoff value."
    }

    return [double]::Parse($RawValue, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-BooleanFlag {
    param([bool]$Value)
    if ($Value) { return "true" }
    return "false"
}

$resolvedPairwisePath = [System.IO.Path]::GetFullPath($PairwiseSimilarityPath)
$resolvedCutoffPath = [System.IO.Path]::GetFullPath($ScreeningCutoffPath)
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
    throw "Screening cutoff file is empty: $resolvedCutoffPath"
}

$nameOnlyCutoff = Resolve-NumericCutoff -RawValue $cutoffRow.screening_cutoff_name_only
$nameDescriptionCutoff = Resolve-NumericCutoff -RawValue $cutoffRow.screening_cutoff_name_description
$cutoffStatus = [string]$cutoffRow.cutoff_status
$cutoffSource = [string]$cutoffRow.cutoff_source

$reviewDirectory = Split-Path -Parent $resolvedReviewPairsPath
if (-not (Test-Path -LiteralPath $reviewDirectory)) {
    New-Item -ItemType Directory -Path $reviewDirectory -Force | Out-Null
}

$retainedPairs = New-Object System.Collections.Generic.List[object]
$passNameOnlyCount = 0
$passNameDescriptionCount = 0
$passBothCount = 0
$requiresManualValidationCount = 0
$exactNameStratumCount = 0

foreach ($row in Import-Csv -LiteralPath $resolvedPairwisePath) {
    $cosineNameOnly = [double]::Parse($row.cosine_name_only, [System.Globalization.CultureInfo]::InvariantCulture)
    $cosineNameDescription = [double]::Parse($row.cosine_name_description, [System.Globalization.CultureInfo]::InvariantCulture)

    $passNameOnly = $cosineNameOnly -ge $nameOnlyCutoff
    $passNameDescription = $cosineNameDescription -ge $nameDescriptionCutoff

    if (-not ($passNameOnly -or $passNameDescription)) {
        continue
    }

    if ($passNameOnly) { $passNameOnlyCount++ }
    if ($passNameDescription) { $passNameDescriptionCount++ }
    if ($passNameOnly -and $passNameDescription) { $passBothCount++ }
    if ($row.requires_manual_validation -eq "true") { $requiresManualValidationCount++ }
    if ($row.review_stratum -eq "exact_name_review_stratum") { $exactNameStratumCount++ }

    $retainedPairs.Add([pscustomobject]@{
        pair_id = $row.pair_id
        text_instance_id_1 = $row.text_instance_id_1
        text_instance_id_2 = $row.text_instance_id_2
        name_1 = $row.name_1
        description_1 = $row.description_1
        name_2 = $row.name_2
        description_2 = $row.description_2
        exact_name_match = $row.exact_name_match
        exact_description_match = $row.exact_description_match
        review_stratum = $row.review_stratum
        requires_manual_validation = $row.requires_manual_validation
        cosine_name_only = $row.cosine_name_only
        cosine_name_description = $row.cosine_name_description
        pass_name_only_screening_cutoff = Format-BooleanFlag -Value $passNameOnly
        pass_name_description_screening_cutoff = Format-BooleanFlag -Value $passNameDescription
    }) | Out-Null
}

$retainedPairs | Export-Csv -LiteralPath $resolvedReviewPairsPath -NoTypeInformation -Encoding UTF8

$reviewTemplateRows = foreach ($row in $retainedPairs) {
    [pscustomobject]@{
        pair_id = $row.pair_id
        text_instance_id_1 = $row.text_instance_id_1
        text_instance_id_2 = $row.text_instance_id_2
        name_1 = $row.name_1
        description_1 = $row.description_1
        name_2 = $row.name_2
        description_2 = $row.description_2
        exact_name_match = $row.exact_name_match
        exact_description_match = $row.exact_description_match
        review_stratum = $row.review_stratum
        requires_manual_validation = $row.requires_manual_validation
        cosine_name_only = $row.cosine_name_only
        cosine_name_description = $row.cosine_name_description
        review_decision = ""
        review_notes = ""
    }
}

$reviewTemplateRows | Export-Csv -LiteralPath $resolvedReviewTemplatePath -NoTypeInformation -Encoding UTF8

$summaryRows = @(
    [pscustomobject]@{ summary_metric = "screening_cutoff_name_only"; value = $nameOnlyCutoff.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture) }
    [pscustomobject]@{ summary_metric = "screening_cutoff_name_description"; value = $nameDescriptionCutoff.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture) }
    [pscustomobject]@{ summary_metric = "cutoff_source"; value = $cutoffSource }
    [pscustomobject]@{ summary_metric = "cutoff_status"; value = $cutoffStatus }
    [pscustomobject]@{ summary_metric = "pairs_passing_name_only_screening_cutoff"; value = $passNameOnlyCount }
    [pscustomobject]@{ summary_metric = "pairs_passing_name_description_screening_cutoff"; value = $passNameDescriptionCount }
    [pscustomobject]@{ summary_metric = "pairs_passing_both_screening_cutoffs"; value = $passBothCount }
    [pscustomobject]@{ summary_metric = "review_pairs_requiring_manual_validation"; value = $requiresManualValidationCount }
    [pscustomobject]@{ summary_metric = "review_pairs_in_exact_name_stratum"; value = $exactNameStratumCount }
    [pscustomobject]@{ summary_metric = "total_review_pairs"; value = $retainedPairs.Count }
    [pscustomobject]@{ summary_metric = "review_decisions_pre_filled"; value = "false" }
    [pscustomobject]@{ summary_metric = "allowed_review_states"; value = "equivalent;not_equivalent;uncertain" }
)

$summaryRows | Export-Csv -LiteralPath $resolvedReviewSummaryPath -NoTypeInformation -Encoding UTF8

Write-Host ("Loaded screening cutoffs: name_only={0}, name_description={1}" -f
    $nameOnlyCutoff.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture),
    $nameDescriptionCutoff.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture))
Write-Host ("Retained review pairs: {0}" -f $retainedPairs.Count)
Write-Host "Review template generated with blank review_decision and review_notes fields."
