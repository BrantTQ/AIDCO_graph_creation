$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function To-Double([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [double]::NaN
    }

    return [double]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-Number([double]$Value) {
    if ([double]::IsNaN($Value)) {
        return ''
    }

    return $Value.ToString('0.############', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-EdgeKey([string]$NodeA, [string]$NodeB) {
    if ([string]::CompareOrdinal($NodeA, $NodeB) -le 0) {
        return "$NodeA||$NodeB"
    }

    return "$NodeB||$NodeA"
}

function New-StringSet() {
    return ,(New-Object 'System.Collections.Generic.HashSet[string]')
}

function Add-ToMembership([hashtable]$Map, [string]$Key, [string]$NodeId) {
    if (-not $Map.ContainsKey($Key)) {
        $Map[$Key] = New-StringSet
    }

    $null = $Map[$Key].Add($NodeId)
}

function New-Graph([string]$UnitType, [string]$UnitId, [string]$RepresentationFamily, [string]$SourceRepresentation, [double]$ReferenceThreshold, $NodeSet) {
    return [pscustomobject]@{
        unit_type             = $UnitType
        unit_id               = $UnitId
        representation_family = $RepresentationFamily
        source_representation = $SourceRepresentation
        reference_threshold   = $ReferenceThreshold
        node_ids              = $NodeSet
        edges                 = @()
        edge_weight_map       = @{}
    }
}

function Parse-ProgrammeYearUnitId([string]$UnitId) {
    $parts = $UnitId -split '__', 2
    if ($parts.Count -ne 2) {
        throw "Invalid programme-year unit id: $UnitId"
    }

    return [pscustomobject]@{
        programme = $parts[0]
        year      = [int]$parts[1]
    }
}

function Add-EdgeToGraph($Graph, [string]$NodeA, [string]$NodeB, [double]$Weight) {
    $key = Get-EdgeKey $NodeA $NodeB
    $Graph.edge_weight_map[$key] = $Weight
    $Graph.edges += [pscustomobject]@{
        node_a = $NodeA
        node_b = $NodeB
        key    = $key
        weight = $Weight
    }
}

function Get-SharedNodeSet($SetA, $SetB) {
    $shared = New-StringSet
    foreach ($nodeId in $SetA) {
        if ($SetB.Contains($nodeId)) {
            $null = $shared.Add($nodeId)
        }
    }

    return ,$shared
}

function Get-Ranks([double[]]$Values) {
    $items = for ($index = 0; $index -lt $Values.Length; $index += 1) {
        [pscustomobject]@{
            index = $index
            value = $Values[$index]
        }
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
    if ($X.Length -lt 2 -or $Y.Length -lt 2) {
        return [double]::NaN
    }

    $meanX = ($X | Measure-Object -Average).Average
    $meanY = ($Y | Measure-Object -Average).Average
    $numerator = 0.0
    $sumSquaresX = 0.0
    $sumSquaresY = 0.0

    for ($index = 0; $index -lt $X.Length; $index += 1) {
        $dx = $X[$index] - $meanX
        $dy = $Y[$index] - $meanY
        $numerator += $dx * $dy
        $sumSquaresX += $dx * $dx
        $sumSquaresY += $dy * $dy
    }

    $denominator = [math]::Sqrt($sumSquaresX * $sumSquaresY)
    if ($denominator -eq 0) {
        return [double]::NaN
    }

    return $numerator / $denominator
}

function Get-SpearmanCorrelation([double[]]$X, [double[]]$Y) {
    if ($X.Length -lt 2 -or $Y.Length -lt 2) {
        return [double]::NaN
    }

    $rankX = Get-Ranks $X
    $rankY = Get-Ranks $Y
    return Get-PearsonCorrelation $rankX $rankY
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
        if ($visited.ContainsKey($nodeId)) {
            continue
        }

        $queue = New-Object 'System.Collections.Generic.Queue[string]'
        $queue.Enqueue($nodeId)
        $visited[$nodeId] = $true
        $componentSize = 0

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

        if ($componentSize -gt $largestComponentSize) {
            $largestComponentSize = $componentSize
        }
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

    $unionRetainedEdgeCount = $edgeSupportA.Count + $edgeSupportB.Count - $sharedRetainedEdgeCount
    $conditionalEdgeJaccard = if ($unionRetainedEdgeCount -eq 0) { 0.0 } else { $sharedRetainedEdgeCount / [double]$unionRetainedEdgeCount }
    $weightedSpearman = if ($sharedRetainedEdgeCount -ge 2) { Get-SpearmanCorrelation $weightA $weightB } else { [double]::NaN }

    $row = [ordered]@{
        unit_type_a               = $GraphA.unit_type
        unit_id_a                 = $GraphA.unit_id
        unit_type_b               = $GraphB.unit_type
        unit_id_b                 = $GraphB.unit_id
        n_nodes_a                 = $GraphA.node_ids.Count
        n_nodes_b                 = $GraphB.node_ids.Count
        shared_node_count         = $sharedNodeCount
        union_node_count          = $unionNodeCount
        node_jaccard              = Format-Number $nodeJaccard
        inclusion_a_to_b          = Format-Number $inclusionAtoB
        inclusion_b_to_a          = Format-Number $inclusionBtoA
        shared_edge_support_a     = $edgeSupportA.Count
        shared_edge_support_b     = $edgeSupportB.Count
        shared_retained_edge_count= $sharedRetainedEdgeCount
        union_retained_edge_count = $unionRetainedEdgeCount
        conditional_edge_jaccard  = Format-Number $conditionalEdgeJaccard
        weighted_spearman         = Format-Number $weightedSpearman
    }

    foreach ($key in $ExtraFields.Keys) {
        $row[$key] = $ExtraFields[$key]
    }

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
$pooledCutoffsPath = Join-Path $graphsSparseDirectory '07_pooled_reference_cutoffs.csv'
$allTracksEdgesPath = Join-Path $graphsSparseDirectory '07_pooled_reference_sparse_graphs_all_tracks.csv'
$sectionsEdgesPath = Join-Path $graphsSparseDirectory '07_pooled_reference_sparse_graphs_sections.csv'
$tracksEdgesPath = Join-Path $graphsSparseDirectory '07_pooled_reference_sparse_graphs_tracks.csv'
$programmesEdgesPath = Join-Path $graphsSparseDirectory '07_pooled_reference_sparse_graphs_programmes.csv'
$programmeYearsEdgesPath = Join-Path $graphsSparseDirectory '07_pooled_reference_sparse_graphs_programme_years.csv'

foreach ($requiredPath in @(
    $selectionPath,
    $harmonizedDatasetPath,
    $pooledCutoffsPath,
    $allTracksEdgesPath,
    $sectionsEdgesPath,
    $tracksEdgesPath,
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
$progressionPath = Join-Path $outputDirectory '09_programme_year_progression_overlap.csv'
$tracksOverlapPath = Join-Path $outputDirectory '09_overlap_matrix_tracks.csv'
$sectionsOverlapPath = Join-Path $outputDirectory '09_overlap_matrix_sections.csv'
$programmesOverlapPath = Join-Path $outputDirectory '09_overlap_matrix_programmes.csv'
$programmeYearsOverlapPath = Join-Path $outputDirectory '09_overlap_matrix_programme_years.csv'
$pooledComparisonPath = Join-Path $outputDirectory '09_overlap_to_pooled.csv'
$summaryPath = Join-Path $outputDirectory '09_descriptive_atlas_summary.csv'

$selectionRecord = Import-Csv -LiteralPath $selectionPath | Select-Object -First 1
$selectedRepresentationFamily = $selectionRecord.selected_representation_family
$selectedSourceRepresentation = $selectionRecord.selected_source_representation

$selectedCutoff = (Import-Csv -LiteralPath $pooledCutoffsPath |
    Where-Object { $_.representation_family -eq $selectedRepresentationFamily } |
    Select-Object -First 1).selected_threshold

if (-not $selectedCutoff) {
    throw "Selected representation family '$selectedRepresentationFamily' was not found in Step 7 pooled cutoffs."
}

$referenceThreshold = To-Double $selectedCutoff
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
$allTracksMembership = New-StringSet

foreach ($row in $selectedRows) {
    $nodeNameById[$row.harmonized_skill_id] = $row.harmonized_name
    $null = $allTracksMembership.Add($row.harmonized_skill_id)
    Add-ToMembership -Map $sectionMembership -Key $row.section -NodeId $row.harmonized_skill_id
    Add-ToMembership -Map $trackMembership -Key $row.edu_type -NodeId $row.harmonized_skill_id
    Add-ToMembership -Map $programmeMembership -Key $row.programme -NodeId $row.harmonized_skill_id
    Add-ToMembership -Map $programmeYearMembership -Key ("{0}__{1}" -f $row.programme, $row.year) -NodeId $row.harmonized_skill_id
}

$graphsByType = @{
    all_tracks     = @{ 'ALL_TRACKS' = (New-Graph -UnitType 'all_tracks' -UnitId 'ALL_TRACKS' -RepresentationFamily $selectedRepresentationFamily -SourceRepresentation $selectedSourceRepresentation -ReferenceThreshold $referenceThreshold -NodeSet $allTracksMembership) }
    section        = @{}
    track          = @{}
    programme      = @{}
    programme_year = @{}
}

foreach ($unitId in $sectionMembership.Keys) {
    $graphsByType.section[$unitId] = New-Graph -UnitType 'section' -UnitId $unitId -RepresentationFamily $selectedRepresentationFamily -SourceRepresentation $selectedSourceRepresentation -ReferenceThreshold $referenceThreshold -NodeSet $sectionMembership[$unitId]
}
foreach ($unitId in $trackMembership.Keys) {
    $graphsByType.track[$unitId] = New-Graph -UnitType 'track' -UnitId $unitId -RepresentationFamily $selectedRepresentationFamily -SourceRepresentation $selectedSourceRepresentation -ReferenceThreshold $referenceThreshold -NodeSet $trackMembership[$unitId]
}
foreach ($unitId in $programmeMembership.Keys) {
    $graphsByType.programme[$unitId] = New-Graph -UnitType 'programme' -UnitId $unitId -RepresentationFamily $selectedRepresentationFamily -SourceRepresentation $selectedSourceRepresentation -ReferenceThreshold $referenceThreshold -NodeSet $programmeMembership[$unitId]
}
foreach ($unitId in $programmeYearMembership.Keys) {
    $graphsByType.programme_year[$unitId] = New-Graph -UnitType 'programme_year' -UnitId $unitId -RepresentationFamily $selectedRepresentationFamily -SourceRepresentation $selectedSourceRepresentation -ReferenceThreshold $referenceThreshold -NodeSet $programmeYearMembership[$unitId]
}

function Import-SelectedEdges([string]$Path, [hashtable]$GraphMap, [string]$SelectedRepresentationFamily) {
    Import-Csv -LiteralPath $Path |
        Where-Object { $_.representation_family -eq $SelectedRepresentationFamily } |
        ForEach-Object {
            if ($GraphMap.ContainsKey($_.unit_id)) {
                Add-EdgeToGraph -Graph $GraphMap[$_.unit_id] -NodeA $_.harmonized_skill_id_1 -NodeB $_.harmonized_skill_id_2 -Weight (To-Double $_.edge_weight)
            }
        }
}

Import-SelectedEdges -Path $allTracksEdgesPath -GraphMap $graphsByType.all_tracks -SelectedRepresentationFamily $selectedRepresentationFamily
Import-SelectedEdges -Path $sectionsEdgesPath -GraphMap $graphsByType.section -SelectedRepresentationFamily $selectedRepresentationFamily
Import-SelectedEdges -Path $tracksEdgesPath -GraphMap $graphsByType.track -SelectedRepresentationFamily $selectedRepresentationFamily
Import-SelectedEdges -Path $programmesEdgesPath -GraphMap $graphsByType.programme -SelectedRepresentationFamily $selectedRepresentationFamily
Import-SelectedEdges -Path $programmeYearsEdgesPath -GraphMap $graphsByType.programme_year -SelectedRepresentationFamily $selectedRepresentationFamily

$graphProfileRows = @()
foreach ($unitType in @('all_tracks', 'section', 'track', 'programme', 'programme_year')) {
    foreach ($graph in ($graphsByType[$unitType].Values | Sort-Object unit_id)) {
        $profile = Get-GraphProfile $graph
        $graphProfileRows += [pscustomobject]@{
            representation_family   = $selectedRepresentationFamily
            source_representation   = $selectedSourceRepresentation
            unit_type               = $graph.unit_type
            unit_id                 = $graph.unit_id
            reference_threshold     = Format-Number $graph.reference_threshold
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

    foreach ($nodeId in $programmeNodeSet) {
        $recurrenceBySkill[$nodeId] = 0
    }

    foreach ($programmeYearGraph in $programmeYears) {
        foreach ($nodeId in $programmeYearGraph.node_ids) {
            $recurrenceBySkill[$nodeId] += 1
        }
    }

    $recurrentSkillCount = @($recurrenceBySkill.GetEnumerator() | Where-Object { $_.Value -ge 2 }).Count
    $meanRecurrenceCount = if ($programmeNodeSet.Count -eq 0) { 0.0 } else { (($recurrenceBySkill.Values | Measure-Object -Average).Average) }
    $recurrentSkillShare = if ($programmeNodeSet.Count -eq 0) { 0.0 } else { $recurrentSkillCount / [double]$programmeNodeSet.Count }
    $recurrenceSummaryRows += [pscustomobject]@{
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

$progressionRows = @()
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
            $progressionRows += [pscustomobject]@{
                programme_id                = $programmeId
                year_a                      = $yearA
                year_b                      = $yearB
                year_gap                    = $yearB - $yearA
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

$pooledGraph = $graphsByType.all_tracks['ALL_TRACKS']
$pooledComparisonRows = @()
foreach ($unitType in @('section', 'track', 'programme', 'programme_year')) {
    foreach ($graph in ($graphsByType[$unitType].Values | Sort-Object unit_id)) {
        $pooledComparisonRows += Get-OverlapRow -GraphA $graph -GraphB $pooledGraph -ExtraFields ([ordered]@{
            comparison_scope = 'to_pooled'
        })
    }
}

$summaryRows = @(
    [pscustomobject]@{ summary_key = 'selected_representation_family'; summary_value = $selectedRepresentationFamily }
    [pscustomobject]@{ summary_key = 'selected_source_representation'; summary_value = $selectedSourceRepresentation }
    [pscustomobject]@{ summary_key = 'reference_threshold'; summary_value = Format-Number $referenceThreshold }
    [pscustomobject]@{ summary_key = 'graph_profile_rows'; summary_value = $graphProfileRows.Count }
    [pscustomobject]@{ summary_key = 'programme_recurrence_summary_rows'; summary_value = $recurrenceSummaryRows.Count }
    [pscustomobject]@{ summary_key = 'programme_recurrence_detail_rows'; summary_value = $recurrenceDetailRows.Count }
    [pscustomobject]@{ summary_key = 'programme_year_progression_rows'; summary_value = $progressionRows.Count }
    [pscustomobject]@{ summary_key = 'track_overlap_rows'; summary_value = $trackOverlapRows.Count }
    [pscustomobject]@{ summary_key = 'section_overlap_rows'; summary_value = $sectionOverlapRows.Count }
    [pscustomobject]@{ summary_key = 'programme_overlap_rows'; summary_value = $programmeOverlapRows.Count }
    [pscustomobject]@{ summary_key = 'programme_year_overlap_rows'; summary_value = $programmeYearOverlapRows.Count }
    [pscustomobject]@{ summary_key = 'pooled_comparison_rows'; summary_value = $pooledComparisonRows.Count }
)

$graphProfileRows | Export-Csv -LiteralPath $graphProfilePath -NoTypeInformation -Encoding UTF8
$recurrenceSummaryRows | Export-Csv -LiteralPath $recurrenceSummaryPath -NoTypeInformation -Encoding UTF8
$recurrenceDetailRows | Export-Csv -LiteralPath $recurrenceDetailPath -NoTypeInformation -Encoding UTF8
$progressionRows | Export-Csv -LiteralPath $progressionPath -NoTypeInformation -Encoding UTF8
$trackOverlapRows | Export-Csv -LiteralPath $tracksOverlapPath -NoTypeInformation -Encoding UTF8
$sectionOverlapRows | Export-Csv -LiteralPath $sectionsOverlapPath -NoTypeInformation -Encoding UTF8
$programmeOverlapRows | Export-Csv -LiteralPath $programmesOverlapPath -NoTypeInformation -Encoding UTF8
$programmeYearOverlapRows | Export-Csv -LiteralPath $programmeYearsOverlapPath -NoTypeInformation -Encoding UTF8
$pooledComparisonRows | Export-Csv -LiteralPath $pooledComparisonPath -NoTypeInformation -Encoding UTF8
$summaryRows | Export-Csv -LiteralPath $summaryPath -NoTypeInformation -Encoding UTF8

Write-Host "Step 9 outputs written to $outputDirectory"
Write-Host "Selected graph family: $selectedRepresentationFamily"
