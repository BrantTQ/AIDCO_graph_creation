$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function To-Double([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [double]::NaN
    }

    return [double]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture)
}

function To-Int([string]$Value) {
    return [int]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-Number([double]$Value) {
    if ([double]::IsNaN($Value)) {
        return ''
    }

    return $Value.ToString('0.############', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-Bool([bool]$Value) {
    if ($Value) { return 'TRUE' }
    return 'FALSE'
}

function Get-MinMaxMap($Rows, [string]$PropertyName, [bool]$Inverse = $false) {
    $values = @($Rows | ForEach-Object { [double]($_.$PropertyName) })
    $minValue = ($values | Measure-Object -Minimum).Minimum
    $maxValue = ($values | Measure-Object -Maximum).Maximum
    $map = @{}

    foreach ($row in $Rows) {
        $value = [double]($row.$PropertyName)
        if ($maxValue -eq $minValue) {
            $normalized = 1.0
        }
        elseif ($Inverse) {
            $normalized = ($maxValue - $value) / ($maxValue - $minValue)
        }
        else {
            $normalized = ($value - $minValue) / ($maxValue - $minValue)
        }

        $map[$row.representation_family] = [double]$normalized
    }

    return $map
}

$workspaceRoot = Split-Path -Parent $PSScriptRoot
$graphsSparseDirectory = Join-Path $workspaceRoot 'outputs\graphs_sparse'
$outputDirectory = Join-Path $workspaceRoot 'outputs\representation_selection'

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

$pooledCutoffsPath = Join-Path $graphsSparseDirectory '07_pooled_reference_cutoffs.csv'
$pooledSummaryPath = Join-Path $graphsSparseDirectory '07_pooled_reference_sparse_graph_summary.csv'

foreach ($requiredPath in @($pooledCutoffsPath, $pooledSummaryPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required Step 8 input not found: $requiredPath"
    }
}

$decisionMatrixPath = Join-Path $outputDirectory '08_representation_decision_matrix.csv'
$scenarioPath = Join-Path $outputDirectory '08_representation_scenarios.csv'
$consistencyPath = Join-Path $outputDirectory '08_unit_level_consistency_audit.csv'
$selectionPath = Join-Path $outputDirectory '08_primary_representation_selection.csv'
$decisionLogPath = Join-Path $outputDirectory '08_representation_selection_decision_log.csv'

$availableRows = Import-Csv -LiteralPath $pooledCutoffsPath | ForEach-Object {
    [pscustomobject]@{
        representation_family                   = $_.representation_family
        source_representation                   = $_.source_representation
        selected_threshold                      = To-Double $_.selected_threshold
        selection_rule                          = $_.selection_rule
        lambda_min                              = To-Double $_.lambda_min
        iota_max                                = To-Double $_.iota_max
        peak_susceptibility                     = To-Double $_.max_susceptibility
        largest_component_share                 = To-Double $_.largest_component_share
        connected_node_share                    = To-Double $_.connected_node_share
        isolate_share                           = To-Double $_.isolate_share
        retained_pooled_edges                   = To-Int $_.n_retained_edges
        retained_edge_share                     = To-Double $_.retained_edge_share
        n_connected_components                  = To-Int $_.n_connected_components
        eligibility_flag                        = ((To-Double $_.largest_component_share) -ge (To-Double $_.lambda_min)) -and ((To-Double $_.isolate_share) -le (To-Double $_.iota_max))
        selected_from_admissible_maximizers     = ($_.selected_from_admissible_maximizers -eq 'TRUE')
    }
}

if ($availableRows.Count -eq 0) {
    throw 'No available representation families were found in Step 7 pooled cutoffs.'
}

$eligibleRows = @($availableRows | Where-Object { $_.eligibility_flag })
$decisionRows = if ($eligibleRows.Count -gt 0) { $eligibleRows } else { $availableRows }
$fallbackDecision = ($eligibleRows.Count -eq 0)

$chiNormMap = Get-MinMaxMap -Rows $decisionRows -PropertyName 'peak_susceptibility'
$lambdaNormMap = Get-MinMaxMap -Rows $decisionRows -PropertyName 'largest_component_share'
$nuNormMap = Get-MinMaxMap -Rows $decisionRows -PropertyName 'connected_node_share'
$parsimonyMap = Get-MinMaxMap -Rows $decisionRows -PropertyName 'retained_pooled_edges' -Inverse $true

$decisionMatrixRows = @()
foreach ($row in $decisionRows) {
    $structuralScore = 0.4 * $chiNormMap[$row.representation_family] + 0.3 * $lambdaNormMap[$row.representation_family] + 0.3 * $nuNormMap[$row.representation_family]
    $parsimonyScore = $parsimonyMap[$row.representation_family]
    $richnessScore = 0.85 * $structuralScore + 0.15 * $parsimonyScore
    $simplicityScore = 0.60 * $structuralScore + 0.40 * $parsimonyScore
    $balancedScore = 0.75 * $structuralScore + 0.25 * $parsimonyScore

    $decisionMatrixRows += [pscustomobject]@{
        representation_family       = $row.representation_family
        source_representation       = $row.source_representation
        available_family            = $true
        eligible_family             = $row.eligibility_flag
        in_decision_set             = $true
        fallback_decision           = $fallbackDecision
        selected_threshold          = $row.selected_threshold
        selection_rule              = $row.selection_rule
        peak_susceptibility         = $row.peak_susceptibility
        largest_component_share     = $row.largest_component_share
        connected_node_share        = $row.connected_node_share
        isolate_share               = $row.isolate_share
        retained_pooled_edges       = $row.retained_pooled_edges
        retained_edge_share         = $row.retained_edge_share
        n_connected_components      = $row.n_connected_components
        structural_chi_norm         = $chiNormMap[$row.representation_family]
        structural_lambda_norm      = $lambdaNormMap[$row.representation_family]
        structural_nu_norm          = $nuNormMap[$row.representation_family]
        structural_score            = $structuralScore
        parsimony_score             = $parsimonyScore
        composite_score             = 0.75 * $structuralScore + 0.25 * $parsimonyScore
        richness_score              = $richnessScore
        simplicity_score            = $simplicityScore
        balanced_score              = $balancedScore
        average_scenario_score      = ($richnessScore + $simplicityScore + $balancedScore) / 3.0
        scenario_win_count          = 0
        overall_consistency_score   = [double]::NaN
        final_rank                  = 0
    }
}

$epsilon = 1e-12
foreach ($scenarioProperty in @('richness_score', 'simplicity_score', 'balanced_score')) {
    $bestValue = ($decisionMatrixRows | Measure-Object -Property $scenarioProperty -Maximum).Maximum
    foreach ($winner in $decisionMatrixRows | Where-Object { [math]::Abs([double]($_.$scenarioProperty) - $bestValue) -le $epsilon }) {
        $winner.scenario_win_count += 1
    }
}

$pooledSummaryRows = Import-Csv -LiteralPath $pooledSummaryPath | ForEach-Object {
    [pscustomobject]@{
        representation_family   = $_.representation_family
        unit_type               = $_.unit_type
        unit_id                 = $_.unit_id
        density                 = To-Double $_.density
        largest_component_share = To-Double $_.largest_component_share
        connected_node_share    = To-Double $_.connected_node_share
        isolate_share           = To-Double $_.isolate_share
        n_connected_components  = To-Int $_.n_connected_components
    }
}

$decisionFamilies = @($decisionMatrixRows.representation_family)
$auditRows = @($pooledSummaryRows | Where-Object {
    ($decisionFamilies -contains $_.representation_family) -and ($_.unit_type -ne 'all_tracks')
})

$beneficialMetrics = @('largest_component_share', 'connected_node_share', 'density')
$costMetrics = @('isolate_share', 'n_connected_components')
$unitTypes = @('section', 'track', 'programme', 'programme_year')
$consistencyRows = @()

foreach ($unitType in $unitTypes) {
    $rowsByType = @($auditRows | Where-Object { $_.unit_type -eq $unitType })
    $unitIds = @($rowsByType.unit_id | Sort-Object -Unique)
    $unitCount = $unitIds.Count
    $dominanceCounts = @{}

    foreach ($family in $decisionFamilies) {
        $dominanceCounts[$family] = @{
            largest_component_share = 0.0
            connected_node_share    = 0.0
            density                 = 0.0
            isolate_share           = 0.0
            n_connected_components  = 0.0
        }
    }

    foreach ($unitId in $unitIds) {
        $unitRows = @($rowsByType | Where-Object { $_.unit_id -eq $unitId })

        foreach ($metric in $beneficialMetrics) {
            $bestValue = ($unitRows | Measure-Object -Property $metric -Maximum).Maximum
            foreach ($winner in $unitRows | Where-Object { [math]::Abs([double]($_.$metric) - $bestValue) -le $epsilon }) {
                $dominanceCounts[$winner.representation_family][$metric] += 1.0
            }
        }

        foreach ($metric in $costMetrics) {
            $bestValue = ($unitRows | Measure-Object -Property $metric -Minimum).Minimum
            foreach ($winner in $unitRows | Where-Object { [math]::Abs([double]($_.$metric) - $bestValue) -le $epsilon }) {
                $dominanceCounts[$winner.representation_family][$metric] += 1.0
            }
        }
    }

    foreach ($family in $decisionFamilies) {
        $dominanceLcc = if ($unitCount -eq 0) { 0.0 } else { $dominanceCounts[$family]['largest_component_share'] / $unitCount }
        $dominanceConnected = if ($unitCount -eq 0) { 0.0 } else { $dominanceCounts[$family]['connected_node_share'] / $unitCount }
        $dominanceDensity = if ($unitCount -eq 0) { 0.0 } else { $dominanceCounts[$family]['density'] / $unitCount }
        $dominanceIsolate = if ($unitCount -eq 0) { 0.0 } else { $dominanceCounts[$family]['isolate_share'] / $unitCount }
        $dominanceComponents = if ($unitCount -eq 0) { 0.0 } else { $dominanceCounts[$family]['n_connected_components'] / $unitCount }
        $unitClassAuditScore = ($dominanceLcc + $dominanceConnected + $dominanceDensity + $dominanceIsolate + $dominanceComponents) / 5.0

        $consistencyRows += [pscustomobject]@{
            representation_family            = $family
            unit_type                        = $unitType
            n_units                          = $unitCount
            dominance_lcc_share              = $dominanceLcc
            dominance_connected_node_share   = $dominanceConnected
            dominance_density                = $dominanceDensity
            dominance_isolate_share          = $dominanceIsolate
            dominance_component_count        = $dominanceComponents
            unit_class_audit_score           = $unitClassAuditScore
            overall_consistency_score        = [double]::NaN
        }
    }
}

$totalLowerUnits = ($consistencyRows |
    Where-Object { ($_.representation_family -eq $decisionFamilies[0]) -and ($_.unit_type -ne 'overall') } |
    Measure-Object -Property n_units -Sum).Sum

$overallConsistencyMap = @{}
foreach ($family in $decisionFamilies) {
    $familyClassRows = @($consistencyRows | Where-Object { $_.representation_family -eq $family })
    $overallDominanceLcc = ($familyClassRows | Measure-Object -Property dominance_lcc_share -Average).Average
    $overallDominanceConnected = ($familyClassRows | Measure-Object -Property dominance_connected_node_share -Average).Average
    $overallDominanceDensity = ($familyClassRows | Measure-Object -Property dominance_density -Average).Average
    $overallDominanceIsolate = ($familyClassRows | Measure-Object -Property dominance_isolate_share -Average).Average
    $overallDominanceComponents = ($familyClassRows | Measure-Object -Property dominance_component_count -Average).Average
    $overallConsistencyScore = ($familyClassRows | Measure-Object -Property unit_class_audit_score -Average).Average
    $overallConsistencyMap[$family] = [double]$overallConsistencyScore

    foreach ($matrixRow in $decisionMatrixRows | Where-Object { $_.representation_family -eq $family }) {
        $matrixRow.overall_consistency_score = $overallConsistencyScore
    }

    $consistencyRows += [pscustomobject]@{
        representation_family            = $family
        unit_type                        = 'overall'
        n_units                          = [int]$totalLowerUnits
        dominance_lcc_share              = $overallDominanceLcc
        dominance_connected_node_share   = $overallDominanceConnected
        dominance_density                = $overallDominanceDensity
        dominance_isolate_share          = $overallDominanceIsolate
        dominance_component_count        = $overallDominanceComponents
        unit_class_audit_score           = $overallConsistencyScore
        overall_consistency_score        = $overallConsistencyScore
    }
}

$rankedRows = @($decisionMatrixRows | Sort-Object `
    @{ Expression = 'composite_score'; Descending = $true }, `
    @{ Expression = 'structural_score'; Descending = $true }, `
    @{ Expression = 'average_scenario_score'; Descending = $true }, `
    @{ Expression = 'representation_family'; Descending = $false })

$rank = 1
foreach ($row in $rankedRows) {
    $row.final_rank = $rank
    $rank += 1
}

$selectedRow = $rankedRows[0]
$sensitivityFamilies = @($rankedRows | Where-Object { $_.representation_family -ne $selectedRow.representation_family } | ForEach-Object { $_.representation_family })
$selectionRationale = if ($fallbackDecision) {
    "No available family passed the pooled usability screen, so the selection was made on the fallback decision set of all available families. $($selectedRow.representation_family) ranked first because its pooled structural score outweighed the parsimony advantage of competing families."
}
else {
    "$($selectedRow.representation_family) ranked first within the eligible family set and is frozen as the primary representation family."
}

$decisionMatrixExport = $rankedRows | ForEach-Object {
    [pscustomobject]@{
        representation_family         = $_.representation_family
        source_representation         = $_.source_representation
        available_family              = Format-Bool $_.available_family
        eligible_family               = Format-Bool $_.eligible_family
        in_decision_set               = Format-Bool $_.in_decision_set
        fallback_decision             = Format-Bool $_.fallback_decision
        selected_threshold            = Format-Number $_.selected_threshold
        selection_rule                = $_.selection_rule
        peak_susceptibility           = Format-Number $_.peak_susceptibility
        largest_component_share       = Format-Number $_.largest_component_share
        connected_node_share          = Format-Number $_.connected_node_share
        isolate_share                 = Format-Number $_.isolate_share
        retained_pooled_edges         = $_.retained_pooled_edges
        retained_edge_share           = Format-Number $_.retained_edge_share
        n_connected_components        = $_.n_connected_components
        structural_chi_norm           = Format-Number $_.structural_chi_norm
        structural_lambda_norm        = Format-Number $_.structural_lambda_norm
        structural_nu_norm            = Format-Number $_.structural_nu_norm
        structural_score              = Format-Number $_.structural_score
        parsimony_score               = Format-Number $_.parsimony_score
        composite_score               = Format-Number $_.composite_score
        overall_consistency_score     = Format-Number $_.overall_consistency_score
        final_rank                    = $_.final_rank
    }
}

$scenarioExport = $rankedRows | ForEach-Object {
    [pscustomobject]@{
        representation_family    = $_.representation_family
        source_representation    = $_.source_representation
        richness_score           = Format-Number $_.richness_score
        simplicity_score         = Format-Number $_.simplicity_score
        balanced_score           = Format-Number $_.balanced_score
        average_scenario_score   = Format-Number $_.average_scenario_score
        scenario_win_count       = $_.scenario_win_count
    }
}

$consistencyExport = $consistencyRows | Sort-Object `
    @{ Expression = 'representation_family'; Descending = $false }, `
    @{ Expression = { switch ($_.unit_type) { 'section' { 1 } 'track' { 2 } 'programme' { 3 } 'programme_year' { 4 } 'overall' { 5 } default { 99 } } }; Descending = $false } | ForEach-Object {
    [pscustomobject]@{
        representation_family          = $_.representation_family
        unit_type                      = $_.unit_type
        n_units                        = $_.n_units
        dominance_lcc_share            = Format-Number $_.dominance_lcc_share
        dominance_connected_node_share = Format-Number $_.dominance_connected_node_share
        dominance_density              = Format-Number $_.dominance_density
        dominance_isolate_share        = Format-Number $_.dominance_isolate_share
        dominance_component_count      = Format-Number $_.dominance_component_count
        unit_class_audit_score         = Format-Number $_.unit_class_audit_score
        overall_consistency_score      = Format-Number $_.overall_consistency_score
    }
}

$selectionExport = [pscustomobject]@{
    selected_representation_family = $selectedRow.representation_family
    selected_source_representation = $selectedRow.source_representation
    available_family_count         = $availableRows.Count
    eligible_family_count          = $eligibleRows.Count
    decision_set                   = (($decisionFamilies | Sort-Object) -join ';')
    fallback_decision              = Format-Bool $fallbackDecision
    selected_composite_score       = Format-Number $selectedRow.composite_score
    selected_rank                  = $selectedRow.final_rank
    selected_scenario_win_count    = $selectedRow.scenario_win_count
    selected_overall_consistency   = Format-Number $selectedRow.overall_consistency_score
    sensitivity_families           = (($sensitivityFamilies | Sort-Object) -join ';')
    selection_rationale            = $selectionRationale
}

$decisionLogExport = @(
    [pscustomobject]@{ decision_group = 'eligibility_screen'; decision_key = 'lambda_min'; decision_value = Format-Number $availableRows[0].lambda_min; rationale = 'Largest-component share threshold inherited from Step 7.' }
    [pscustomobject]@{ decision_group = 'eligibility_screen'; decision_key = 'iota_max'; decision_value = Format-Number $availableRows[0].iota_max; rationale = 'Isolate-share threshold inherited from Step 7.' }
    [pscustomobject]@{ decision_group = 'pooled_score'; decision_key = 'structural_weights'; decision_value = 'chi=0.4;lambda=0.3;nu=0.3'; rationale = 'Ex ante structural weights from Step 8 specification.' }
    [pscustomobject]@{ decision_group = 'pooled_score'; decision_key = 'composite_weights'; decision_value = 'alpha=0.75;beta=0.25'; rationale = 'Balanced pooled score weights from Step 8 specification.' }
    [pscustomobject]@{ decision_group = 'scenario_scores'; decision_key = 'richness'; decision_value = '0.85*structural + 0.15*parsimony'; rationale = 'Scenario total for structure-heavy emphasis.' }
    [pscustomobject]@{ decision_group = 'scenario_scores'; decision_key = 'simplicity'; decision_value = '0.60*structural + 0.40*parsimony'; rationale = 'Scenario total for stronger sparsity preference.' }
    [pscustomobject]@{ decision_group = 'scenario_scores'; decision_key = 'balanced'; decision_value = '0.75*structural + 0.25*parsimony'; rationale = 'Main pooled score repeated as a transparency scenario.' }
    [pscustomobject]@{ decision_group = 'decision_set'; decision_key = 'fallback_decision'; decision_value = Format-Bool $fallbackDecision; rationale = 'If no family passes the pooled usability screen, the decision is made on all available families.' }
    [pscustomobject]@{ decision_group = 'selection'; decision_key = 'selected_representation_family'; decision_value = $selectedRow.representation_family; rationale = $selectionRationale }
)

$decisionMatrixExport | Export-Csv -LiteralPath $decisionMatrixPath -NoTypeInformation -Encoding UTF8
$scenarioExport | Export-Csv -LiteralPath $scenarioPath -NoTypeInformation -Encoding UTF8
$consistencyExport | Export-Csv -LiteralPath $consistencyPath -NoTypeInformation -Encoding UTF8
$selectionExport | Export-Csv -LiteralPath $selectionPath -NoTypeInformation -Encoding UTF8
$decisionLogExport | Export-Csv -LiteralPath $decisionLogPath -NoTypeInformation -Encoding UTF8

Write-Host "Step 8 outputs written to $outputDirectory"
Write-Host "Selected primary representation family: $($selectedRow.representation_family)"
Write-Host "Fallback decision: $(Format-Bool $fallbackDecision)"
