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

function Get-EdgeKey([string]$NodeA, [string]$NodeB) {
    if ([string]::CompareOrdinal($NodeA, $NodeB) -le 0) { return "$NodeA||$NodeB" }
    return "$NodeB||$NodeA"
}

function New-StringSet() { return ,(New-Object 'System.Collections.Generic.HashSet[string]') }

function Add-ToMembership([hashtable]$Map, [string]$Key, [string]$NodeId) {
    if (-not $Map.ContainsKey($Key)) { $Map[$Key] = New-StringSet }
    $null = $Map[$Key].Add($NodeId)
}

function New-Graph([string]$Level, [string]$UnitType, [string]$UnitId, [string]$RepresentationFamily, [string]$SourceRepresentation, [double]$SelectedCutoff, [string]$SparsificationSupported, [string]$SelectedGraphMode, $NodeSet) {
    return [pscustomobject]@{
        level                 = $Level
        unit_type             = $UnitType
        unit_id               = $UnitId
        representation_family = $RepresentationFamily
        source_representation = $SourceRepresentation
        selected_cutoff       = $SelectedCutoff
        sparsification_supported = $SparsificationSupported
        selected_graph_mode      = $SelectedGraphMode
        node_ids              = $NodeSet
        edges                 = (New-Object 'System.Collections.Generic.List[object]')
        edge_weight_map       = @{}
    }
}

function Parse-ProgrammeYearUnitId([string]$UnitId) {
    $parts = $UnitId -split '__', 2
    if ($parts.Count -ne 2) { throw "Invalid programme-year unit id: $UnitId" }
    return [pscustomobject]@{
        programme = $parts[0]
        year      = [int]$parts[1]
    }
}

function Add-EdgeToGraph($Graph, [string]$NodeA, [string]$NodeB, [double]$Weight) {
    $key = Get-EdgeKey $NodeA $NodeB
    $Graph.edge_weight_map[$key] = $Weight
    $null = $Graph.edges.Add([pscustomobject]@{
        node_a = $NodeA
        node_b = $NodeB
        key    = $key
        weight = $Weight
    })
}

function Get-SharedNodeSet($SetA, $SetB) {
    $shared = New-StringSet
    foreach ($nodeId in $SetA) {
        if ($SetB.Contains($nodeId)) { $null = $shared.Add($nodeId) }
    }
    return ,$shared
}

function Get-Ranks([double[]]$Values) {
    $items = for ($index = 0; $index -lt $Values.Length; $index += 1) {
        [pscustomobject]@{ index = $index; value = $Values[$index] }
    }
    $sorted = @($items | Sort-Object value, index)
    $ranks = New-Object double[] $Values.Length
    $position = 0
    while ($position -lt $sorted.Count) {
        $nextPosition = $position
        while (($nextPosition + 1) -lt $sorted.Count -and $sorted[$nextPosition + 1].value -eq $sorted[$position].value) {
            $nextPosition += 1
        }
        $averageRank = (($position + 1) + ($nextPosition + 1)) / 2.0
        for ($cursor = $position; $cursor -le $nextPosition; $cursor += 1) {
            $ranks[$sorted[$cursor].index] = $averageRank
        }
        $position = $nextPosition + 1
    }
    return ,$ranks
}

function Get-PearsonCorrelation([double[]]$X, [double[]]$Y) {
    if ($X.Length -lt 2 -or $Y.Length -lt 2) { return [double]::NaN }
    $meanX = ($X | Measure-Object -Average).Average
    $meanY = ($Y | Measure-Object -Average).Average
    $numerator = 0.0; $sumSquaresX = 0.0; $sumSquaresY = 0.0
    for ($index = 0; $index -lt $X.Length; $index += 1) {
        $dx = $X[$index] - $meanX
        $dy = $Y[$index] - $meanY
        $numerator += $dx * $dy
        $sumSquaresX += $dx * $dx
        $sumSquaresY += $dy * $dy
    }
    $denominator = [math]::Sqrt($sumSquaresX * $sumSquaresY)
    if ($denominator -eq 0) { return [double]::NaN }
    return $numerator / $denominator
}

