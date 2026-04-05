[CmdletBinding()]
param(
    [string]$SelectionPath = "",
    [string]$PooledEdgesPath = "",
    [string]$TracksEdgesPath = "",
    [string]$SectionsEdgesPath = "",
    [string]$ProgrammesEdgesPath = "",
    [string]$ProgrammeYearsEdgesPath = "",
    [string]$PooledNodesPath = "",
    [string]$PooledProvenancePath = "",
    [string]$HarmonizedDatasetPath = "",
    [string]$OutputDirectory = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-DefaultPath {
    param(
        [string]$ProvidedPath,
        [string]$FallbackRelativePath,
        [string]$ScriptRoot
    )

    if ([string]::IsNullOrWhiteSpace($ProvidedPath)) {
        return [System.IO.Path]::GetFullPath((Join-Path $ScriptRoot $FallbackRelativePath))
    }

    return [System.IO.Path]::GetFullPath($ProvidedPath)
}

function Convert-CompactJson {
    param([object]$Value)
    return ($Value | ConvertTo-Json -Compress -Depth 100)
}

function Convert-UniqueSortedStringArray {
    param([string[]]$Values)
    return @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}

function Get-DegreeMap {
    param([object[]]$Rows)

    $degreeMap = @{}
    foreach ($row in $Rows) {
        foreach ($nodeId in @([string]$row.source_node_id, [string]$row.target_node_id)) {
            if (-not $degreeMap.ContainsKey($nodeId)) { $degreeMap[$nodeId] = 0 }
            $degreeMap[$nodeId] += 1
        }
    }
    return $degreeMap
}

$scriptRoot = Split-Path -Parent $PSCommandPath

$SelectionPath = Resolve-DefaultPath -ProvidedPath $SelectionPath -FallbackRelativePath "..\outputs\representation_selection\08_primary_representation_selection.csv" -ScriptRoot $scriptRoot
$PooledEdgesPath = Resolve-DefaultPath -ProvidedPath $PooledEdgesPath -FallbackRelativePath "..\outputs\graphs_sparse\07_selected_graphs_pooled.csv" -ScriptRoot $scriptRoot
$TracksEdgesPath = Resolve-DefaultPath -ProvidedPath $TracksEdgesPath -FallbackRelativePath "..\outputs\graphs_sparse\07_selected_graphs_tracks.csv" -ScriptRoot $scriptRoot
$SectionsEdgesPath = Resolve-DefaultPath -ProvidedPath $SectionsEdgesPath -FallbackRelativePath "..\outputs\graphs_sparse\07_selected_graphs_sections.csv" -ScriptRoot $scriptRoot
$ProgrammesEdgesPath = Resolve-DefaultPath -ProvidedPath $ProgrammesEdgesPath -FallbackRelativePath "..\outputs\graphs_sparse\07_selected_graphs_programmes.csv" -ScriptRoot $scriptRoot
$ProgrammeYearsEdgesPath = Resolve-DefaultPath -ProvidedPath $ProgrammeYearsEdgesPath -FallbackRelativePath "..\outputs\graphs_sparse\07_selected_graphs_programme_years.csv" -ScriptRoot $scriptRoot
$PooledNodesPath = Resolve-DefaultPath -ProvidedPath $PooledNodesPath -FallbackRelativePath "..\outputs\node_tables\05_graph_ready_nodes_pooled.csv" -ScriptRoot $scriptRoot
$PooledProvenancePath = Resolve-DefaultPath -ProvidedPath $PooledProvenancePath -FallbackRelativePath "..\outputs\node_tables\05_harmonized_node_provenance.csv" -ScriptRoot $scriptRoot
$HarmonizedDatasetPath = Resolve-DefaultPath -ProvidedPath $HarmonizedDatasetPath -FallbackRelativePath "..\data_processed\04_skills_harmonized.csv" -ScriptRoot $scriptRoot
$OutputDirectory = Resolve-DefaultPath -ProvidedPath $OutputDirectory -FallbackRelativePath "..\outputs\final_graphs_selected_methodology" -ScriptRoot $scriptRoot

foreach ($requiredPath in @(
    $SelectionPath,
    $PooledEdgesPath,
    $TracksEdgesPath,
    $SectionsEdgesPath,
    $ProgrammesEdgesPath,
    $ProgrammeYearsEdgesPath,
    $PooledNodesPath,
    $PooledProvenancePath,
    $HarmonizedDatasetPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required input file not found: $requiredPath"
    }
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$selectionRows = @(Import-Csv -LiteralPath $SelectionPath)
$selectionByLevel = @{}
foreach ($row in $selectionRows) { $selectionByLevel[$row.level] = $row }

$edgeSpecs = @(
    [pscustomobject]@{ level = "pooled"; input_path = $PooledEdgesPath; output_name = "final_edges_pooled.csv" }
    [pscustomobject]@{ level = "tracks"; input_path = $TracksEdgesPath; output_name = "final_edges_tracks.csv" }
    [pscustomobject]@{ level = "sections"; input_path = $SectionsEdgesPath; output_name = "final_edges_sections.csv" }
    [pscustomobject]@{ level = "programmes"; input_path = $ProgrammesEdgesPath; output_name = "final_edges_programmes.csv" }
    [pscustomobject]@{ level = "programme_years"; input_path = $ProgrammeYearsEdgesPath; output_name = "final_edges_programme_years.csv" }
)

$manifestRows = New-Object System.Collections.Generic.List[object]

foreach ($spec in $edgeSpecs) {
    $rows = @(Import-Csv -LiteralPath $spec.input_path | ForEach-Object {
        [pscustomobject]@{
            level                          = $_.level
            unit_type                      = $_.unit_type
            unit_id                        = $_.unit_id
            selected_representation_family = $_.selected_representation_family
            selected_source_representation = $_.selected_source_representation
            selected_cutoff                = $_.selected_threshold
            source_node_id                 = $_.source_node_id
            source_node_name               = $_.source_node_name
            target_node_id                 = $_.target_node_id
            target_node_name               = $_.target_node_name
            edge_weight                    = $_.edge_weight
        }
    })

    $outputPath = Join-Path $OutputDirectory $spec.output_name
    $rows | Export-Csv -LiteralPath $outputPath -NoTypeInformation -Encoding UTF8

    $manifestRows.Add([pscustomobject]@{
        artifact_type = "edges"
        level = $spec.level
        output_file = $spec.output_name
            row_count = @($rows).Count
    }) | Out-Null
}

$pooledEdges = Import-Csv -LiteralPath (Join-Path $OutputDirectory "final_edges_pooled.csv")
$pooledDegreeMap = Get-DegreeMap -Rows $pooledEdges

$pooledNodeRows = Import-Csv -LiteralPath $PooledNodesPath
$pooledProvenanceRows = Import-Csv -LiteralPath $PooledProvenancePath | Where-Object { $_.unit_type -eq "pooled" -and $_.unit_id -eq "POOLED_ALL" }
$harmonizedRows = Import-Csv -LiteralPath $HarmonizedDatasetPath

$pooledProvenanceById = @{}
foreach ($row in $pooledProvenanceRows) { $pooledProvenanceById[$row.harmonized_skill_id] = $row }

$sectionMemberships = @{}
$trackMemberships = @{}
$programmeMemberships = @{}
$yearMemberships = @{}
$programmeYearMemberships = @{}
$occurrenceMemberships = @{}

foreach ($row in $harmonizedRows) {
    $hid = [string]$row.harmonized_skill_id
    if (-not $sectionMemberships.ContainsKey($hid)) {
        $sectionMemberships[$hid] = New-Object System.Collections.Generic.List[string]
        $trackMemberships[$hid] = New-Object System.Collections.Generic.List[string]
        $programmeMemberships[$hid] = New-Object System.Collections.Generic.List[string]
        $yearMemberships[$hid] = New-Object System.Collections.Generic.List[string]
        $programmeYearMemberships[$hid] = New-Object System.Collections.Generic.List[string]
        $occurrenceMemberships[$hid] = New-Object System.Collections.Generic.List[string]
    }
    $sectionMemberships[$hid].Add([string]$row.section)
    $trackMemberships[$hid].Add([string]$row.edu_type)
    $programmeMemberships[$hid].Add([string]$row.programme)
    $yearMemberships[$hid].Add([string]$row.year)
    $programmeYearMemberships[$hid].Add(("{0}__{1}" -f $row.programme, $row.year))
    $occurrenceMemberships[$hid].Add([string]$row.occurrence_id)
}

$selectionMethodByLevel = @{}
$selectionCutoffByLevel = @{}
foreach ($row in $selectionRows) {
    $selectionMethodByLevel[[string]$row.level] = [string]$row.selected_representation_family
    $selectionCutoffByLevel[[string]$row.level] = [string]$row.selected_threshold
}

$masterRows = foreach ($node in $pooledNodeRows | Sort-Object harmonized_skill_id) {
    $hid = [string]$node.harmonized_skill_id
    $provenance = $pooledProvenanceById[$hid]
    $sectionArray = @(Convert-UniqueSortedStringArray -Values $sectionMemberships[$hid].ToArray())
    $trackArray = @(Convert-UniqueSortedStringArray -Values $trackMemberships[$hid].ToArray())
    $programmeArray = @(Convert-UniqueSortedStringArray -Values $programmeMemberships[$hid].ToArray())
    $yearArray = @(Convert-UniqueSortedStringArray -Values $yearMemberships[$hid].ToArray())
    $programmeYearArray = @(Convert-UniqueSortedStringArray -Values $programmeYearMemberships[$hid].ToArray())
    $occurrenceArray = @(Convert-UniqueSortedStringArray -Values $occurrenceMemberships[$hid].ToArray())

    [pscustomobject]@{
        harmonized_skill_id = $hid
        harmonized_name = [string]$node.harmonized_name
        pooled_selected_degree = if ($pooledDegreeMap.ContainsKey($hid)) { $pooledDegreeMap[$hid] } else { 0 }
        is_isolated_in_selected_pooled_graph = if ($pooledDegreeMap.ContainsKey($hid)) { "false" } else { "true" }
        n_source_records = [int]$node.n_source_records
        n_source_years = [int]$node.n_source_years
        n_source_programmes = [int]$node.n_source_programmes
        n_source_sections = [int]$node.n_source_sections
        n_source_edu_types = [int]$node.n_source_edu_types
        source_skill_ids = if ($null -ne $provenance) { $provenance.source_skill_ids } else { "[]" }
        source_text_instance_ids = if ($null -ne $provenance) { $provenance.source_text_instance_ids } else { "[]" }
        source_old_names = if ($null -ne $provenance) { $provenance.source_old_names } else { "[]" }
        source_programmes = if ($null -ne $provenance) { $provenance.source_programmes } else { "[]" }
        source_sections = if ($null -ne $provenance) { $provenance.source_sections } else { "[]" }
        source_years = if ($null -ne $provenance) { $provenance.source_years } else { "[]" }
        source_edu_types = if ($null -ne $provenance) { $provenance.source_edu_types } else { "[]" }
        section_memberships = Convert-CompactJson $sectionArray
        track_memberships = Convert-CompactJson $trackArray
        programme_memberships = Convert-CompactJson $programmeArray
        year_memberships = Convert-CompactJson $yearArray
        programme_year_memberships = Convert-CompactJson $programmeYearArray
        n_programme_year_memberships = @($programmeYearArray).Count
        occurrence_ids = Convert-CompactJson $occurrenceArray
        selected_method_by_level = Convert-CompactJson $selectionMethodByLevel
        selected_cutoff_by_level = Convert-CompactJson $selectionCutoffByLevel
        node_name_vector = [string]$node.node_name_vector
        node_name_description_vector = [string]$node.node_name_description_vector
    }
}

$masterPath = Join-Path $OutputDirectory "final_nodes_master.csv"
$masterRows | Export-Csv -LiteralPath $masterPath -NoTypeInformation -Encoding UTF8

$manifestRows.Add([pscustomobject]@{
    artifact_type = "nodes"
    level = "master"
    output_file = "final_nodes_master.csv"
    row_count = @($masterRows).Count
}) | Out-Null

$manifestPath = Join-Path $OutputDirectory "final_graph_export_manifest.csv"
$manifestRows | Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding UTF8

$readmePath = Join-Path $OutputDirectory "README_final_graphs.txt"
$readmeLines = @(
    "Final undirected graph export package",
    "",
    "This folder contains the corrected final graph package exported from the current pipeline state.",
    "Selections are level-specific and come from outputs/representation_selection/08_primary_representation_selection.csv.",
    "",
    "Files:",
    "- final_edges_pooled.csv",
    "- final_edges_tracks.csv",
    "- final_edges_sections.csv",
    "- final_edges_programmes.csv",
    "- final_edges_programme_years.csv",
    "- final_nodes_master.csv",
    "- final_graph_export_manifest.csv",
    "",
    "Notes:",
    "- Edge files are undirected edge lists with retained edge weights.",
    "- final_nodes_master.csv contains the pooled node universe plus provenance, memberships, and node vectors.",
    "- The current corrected harmonization state is a no-merge baseline unless reviewed equivalent decisions are later added and Steps 4 to 9 are rerun."
)
$readmeLines | Set-Content -LiteralPath $readmePath -Encoding UTF8

Write-Host "Created final graph package in: $OutputDirectory"
Write-Host "Selections loaded: $($selectionRows.Count)"
