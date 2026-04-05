$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function To-Double([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return [double]::NaN }
    return [double]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-Number([double]$Value) {
    if ([double]::IsNaN($Value)) { return '' }
    return $Value.ToString('0.############', [System.Globalization.CultureInfo]::InvariantCulture)
}

$workspaceRoot = Split-Path -Parent $PSScriptRoot
$graphsSparseDirectory = Join-Path $workspaceRoot 'outputs\graphs_sparse'
$outputDirectory = Join-Path $workspaceRoot 'outputs\representation_selection'

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

$selectedModelsPath = Join-Path $graphsSparseDirectory '07_levelwise_selected_models.csv'
if (-not (Test-Path -LiteralPath $selectedModelsPath)) {
    throw "Required Step 8 input not found: $selectedModelsPath"
}

$alternativesPath = Join-Path $outputDirectory '08_levelwise_alternatives.csv'
$selectionPath = Join-Path $outputDirectory '08_primary_representation_selection.csv'
$reportPath = Join-Path $outputDirectory '08_levelwise_selection_report.csv'
$decisionLogPath = Join-Path $outputDirectory '08_selection_freeze_log.csv'

$selectedRows = @(Import-Csv -LiteralPath $selectedModelsPath | ForEach-Object {
    [pscustomobject]@{
        level                         = $_.level
        selected_representation_family = $_.selected_representation_family
        selected_source_representation = $_.selected_source_representation
        selected_threshold            = To-Double $_.selected_threshold
        cv_skill                      = To-Double $_.cv_skill
        cv_logloss                    = To-Double $_.cv_logloss
        n_units                       = [int]$_.n_units
        n_candidate_edges             = [long]$_.n_candidate_edges
        total_pair_evaluations        = [long]$_.total_pair_evaluations
        sparsification_supported      = [string]$_.sparsification_supported
        selected_graph_mode           = $_.selected_graph_mode
        selection_notes               = $_.selection_notes
    }
})

$selectionExport = $selectedRows | Sort-Object level | ForEach-Object {
    [pscustomobject]@{
        level                         = $_.level
        selected_representation_family = $_.selected_representation_family
        selected_source_representation = $_.selected_source_representation
        selected_threshold            = Format-Number $_.selected_threshold
        cv_skill                      = Format-Number $_.cv_skill
        cv_logloss                    = Format-Number $_.cv_logloss
        n_units                       = $_.n_units
        n_candidate_edges             = $_.n_candidate_edges
        total_pair_evaluations        = $_.total_pair_evaluations
        sparsification_supported      = $_.sparsification_supported
        selected_graph_mode           = $_.selected_graph_mode
        selection_notes               = $_.selection_notes
    }
}

$alternativesRows = $selectedRows | Sort-Object level | ForEach-Object {
    [pscustomobject]@{
        level                  = $_.level
        representation_family  = $_.selected_representation_family
        source_representation  = $_.selected_source_representation
        threshold              = Format-Number $_.selected_threshold
        rank_within_level      = 1
        cv_skill               = Format-Number $_.cv_skill
        cv_logloss             = Format-Number $_.cv_logloss
        n_units                = $_.n_units
        n_candidate_edges      = $_.n_candidate_edges
        total_pair_evaluations = $_.total_pair_evaluations
        selected_flag          = 'TRUE'
    }
}

$reportRows = $selectedRows | Sort-Object level | ForEach-Object {
    [pscustomobject]@{
        level                           = $_.level
        selected_representation_family  = $_.selected_representation_family
        selected_source_representation  = $_.selected_source_representation
        selected_threshold              = Format-Number $_.selected_threshold
        selected_cv_skill               = Format-Number $_.cv_skill
        selected_cv_logloss             = Format-Number $_.cv_logloss
        sparsification_supported        = $_.sparsification_supported
        selected_graph_mode             = $_.selected_graph_mode
        runner_up_representation_family = ''
        runner_up_source_representation = ''
        runner_up_threshold             = ''
        runner_up_cv_skill              = ''
        runner_up_cv_logloss            = ''
    }
}

$decisionLogRows = @(
    [pscustomobject]@{ decision_group = 'step8_role'; decision_key = 'function'; decision_value = 'freeze_and_report_only'; rationale = 'Step 8 freezes the level-wise automatic selections emitted by Step 7 and does not rerun a second selector.' }
    [pscustomobject]@{ decision_group = 'selection_scope'; decision_key = 'indexed_by_level'; decision_value = 'TRUE'; rationale = 'Representation and threshold are selected independently for pooled, track, section, programme, and programme_year graphs.' }
    [pscustomobject]@{ decision_group = 'selection_source'; decision_key = 'upstream_file'; decision_value = '07_levelwise_selected_models.csv'; rationale = 'Selections are inherited directly from the Step 7 data-driven cross-validated model-selection step.' }
    [pscustomobject]@{ decision_group = 'alternatives_scope'; decision_key = 'surface_retained_in_step7'; decision_value = 'TRUE'; rationale = 'The full candidate surface remains available in outputs/graphs_sparse/07_levelwise_model_selection_surface.csv, so Step 8 stores only the frozen winning row per level.' }
)

$alternativesRows | Export-Csv -LiteralPath $alternativesPath -NoTypeInformation -Encoding UTF8
$selectionExport | Export-Csv -LiteralPath $selectionPath -NoTypeInformation -Encoding UTF8
$reportRows | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
$decisionLogRows | Export-Csv -LiteralPath $decisionLogPath -NoTypeInformation -Encoding UTF8

Write-Host "Step 8 outputs written to $outputDirectory"
Write-Host "Levels frozen: $($selectionExport.Count)"