function Get-SpearmanCorrelation([double[]]$X, [double[]]$Y) {
    if ($X.Length -lt 2 -or $Y.Length -lt 2) { return [double]::NaN }
    return Get-PearsonCorrelation (Get-Ranks $X) (Get-Ranks $Y)
}

function Get-GraphProfile($Graph) {
    $nodeCount = $Graph.node_ids.Count
    $edgeCount = $Graph.edges.Count
    $degrees = @{}
    $strengths = @{}
    $adjacency = @{}

    foreach ($nodeId in $Graph.node_ids) {
        $degrees[$nodeId] = 0
        $strengths[$nodeId] = 0.0
        $adjacency[$nodeId] = New-Object 'System.Collections.Generic.List[string]'
    }

    foreach ($edge in $Graph.edges) {
        $degrees[$edge.node_a] += 1
        $degrees[$edge.node_b] += 1
        $strengths[$edge.node_a] += $edge.weight
        $strengths[$edge.node_b] += $edge.weight
        $adjacency[$edge.node_a].Add($edge.node_b)
        $adjacency[$edge.node_b].Add($edge.node_a)
    }

    $density = if ($nodeCount -lt 2) { 0.0 } else { (2.0 * $edgeCount) / ($nodeCount * ($nodeCount - 1)) }
    $meanDegree = if ($nodeCount -eq 0) { 0.0 } else { (2.0 * $edgeCount) / $nodeCount }
    $meanStrength = if ($nodeCount -eq 0) { 0.0 } else { (($strengths.Values | Measure-Object -Sum).Sum) / $nodeCount }
    $isolatedNodes = @($degrees.GetEnumerator() | Where-Object { $_.Value -eq 0 } | ForEach-Object { $_.Key })
    $isolateShare = if ($nodeCount -eq 0) { 0.0 } else { $isolatedNodes.Count / [double]$nodeCount }
    $connectedNodeShare = if ($nodeCount -eq 0) { 0.0 } else { 1.0 - $isolateShare }

    $visited = @{}
    $largestComponentSize = 0
    foreach ($nodeId in $Graph.node_ids) {
        if ($visited.ContainsKey($nodeId)) { continue }
        $queue = New-Object 'System.Collections.Generic.Queue[string]'
        $queue.Enqueue($nodeId); $visited[$nodeId] = $true; $componentSize = 0
        while ($queue.Count -gt 0) {
            $currentNode = $queue.Dequeue()
            $componentSize += 1
            foreach ($neighbor in $adjacency[$currentNode]) {
                if (-not $visited.ContainsKey($neighbor)) {
                    $visited[$neighbor] = $true
                    $queue.Enqueue($neighbor)
                }
            }
        }
        if ($componentSize -gt $largestComponentSize) { $largestComponentSize = $componentSize }
    }

    $largestComponentShare = if ($nodeCount -eq 0) { 0.0 } else { $largestComponentSize / [double]$nodeCount }
    return [pscustomobject]@{
        n_nodes                 = $nodeCount
        n_edges                 = $edgeCount
        density                 = $density
        mean_degree             = $meanDegree
        mean_strength           = $meanStrength
        isolate_share           = $isolateShare
        connected_node_share    = $connectedNodeShare
        largest_component_share = $largestComponentShare
    }
}

function Get-OverlapRow($GraphA, $GraphB, [hashtable]$ExtraFields) {
    $sharedNodes = Get-SharedNodeSet $GraphA.node_ids $GraphB.node_ids
    $sharedNodeCount = $sharedNodes.Count
    $unionNodeCount = $GraphA.node_ids.Count + $GraphB.node_ids.Count - $sharedNodeCount
    $nodeJaccard = if ($unionNodeCount -eq 0) { 0.0 } else { $sharedNodeCount / [double]$unionNodeCount }
    $inclusionAtoB = if ($GraphA.node_ids.Count -eq 0) { 0.0 } else { $sharedNodeCount / [double]$GraphA.node_ids.Count }
    $inclusionBtoA = if ($GraphB.node_ids.Count -eq 0) { 0.0 } else { $sharedNodeCount / [double]$GraphB.node_ids.Count }

    $fullWeightedComparison = ($GraphA.selected_graph_mode -eq 'full_weighted_graph' -or $GraphB.selected_graph_mode -eq 'full_weighted_graph')
    $edgeSupportACount = ''
    $edgeSupportBCount = ''
    $sharedRetainedEdgeCount = ''
    $unionRetainedEdgeCount = ''
    $conditionalEdgeJaccard = ''
    $weightedSpearman = ''

    if (-not $fullWeightedComparison) {
        $edgeSupportA = @{}
        foreach ($edge in $GraphA.edges) {
            if ($sharedNodes.Contains($edge.node_a) -and $sharedNodes.Contains($edge.node_b)) {
                $edgeSupportA[$edge.key] = $edge.weight
            }
        }

        $edgeSupportB = @{}
        foreach ($edge in $GraphB.edges) {
            if ($sharedNodes.Contains($edge.node_a) -and $sharedNodes.Contains($edge.node_b)) {
                $edgeSupportB[$edge.key] = $edge.weight
            }
        }

        $sharedRetainedEdgeCount = 0
        $weightA = @()
        $weightB = @()
        foreach ($edgeKey in $edgeSupportA.Keys) {
            if ($edgeSupportB.ContainsKey($edgeKey)) {
                $sharedRetainedEdgeCount += 1
                $weightA += [double]$edgeSupportA[$edgeKey]
                $weightB += [double]$edgeSupportB[$edgeKey]
            }
        }

        $edgeSupportACount = $edgeSupportA.Count
        $edgeSupportBCount = $edgeSupportB.Count
        $unionRetainedEdgeCount = $edgeSupportA.Count + $edgeSupportB.Count - $sharedRetainedEdgeCount
        $conditionalEdgeJaccard = if ($unionRetainedEdgeCount -eq 0) { 0.0 } else { $sharedRetainedEdgeCount / [double]$unionRetainedEdgeCount }
        $weightsComparable = ($GraphA.representation_family -eq $GraphB.representation_family)
        $weightedSpearman = if ($weightsComparable -and $sharedRetainedEdgeCount -ge 2) { Get-SpearmanCorrelation $weightA $weightB } else { [double]::NaN }
    }

    $row = [ordered]@{
        level_a                    = $GraphA.level
        unit_type_a                = $GraphA.unit_type
        unit_id_a                  = $GraphA.unit_id
        representation_family_a    = $GraphA.representation_family
        source_representation_a    = $GraphA.source_representation
        selected_cutoff_a          = Format-Number $GraphA.selected_cutoff
        sparsification_supported_a = $GraphA.sparsification_supported
        selected_graph_mode_a      = $GraphA.selected_graph_mode
        level_b                    = $GraphB.level
        unit_type_b                = $GraphB.unit_type
        unit_id_b                  = $GraphB.unit_id
        representation_family_b    = $GraphB.representation_family
        source_representation_b    = $GraphB.source_representation
        selected_cutoff_b          = Format-Number $GraphB.selected_cutoff
        sparsification_supported_b = $GraphB.sparsification_supported
        selected_graph_mode_b      = $GraphB.selected_graph_mode
        n_nodes_a                  = $GraphA.node_ids.Count
        n_nodes_b                  = $GraphB.node_ids.Count
        shared_node_count          = $sharedNodeCount
        union_node_count           = $unionNodeCount
        node_jaccard               = Format-Number $nodeJaccard
        inclusion_a_to_b           = Format-Number $inclusionAtoB
        inclusion_b_to_a           = Format-Number $inclusionBtoA
        shared_edge_support_a      = $edgeSupportACount
        shared_edge_support_b      = $edgeSupportBCount
        shared_retained_edge_count = $sharedRetainedEdgeCount
        union_retained_edge_count  = $unionRetainedEdgeCount
        conditional_edge_jaccard   = if ($conditionalEdgeJaccard -is [double]) { Format-Number $conditionalEdgeJaccard } else { '' }
        weighted_spearman          = if ($weightedSpearman -is [double]) { Format-Number $weightedSpearman } else { '' }
    }

    foreach ($key in $ExtraFields.Keys) { $row[$key] = $ExtraFields[$key] }
    return [pscustomobject]$row
}

$workspaceRoot = Split-Path -Parent $PSScriptRoot
$dataProcessedDirectory = Join-Path $workspaceRoot 'data_processed'
$graphsSparseDirectory = Join-Path $workspaceRoot 'outputs\graphs_sparse'
$representationSelectionDirectory = Join-Path $workspaceRoot 'outputs\representation_selection'
$outputDirectory = Join-Path $workspaceRoot 'outputs\descriptive_atlas'

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

$selectionPath = Join-Path $representationSelectionDirectory '08_primary_representation_selection.csv'
$harmonizedDatasetPath = Join-Path $dataProcessedDirectory '04_skills_harmonized.csv'
$pooledEdgesPath = Join-Path $graphsSparseDirectory '07_selected_graphs_pooled.csv'
$tracksEdgesPath = Join-Path $graphsSparseDirectory '07_selected_graphs_tracks.csv'
$sectionsEdgesPath = Join-Path $graphsSparseDirectory '07_selected_graphs_sections.csv'
$programmesEdgesPath = Join-Path $graphsSparseDirectory '07_selected_graphs_programmes.csv'
$programmeYearsEdgesPath = Join-Path $graphsSparseDirectory '07_selected_graphs_programme_years.csv'

foreach ($requiredPath in @(
    $selectionPath,
    $harmonizedDatasetPath,
    $pooledEdgesPath,
    $tracksEdgesPath,
    $sectionsEdgesPath,
    $programmesEdgesPath,
    $programmeYearsEdgesPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required Step 9 input not found: $requiredPath"
    }
}

$graphProfilePath = Join-Path $outputDirectory '09_graph_profile_table.csv'
$recurrenceSummaryPath = Join-Path $outputDirectory '09_programme_skill_recurrence_summary.csv'
$recurrenceDetailPath = Join-Path $outputDirectory '09_programme_skill_recurrence_detail.csv'
$adjacentProgressionPath = Join-Path $outputDirectory '09_programme_year_adjacent_progression_overlap.csv'
$allPairsProgressionPath = Join-Path $outputDirectory '09_programme_year_progression_overlap_all_pairs.csv'
$tracksOverlapPath = Join-Path $outputDirectory '09_overlap_matrix_tracks.csv'
$sectionsOverlapPath = Join-Path $outputDirectory '09_overlap_matrix_sections.csv'
$programmesOverlapPath = Join-Path $outputDirectory '09_overlap_matrix_programmes.csv'
$programmeYearsOverlapPath = Join-Path $outputDirectory '09_overlap_matrix_programme_years.csv'
$pooledComparisonPath = Join-Path $outputDirectory '09_overlap_to_pooled.csv'
$summaryPath = Join-Path $outputDirectory '09_descriptive_atlas_summary.csv'

$selectionByLevel = @{}
foreach ($row in Import-Csv -LiteralPath $selectionPath) {
    $selectionByLevel[$row.level] = [pscustomobject]@{
        representation_family = $row.selected_representation_family
        source_representation = $row.selected_source_representation
        selected_cutoff       = To-Double $row.selected_threshold
        sparsification_supported = [string]$row.sparsification_supported
        selected_graph_mode      = [string]$row.selected_graph_mode
    }
}

$selectedRows = Import-Csv -LiteralPath $harmonizedDatasetPath | ForEach-Object {
    [pscustomobject]@{
        harmonized_skill_id = $_.harmonized_skill_id
        harmonized_name     = $_.harmonized_name
        section             = $_.section
        programme           = $_.programme
        year                = $_.year
        edu_type            = $_.edu_type
    }
}

$nodeNameById = @{}
$sectionMembership = @{}
$trackMembership = @{}
$programmeMembership = @{}
$programmeYearMembership = @{}
$pooledMembership = New-StringSet

foreach ($row in $selectedRows) {
    $nodeNameById[$row.harmonized_skill_id] = $row.harmonized_name
    $null = $pooledMembership.Add($row.harmonized_skill_id)
    Add-ToMembership -Map $sectionMembership -Key $row.section -NodeId $row.harmonized_skill_id
    Add-ToMembership -Map $trackMembership -Key $row.edu_type -NodeId $row.harmonized_skill_id
    Add-ToMembership -Map $programmeMembership -Key $row.programme -NodeId $row.harmonized_skill_id
    Add-ToMembership -Map $programmeYearMembership -Key ("{0}__{1}" -f $row.programme, $row.year) -NodeId $row.harmonized_skill_id
}

$graphsByType = @{
    pooled         = @{ 'POOLED_ALL' = (New-Graph -Level 'pooled' -UnitType 'pooled' -UnitId 'POOLED_ALL' -RepresentationFamily $selectionByLevel['pooled'].representation_family -SourceRepresentation $selectionByLevel['pooled'].source_representation -SelectedCutoff $selectionByLevel['pooled'].selected_cutoff -SparsificationSupported $selectionByLevel['pooled'].sparsification_supported -SelectedGraphMode $selectionByLevel['pooled'].selected_graph_mode -NodeSet $pooledMembership) }
    track          = @{}
    section        = @{}
    programme      = @{}
    programme_year = @{}
}

foreach ($unitId in $trackMembership.Keys) {
    $s = $selectionByLevel['track']
    $graphsByType.track[$unitId] = New-Graph -Level 'track' -UnitType 'track' -UnitId $unitId -RepresentationFamily $s.representation_family -SourceRepresentation $s.source_representation -SelectedCutoff $s.selected_cutoff -SparsificationSupported $s.sparsification_supported -SelectedGraphMode $s.selected_graph_mode -NodeSet $trackMembership[$unitId]
}
foreach ($unitId in $sectionMembership.Keys) {
    $s = $selectionByLevel['section']
    $graphsByType.section[$unitId] = New-Graph -Level 'section' -UnitType 'section' -UnitId $unitId -RepresentationFamily $s.representation_family -SourceRepresentation $s.source_representation -SelectedCutoff $s.selected_cutoff -SparsificationSupported $s.sparsification_supported -SelectedGraphMode $s.selected_graph_mode -NodeSet $sectionMembership[$unitId]
}
foreach ($unitId in $programmeMembership.Keys) {
    $s = $selectionByLevel['programme']
    $graphsByType.programme[$unitId] = New-Graph -Level 'programme' -UnitType 'programme' -UnitId $unitId -RepresentationFamily $s.representation_family -SourceRepresentation $s.source_representation -SelectedCutoff $s.selected_cutoff -SparsificationSupported $s.sparsification_supported -SelectedGraphMode $s.selected_graph_mode -NodeSet $programmeMembership[$unitId]
}
foreach ($unitId in $programmeYearMembership.Keys) {
    $s = $selectionByLevel['programme_year']
    $graphsByType.programme_year[$unitId] = New-Graph -Level 'programme_year' -UnitType 'programme_year' -UnitId $unitId -RepresentationFamily $s.representation_family -SourceRepresentation $s.source_representation -SelectedCutoff $s.selected_cutoff -SparsificationSupported $s.sparsification_supported -SelectedGraphMode $s.selected_graph_mode -NodeSet $programmeYearMembership[$unitId]
}

function Import-SelectedEdges([string]$Path, [hashtable]$GraphMap) {
    Import-Csv -LiteralPath $Path | ForEach-Object {
        if ($GraphMap.ContainsKey($_.unit_id)) {
            Add-EdgeToGraph -Graph $GraphMap[$_.unit_id] -NodeA $_.source_node_id -NodeB $_.target_node_id -Weight (To-Double $_.edge_weight)
        }
    }
}

Import-SelectedEdges -Path $pooledEdgesPath -GraphMap $graphsByType.pooled
Import-SelectedEdges -Path $tracksEdgesPath -GraphMap $graphsByType.track
Import-SelectedEdges -Path $sectionsEdgesPath -GraphMap $graphsByType.section
Import-SelectedEdges -Path $programmesEdgesPath -GraphMap $graphsByType.programme
Import-SelectedEdges -Path $programmeYearsEdgesPath -GraphMap $graphsByType.programme_year

$graphProfileRows = @()
foreach ($unitType in @('pooled', 'track', 'section', 'programme', 'programme_year')) {
    foreach ($graph in ($graphsByType[$unitType].Values | Sort-Object unit_id)) {
        $profile = Get-GraphProfile $graph
        $graphProfileRows += [pscustomobject]@{
            level                   = $graph.level
            representation_family   = $graph.representation_family
            source_representation   = $graph.source_representation
            selected_cutoff         = Format-Number $graph.selected_cutoff
            sparsification_supported = $graph.sparsification_supported
            selected_graph_mode      = $graph.selected_graph_mode
            unit_type               = $graph.unit_type
            unit_id                 = $graph.unit_id
            n_nodes                 = $profile.n_nodes
            n_edges                 = $profile.n_edges
            density                 = Format-Number $profile.density
            mean_degree             = Format-Number $profile.mean_degree
            mean_strength           = Format-Number $profile.mean_strength
            isolate_share           = Format-Number $profile.isolate_share
            connected_node_share    = Format-Number $profile.connected_node_share
            largest_component_share = Format-Number $profile.largest_component_share
        }
    }
}

$recurrenceSummaryRows = @()
$recurrenceDetailRows = @()
foreach ($programmeId in ($graphsByType.programme.Keys | Sort-Object)) {
    $programmeYears = @($graphsByType.programme_year.Values | Where-Object { $_.unit_id.StartsWith("$programmeId" + '__', [System.StringComparison]::Ordinal) })
    $programmeNodeSet = $graphsByType.programme[$programmeId].node_ids
    $recurrenceBySkill = @{}

    foreach ($nodeId in $programmeNodeSet) { $recurrenceBySkill[$nodeId] = 0 }
    foreach ($programmeYearGraph in $programmeYears) {
        foreach ($nodeId in $programmeYearGraph.node_ids) { $recurrenceBySkill[$nodeId] += 1 }
    }

    $recurrentSkillCount = @($recurrenceBySkill.GetEnumerator() | Where-Object { $_.Value -ge 2 }).Count
    $meanRecurrenceCount = if ($programmeNodeSet.Count -eq 0) { 0.0 } else { (($recurrenceBySkill.Values | Measure-Object -Average).Average) }
    $recurrentSkillShare = if ($programmeNodeSet.Count -eq 0) { 0.0 } else { $recurrentSkillCount / [double]$programmeNodeSet.Count }
    $recurrenceSummaryRows += [pscustomobject]@{
        level                   = 'programme'
        representation_family   = $graphsByType.programme[$programmeId].representation_family
        source_representation   = $graphsByType.programme[$programmeId].source_representation
        selected_cutoff         = Format-Number $graphsByType.programme[$programmeId].selected_cutoff
        sparsification_supported = $graphsByType.programme[$programmeId].sparsification_supported
        selected_graph_mode      = $graphsByType.programme[$programmeId].selected_graph_mode
        programme_id            = $programmeId
        n_years                 = $programmeYears.Count
        n_unique_skills         = $programmeNodeSet.Count
        n_recurrent_skills      = $recurrentSkillCount
        recurrent_skill_share   = Format-Number $recurrentSkillShare
        mean_recurrence_count   = Format-Number $meanRecurrenceCount
    }

    foreach ($skillEntry in ($recurrenceBySkill.GetEnumerator() | Sort-Object Name)) {
        $recurrenceDetailRows += [pscustomobject]@{
            programme_id        = $programmeId
            harmonized_skill_id = $skillEntry.Key
            harmonized_name     = $nodeNameById[$skillEntry.Key]
            recurrence_count    = $skillEntry.Value
        }
    }
}

$allPairsProgressionRows = @()
foreach ($programmeId in ($graphsByType.programme.Keys | Sort-Object)) {
    $programmeYearGraphs = @($graphsByType.programme_year.Values |
        Where-Object { $_.unit_id.StartsWith("$programmeId" + '__', [System.StringComparison]::Ordinal) } |
        Sort-Object { (Parse-ProgrammeYearUnitId $_.unit_id).year })

    for ($i = 0; $i -lt $programmeYearGraphs.Count; $i += 1) {
        for ($j = $i + 1; $j -lt $programmeYearGraphs.Count; $j += 1) {
            $graphA = $programmeYearGraphs[$i]
            $graphB = $programmeYearGraphs[$j]
            $parsedA = Parse-ProgrammeYearUnitId $graphA.unit_id
            $parsedB = Parse-ProgrammeYearUnitId $graphB.unit_id
            $yearA = $parsedA.year
            $yearB = $parsedB.year
            $sharedNodes = Get-SharedNodeSet $graphA.node_ids $graphB.node_ids
            $sharedNodeCount = $sharedNodes.Count
            $unionNodeCount = $graphA.node_ids.Count + $graphB.node_ids.Count - $sharedNodeCount
            $nodeJaccard = if ($unionNodeCount -eq 0) { 0.0 } else { $sharedNodeCount / [double]$unionNodeCount }
            $carryoverAtoB = if ($graphA.node_ids.Count -eq 0) { 0.0 } else { $sharedNodeCount / [double]$graphA.node_ids.Count }
            $carryoverBtoA = if ($graphB.node_ids.Count -eq 0) { 0.0 } else { $sharedNodeCount / [double]$graphB.node_ids.Count }
            $introBrelativeA = if ($graphB.node_ids.Count -eq 0) { 0.0 } else { ($graphB.node_ids.Count - $sharedNodeCount) / [double]$graphB.node_ids.Count }
            $introArelativeB = if ($graphA.node_ids.Count -eq 0) { 0.0 } else { ($graphA.node_ids.Count - $sharedNodeCount) / [double]$graphA.node_ids.Count }
            $allPairsProgressionRows += [pscustomobject]@{
                programme_id                = $programmeId
                representation_family       = $graphA.representation_family
                source_representation       = $graphA.source_representation
                selected_cutoff             = Format-Number $graphA.selected_cutoff
                year_a                      = $yearA
                year_b                      = $yearB
                year_gap                    = $yearB - $yearA
                adjacent_year_flag          = if (($yearB - $yearA) -eq 1) { 'TRUE' } else { 'FALSE' }
                shared_skill_count          = $sharedNodeCount
                union_skill_count           = $unionNodeCount
                node_jaccard                = Format-Number $nodeJaccard
                carryover_a_to_b            = Format-Number $carryoverAtoB
                carryover_b_to_a            = Format-Number $carryoverBtoA
                introduction_b_relative_a   = Format-Number $introBrelativeA
                introduction_a_relative_b   = Format-Number $introArelativeB
            }
        }
    }
}

$adjacentProgressionRows = @($allPairsProgressionRows | Where-Object { $_.adjacent_year_flag -eq 'TRUE' })

function Get-OverlapRowsForClass([hashtable]$GraphMap, [string]$UnitType) {
    $graphs = @($GraphMap.Values | Sort-Object unit_id)
    $rows = @()
    for ($i = 0; $i -lt $graphs.Count; $i += 1) {
        for ($j = $i + 1; $j -lt $graphs.Count; $j += 1) {
            $graphA = $graphs[$i]
            $graphB = $graphs[$j]
            $extraFields = [ordered]@{}
            if ($UnitType -eq 'programme_year') {
                $parsedA = Parse-ProgrammeYearUnitId $graphA.unit_id
                $parsedB = Parse-ProgrammeYearUnitId $graphB.unit_id
                $programmeA = $parsedA.programme
                $programmeB = $parsedB.programme
                $yearA = $parsedA.year
                $yearB = $parsedB.year
                $extraFields['programme_a'] = $programmeA
                $extraFields['programme_b'] = $programmeB
                $extraFields['year_a'] = $yearA
                $extraFields['year_b'] = $yearB
                $extraFields['same_year_flag'] = if ($yearA -eq $yearB) { 'TRUE' } else { 'FALSE' }
                $extraFields['same_programme_flag'] = if ($programmeA -eq $programmeB) { 'TRUE' } else { 'FALSE' }
                $extraFields['within_programme_flag'] = if ($programmeA -eq $programmeB) { 'TRUE' } else { 'FALSE' }
                $extraFields['year_gap'] = [math]::Abs($yearA - $yearB)
            }
            $rows += Get-OverlapRow -GraphA $graphA -GraphB $graphB -ExtraFields $extraFields
        }
    }
    return $rows
}

$trackOverlapRows = @(Get-OverlapRowsForClass -GraphMap $graphsByType.track -UnitType 'track')
$sectionOverlapRows = @(Get-OverlapRowsForClass -GraphMap $graphsByType.section -UnitType 'section')
$programmeOverlapRows = @(Get-OverlapRowsForClass -GraphMap $graphsByType.programme -UnitType 'programme')
$programmeYearOverlapRows = @(Get-OverlapRowsForClass -GraphMap $graphsByType.programme_year -UnitType 'programme_year')

$pooledGraph = $graphsByType.pooled['POOLED_ALL']
$pooledComparisonRows = @()
foreach ($unitType in @('track', 'section', 'programme', 'programme_year')) {
    foreach ($graph in ($graphsByType[$unitType].Values | Sort-Object unit_id)) {
        $pooledComparisonRows += Get-OverlapRow -GraphA $graph -GraphB $pooledGraph -ExtraFields ([ordered]@{ comparison_scope = 'to_pooled' })
    }
}

$summaryRows = @(
    [pscustomobject]@{ summary_key = 'selection_rows'; summary_value = ($selectionByLevel.Keys.Count) }
    [pscustomobject]@{ summary_key = 'graph_profile_rows'; summary_value = $graphProfileRows.Count }
    [pscustomobject]@{ summary_key = 'programme_recurrence_summary_rows'; summary_value = $recurrenceSummaryRows.Count }
    [pscustomobject]@{ summary_key = 'programme_recurrence_detail_rows'; summary_value = $recurrenceDetailRows.Count }
    [pscustomobject]@{ summary_key = 'programme_year_adjacent_progression_rows'; summary_value = $adjacentProgressionRows.Count }
    [pscustomobject]@{ summary_key = 'programme_year_progression_all_pairs_rows'; summary_value = $allPairsProgressionRows.Count }
    [pscustomobject]@{ summary_key = 'track_overlap_rows'; summary_value = $trackOverlapRows.Count }
    [pscustomobject]@{ summary_key = 'section_overlap_rows'; summary_value = $sectionOverlapRows.Count }
    [pscustomobject]@{ summary_key = 'programme_overlap_rows'; summary_value = $programmeOverlapRows.Count }
    [pscustomobject]@{ summary_key = 'programme_year_overlap_rows'; summary_value = $programmeYearOverlapRows.Count }
    [pscustomobject]@{ summary_key = 'pooled_comparison_rows'; summary_value = $pooledComparisonRows.Count }
)

$graphProfileRows | Export-Csv -LiteralPath $graphProfilePath -NoTypeInformation -Encoding UTF8
$recurrenceSummaryRows | Export-Csv -LiteralPath $recurrenceSummaryPath -NoTypeInformation -Encoding UTF8
$recurrenceDetailRows | Export-Csv -LiteralPath $recurrenceDetailPath -NoTypeInformation -Encoding UTF8
$adjacentProgressionRows | Export-Csv -LiteralPath $adjacentProgressionPath -NoTypeInformation -Encoding UTF8
$allPairsProgressionRows | Export-Csv -LiteralPath $allPairsProgressionPath -NoTypeInformation -Encoding UTF8
$trackOverlapRows | Export-Csv -LiteralPath $tracksOverlapPath -NoTypeInformation -Encoding UTF8
$sectionOverlapRows | Export-Csv -LiteralPath $sectionsOverlapPath -NoTypeInformation -Encoding UTF8
$programmeOverlapRows | Export-Csv -LiteralPath $programmesOverlapPath -NoTypeInformation -Encoding UTF8
$programmeYearOverlapRows | Export-Csv -LiteralPath $programmeYearsOverlapPath -NoTypeInformation -Encoding UTF8
$pooledComparisonRows | Export-Csv -LiteralPath $pooledComparisonPath -NoTypeInformation -Encoding UTF8
$summaryRows | Export-Csv -LiteralPath $summaryPath -NoTypeInformation -Encoding UTF8

Write-Host "Step 9 outputs written to $outputDirectory"
Write-Host "Level-wise selections loaded: $($selectionByLevel.Keys.Count)"
