[CmdletBinding()]
param(
    [string]$ReviewTemplatePath = "",
    [string]$TextInstancesPath = "",
    [string]$CleanSkillsJsonPath = "",
    [string]$TextInstanceMappingOutputPath = "",
    [string]$TextInstancesHarmonizedOutputPath = "",
    [string]$HarmonizedJsonOutputPath = "",
    [string]$HarmonizedCsvOutputPath = "",
    [string]$HarmonizationSummaryOutputPath = "",
    [string]$HarmonizedGroupsSummaryOutputPath = "",
    [string]$NameSelectionPath = "",
    [string]$ComponentAuditPath = ""
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

function Normalize-ReviewDecision {
    param([string]$Decision)

    if ([string]::IsNullOrWhiteSpace($Decision)) {
        return ""
    }

    return $Decision.Trim().ToLowerInvariant()
}

function Convert-EnumerableToJsonString {
    param([object]$Value)

    return $Value | ConvertTo-Json -Compress -Depth 100
}

function Convert-ToCsvFriendlyObject {
    param([psobject]$InputObject)

    $row = [ordered]@{}
    foreach ($property in $InputObject.PSObject.Properties) {
        $value = $property.Value

        if ($null -eq $value) {
            $row[$property.Name] = $null
            continue
        }

        if (
            $value -is [string] -or
            $value -is [bool] -or
            $value -is [byte] -or
            $value -is [sbyte] -or
            $value -is [int16] -or
            $value -is [int32] -or
            $value -is [int64] -or
            $value -is [uint16] -or
            $value -is [uint32] -or
            $value -is [uint64] -or
            $value -is [single] -or
            $value -is [double] -or
            $value -is [decimal]
        ) {
            $row[$property.Name] = $value
            continue
        }

        $row[$property.Name] = Convert-EnumerableToJsonString -Value $value
    }

    return [pscustomobject]$row
}

function Get-OrdinalSortKey {
    param([string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    return -join ($Text.ToCharArray() | ForEach-Object { "{0:D5}" -f [int][char]$_ })
}

function Get-PreferredHarmonizedName {
    param([object[]]$MemberEntries)

    $nameStats = $MemberEntries |
        Group-Object old_name |
        ForEach-Object {
            $first = $_.Group[0]
            [pscustomobject]@{
                old_name = $first.old_name
                total_occurrences = (@($_.Group | Measure-Object -Property n_occurrences -Sum).Sum)
                text_instances = $_.Count
            }
        } |
        Sort-Object `
            @{ Expression = 'total_occurrences'; Descending = $true }, `
            @{ Expression = 'text_instances'; Descending = $true }, `
            @{ Expression = { Get-OrdinalSortKey -Text $_.old_name }; Ascending = $true }

    return [pscustomobject]@{
        chosen_name = $nameStats[0].old_name
        rationale = "most_frequent_label_then_lexicographic_tiebreak"
    }
}

$scriptRoot = Split-Path -Parent $PSCommandPath

$ReviewTemplatePath = Resolve-DefaultPath -ProvidedPath $ReviewTemplatePath -FallbackRelativePath "..\outputs\review\03_review_template_textual_instances.csv" -ScriptRoot $scriptRoot
$TextInstancesPath = Resolve-DefaultPath -ProvidedPath $TextInstancesPath -FallbackRelativePath "..\data_processed\01_unique_textual_instances_vectors.csv" -ScriptRoot $scriptRoot
$CleanSkillsJsonPath = Resolve-DefaultPath -ProvidedPath $CleanSkillsJsonPath -FallbackRelativePath "..\data_processed\01_skills_occurrence_clean.json" -ScriptRoot $scriptRoot
$TextInstanceMappingOutputPath = Resolve-DefaultPath -ProvidedPath $TextInstanceMappingOutputPath -FallbackRelativePath "..\data_processed\04_textual_instances_harmonization_mapping.csv" -ScriptRoot $scriptRoot
$TextInstancesHarmonizedOutputPath = Resolve-DefaultPath -ProvidedPath $TextInstancesHarmonizedOutputPath -FallbackRelativePath "..\data_processed\04_textual_instances_harmonized.csv" -ScriptRoot $scriptRoot
$HarmonizedJsonOutputPath = Resolve-DefaultPath -ProvidedPath $HarmonizedJsonOutputPath -FallbackRelativePath "..\data_processed\04_skills_harmonized.json" -ScriptRoot $scriptRoot
$HarmonizedCsvOutputPath = Resolve-DefaultPath -ProvidedPath $HarmonizedCsvOutputPath -FallbackRelativePath "..\data_processed\04_skills_harmonized.csv" -ScriptRoot $scriptRoot
$HarmonizationSummaryOutputPath = Resolve-DefaultPath -ProvidedPath $HarmonizationSummaryOutputPath -FallbackRelativePath "..\outputs\harmonization\04_harmonization_summary.csv" -ScriptRoot $scriptRoot
$HarmonizedGroupsSummaryOutputPath = Resolve-DefaultPath -ProvidedPath $HarmonizedGroupsSummaryOutputPath -FallbackRelativePath "..\outputs\harmonization\04_harmonized_groups_summary.csv" -ScriptRoot $scriptRoot
$NameSelectionPath = Resolve-DefaultPath -ProvidedPath $NameSelectionPath -FallbackRelativePath "..\outputs\harmonization\04_harmonized_name_selection.csv" -ScriptRoot $scriptRoot
$ComponentAuditPath = Resolve-DefaultPath -ProvidedPath $ComponentAuditPath -FallbackRelativePath "..\outputs\harmonization\04_component_merge_audit.csv" -ScriptRoot $scriptRoot

foreach ($requiredInputPath in @($ReviewTemplatePath, $TextInstancesPath, $CleanSkillsJsonPath)) {
    if (-not (Test-Path -LiteralPath $requiredInputPath)) {
        throw "Required input file not found: $requiredInputPath"
    }
}

foreach ($outputPath in @(
    $TextInstanceMappingOutputPath,
    $TextInstancesHarmonizedOutputPath,
    $HarmonizedJsonOutputPath,
    $HarmonizedCsvOutputPath,
    $HarmonizationSummaryOutputPath,
    $HarmonizedGroupsSummaryOutputPath,
    $NameSelectionPath,
    $ComponentAuditPath
)) {
    $directory = Split-Path -Parent $outputPath
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

$textInstancesRaw = Import-Csv -LiteralPath $TextInstancesPath |
    Sort-Object -Property @{ Expression = { Get-OrdinalSortKey -Text ([string]$_.text_instance_id) }; Ascending = $true }
if ($textInstancesRaw.Count -eq 0) {
    throw "The textual-instance input is empty: $TextInstancesPath"
}

$idToTextInstance = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
$textInstanceEntries = New-Object System.Collections.Generic.List[object]

foreach ($row in $textInstancesRaw) {
    $textInstanceId = [string]$row.text_instance_id
    if ($idToTextInstance.ContainsKey($textInstanceId)) {
        throw "Duplicate text_instance_id found in input: $textInstanceId"
    }

    $entry = [pscustomobject]@{
        text_instance_id = $textInstanceId
        old_name = [string]$row.name
        old_description = [string]$row.description
        n_occurrences = [int]$row.n_occurrences
        requires_manual_validation = ([string]$row.requires_manual_validation -eq "true")
        name_vector = $row.name_vector
        description_vector = $row.description_vector
    }

    $idToTextInstance.Add($textInstanceId, $entry)
    $textInstanceEntries.Add($entry) | Out-Null
}

$reviewRows = Import-Csv -LiteralPath $ReviewTemplatePath
$equivalentEdges = New-Object System.Collections.Generic.List[object]
$equivalentCount = 0
$notEquivalentCount = 0
$uncertainCount = 0
$blankDecisionCount = 0

foreach ($row in $reviewRows) {
    $decision = Normalize-ReviewDecision -Decision $row.review_decision

    switch ($decision) {
        "" {
            $blankDecisionCount++
            continue
        }
        "equivalent" {
            $equivalentCount++
            if (-not $idToTextInstance.ContainsKey($row.text_instance_id_1)) {
                throw "Unknown text_instance_id_1 in review template: $($row.text_instance_id_1)"
            }
            if (-not $idToTextInstance.ContainsKey($row.text_instance_id_2)) {
                throw "Unknown text_instance_id_2 in review template: $($row.text_instance_id_2)"
            }

            $equivalentEdges.Add([pscustomobject]@{
                text_instance_id_1 = $row.text_instance_id_1
                text_instance_id_2 = $row.text_instance_id_2
            }) | Out-Null
            continue
        }
        "not_equivalent" {
            $notEquivalentCount++
            continue
        }
        "uncertain" {
            $uncertainCount++
            continue
        }
        default {
            throw "Unexpected review_decision value '$($row.review_decision)' in $ReviewTemplatePath"
        }
    }
}

$parent = @{}
$rank = @{}
foreach ($entry in $textInstanceEntries) {
    $parent[$entry.text_instance_id] = $entry.text_instance_id
    $rank[$entry.text_instance_id] = 0
}

function Find-Root {
    param([string]$NodeId)

    if ($parent[$NodeId] -cne $NodeId) {
        $parent[$NodeId] = Find-Root -NodeId $parent[$NodeId]
    }

    return $parent[$NodeId]
}

function Union-Nodes {
    param(
        [string]$LeftId,
        [string]$RightId
    )

    $leftRoot = Find-Root -NodeId $LeftId
    $rightRoot = Find-Root -NodeId $RightId

    if ($leftRoot -ceq $rightRoot) {
        return
    }

    if ($rank[$leftRoot] -lt $rank[$rightRoot]) {
        $parent[$leftRoot] = $rightRoot
        return
    }

    if ($rank[$leftRoot] -gt $rank[$rightRoot]) {
        $parent[$rightRoot] = $leftRoot
        return
    }

    $parent[$rightRoot] = $leftRoot
    $rank[$leftRoot] = [int]$rank[$leftRoot] + 1
}

foreach ($edge in $equivalentEdges) {
    Union-Nodes -LeftId $edge.text_instance_id_1 -RightId $edge.text_instance_id_2
}

$groupsByRoot = @{}
foreach ($entry in $textInstanceEntries) {
    $root = Find-Root -NodeId $entry.text_instance_id
    if (-not $groupsByRoot.ContainsKey($root)) {
        $groupsByRoot[$root] = New-Object System.Collections.Generic.List[string]
    }
    $groupsByRoot[$root].Add($entry.text_instance_id) | Out-Null
}

$orderedGroups = $groupsByRoot.GetEnumerator() |
    ForEach-Object {
        $memberIds = @($_.Value | Sort-Object)
        [pscustomobject]@{
            member_ids = $memberIds
            sort_key = $memberIds[0]
        }
    } |
    Sort-Object -Property sort_key

$existingNameSelections = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
if (Test-Path -LiteralPath $NameSelectionPath) {
    foreach ($row in Import-Csv -LiteralPath $NameSelectionPath) {
        if ([string]::IsNullOrWhiteSpace($row.harmonized_skill_id)) {
            continue
        }

        $existingNameSelections[$row.harmonized_skill_id] = $row
    }
}

$mappingRows = New-Object System.Collections.Generic.List[object]
$textInstancesHarmonizedRows = New-Object System.Collections.Generic.List[object]
$groupSummaryRows = New-Object System.Collections.Generic.List[object]
$nameSelectionRows = New-Object System.Collections.Generic.List[object]
$componentAuditRows = New-Object System.Collections.Generic.List[object]

$textInstanceIdToMapping = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
$multiTextInstanceGroupCount = 0

for ($groupIndex = 0; $groupIndex -lt $orderedGroups.Count; $groupIndex++) {
    $harmonizedSkillId = "HSK_{0:D4}" -f ($groupIndex + 1)
    $memberIds = $orderedGroups[$groupIndex].member_ids
    $memberEntries = @($memberIds | ForEach-Object { $idToTextInstance[$_] })
    $candidateNames = @($memberEntries.old_name | Sort-Object -Unique)
    $candidateDescriptions = @($memberEntries.old_description | Sort-Object -Unique)
    $selectionRule = Get-PreferredHarmonizedName -MemberEntries $memberEntries

    $chosenHarmonizedName = $selectionRule.chosen_name
    $selectionRationale = $selectionRule.rationale
    if ($memberIds.Count -gt 1 -and $existingNameSelections.ContainsKey($harmonizedSkillId)) {
        $selectionRow = $existingNameSelections[$harmonizedSkillId]
        if (
            -not [string]::IsNullOrWhiteSpace($selectionRow.chosen_harmonized_name) -and
            ($candidateNames -contains $selectionRow.chosen_harmonized_name)
        ) {
            $chosenHarmonizedName = $selectionRow.chosen_harmonized_name
            $selectionRationale = if ([string]::IsNullOrWhiteSpace($selectionRow.selection_rationale)) {
                "manual_override"
            } else {
                $selectionRow.selection_rationale
            }
        }
    }

    if ($memberIds.Count -gt 1) {
        $multiTextInstanceGroupCount++
        $nameSelectionRows.Add([pscustomobject]@{
            harmonized_skill_id = $harmonizedSkillId
            candidate_names = Convert-EnumerableToJsonString -Value $candidateNames
            chosen_harmonized_name = $chosenHarmonizedName
            selection_rationale = $selectionRationale
        }) | Out-Null
    }

    if ($memberIds.Count -gt 1) {
        $componentAuditRows.Add([pscustomobject]@{
            harmonized_skill_id = $harmonizedSkillId
            n_text_instances = $memberIds.Count
            n_unique_names = $candidateNames.Count
            n_unique_descriptions = $candidateDescriptions.Count
            member_text_instance_ids = Convert-EnumerableToJsonString -Value $memberIds
            member_names = Convert-EnumerableToJsonString -Value $candidateNames
            member_descriptions = Convert-EnumerableToJsonString -Value $candidateDescriptions
            requires_secondary_validation = if ($candidateNames.Count -gt 1) { "true" } else { "false" }
            audit_note = if ($candidateNames.Count -gt 1) { "Connected-component merge spans multiple labels; validate chain merge before freezing." } else { "Single-label merge component." }
        }) | Out-Null
    }

    $groupSummaryRows.Add([pscustomobject]@{
        harmonized_skill_id = $harmonizedSkillId
        harmonized_name = $chosenHarmonizedName
        n_text_instances = $memberIds.Count
        n_occurrences_in_group = (@($memberEntries | Measure-Object -Property n_occurrences -Sum).Sum)
        member_text_instance_ids = Convert-EnumerableToJsonString -Value $memberIds
        member_old_names = Convert-EnumerableToJsonString -Value $candidateNames
        member_old_descriptions = Convert-EnumerableToJsonString -Value $candidateDescriptions
    }) | Out-Null

    foreach ($memberEntry in $memberEntries) {
        $nameChanged = $memberEntry.old_name -cne $chosenHarmonizedName
        $harmonizationStatus = if ($memberIds.Count -eq 1) {
            "singleton_no_merge"
        } elseif ($nameChanged) {
            "review_validated_merge_name_changed"
        } else {
            "review_validated_merge_name_retained"
        }

        $mappingRow = [pscustomobject]@{
            text_instance_id = $memberEntry.text_instance_id
            old_name = $memberEntry.old_name
            old_description = $memberEntry.old_description
            harmonized_skill_id = $harmonizedSkillId
            harmonized_name = $chosenHarmonizedName
            name_changed = $nameChanged
            harmonization_status = $harmonizationStatus
            requires_manual_validation = $memberEntry.requires_manual_validation
            n_occurrences = $memberEntry.n_occurrences
        }

        $mappingRows.Add($mappingRow) | Out-Null
        $textInstanceIdToMapping[$memberEntry.text_instance_id] = $mappingRow

        $textInstancesHarmonizedRows.Add([pscustomobject]@{
            text_instance_id = $memberEntry.text_instance_id
            old_name = $memberEntry.old_name
            old_description = $memberEntry.old_description
            harmonized_skill_id = $harmonizedSkillId
            harmonized_name = $chosenHarmonizedName
            name_changed = $nameChanged
            harmonization_status = $harmonizationStatus
            requires_manual_validation = $memberEntry.requires_manual_validation
            n_occurrences = $memberEntry.n_occurrences
            name_vector = $memberEntry.name_vector
            description_vector = $memberEntry.description_vector
        }) | Out-Null
    }
}

$mappingRows = @($mappingRows | Sort-Object -Property text_instance_id)
$textInstancesHarmonizedRows = @($textInstancesHarmonizedRows | Sort-Object -Property text_instance_id)
$groupSummaryRows = @($groupSummaryRows | Sort-Object -Property harmonized_skill_id)
$componentAuditRows = @($componentAuditRows | Sort-Object -Property harmonized_skill_id)

$mappingRows | Export-Csv -LiteralPath $TextInstanceMappingOutputPath -NoTypeInformation -Encoding UTF8
$textInstancesHarmonizedRows | Export-Csv -LiteralPath $TextInstancesHarmonizedOutputPath -NoTypeInformation -Encoding UTF8
$groupSummaryRows | Export-Csv -LiteralPath $HarmonizedGroupsSummaryOutputPath -NoTypeInformation -Encoding UTF8

if ($nameSelectionRows.Count -gt 0) {
    $nameSelectionRows | Export-Csv -LiteralPath $NameSelectionPath -NoTypeInformation -Encoding UTF8
} else {
    "harmonized_skill_id,candidate_names,chosen_harmonized_name,selection_rationale" | Set-Content -LiteralPath $NameSelectionPath -Encoding UTF8
}

if ($componentAuditRows.Count -gt 0) {
    $componentAuditRows | Export-Csv -LiteralPath $ComponentAuditPath -NoTypeInformation -Encoding UTF8
} else {
    "harmonized_skill_id,n_text_instances,n_unique_names,n_unique_descriptions,member_text_instance_ids,member_names,member_descriptions,requires_secondary_validation,audit_note" | Set-Content -LiteralPath $ComponentAuditPath -Encoding UTF8
}

$cleanedSkillRecords = Get-Content -LiteralPath $CleanSkillsJsonPath -Raw | ConvertFrom-Json
$harmonizedRecords = New-Object System.Collections.Generic.List[object]
$harmonizedRecordsCsv = New-Object System.Collections.Generic.List[object]
$fullRecordsNameChangedCount = 0

foreach ($record in $cleanedSkillRecords) {
    $textInstanceId = [string]$record.text_instance_id
    if (-not $textInstanceIdToMapping.ContainsKey($textInstanceId)) {
        throw "No harmonization mapping found for text_instance_id '$textInstanceId'"
    }

    $mapping = $textInstanceIdToMapping[$textInstanceId]
    if ([bool]$mapping.name_changed) {
        $fullRecordsNameChangedCount++
    }

    $harmonizedRecord = [ordered]@{
        occurrence_id = $record.occurrence_id
        source_record_index = $record.source_record_index
        occurrence_index_within_record = $record.occurrence_index_within_record
        skill_id = $record.skill_id
        text_instance_id = $textInstanceId
        old_name = [string]$record.name
        old_description = [string]$record.description
        harmonized_name = $mapping.harmonized_name
        name_changed = [bool]$mapping.name_changed
        harmonized_skill_id = $mapping.harmonized_skill_id
    }

    foreach ($property in $record.PSObject.Properties) {
        if (-not $harmonizedRecord.Contains($property.Name)) {
            $harmonizedRecord[$property.Name] = $property.Value
        }
    }

    $harmonizedRecordObject = [pscustomobject]$harmonizedRecord
    $harmonizedRecords.Add($harmonizedRecordObject) | Out-Null
    $harmonizedRecordsCsv.Add((Convert-ToCsvFriendlyObject -InputObject $harmonizedRecordObject)) | Out-Null
}

$harmonizedRecords | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $HarmonizedJsonOutputPath -Encoding UTF8
$harmonizedRecordsCsv | Export-Csv -LiteralPath $HarmonizedCsvOutputPath -NoTypeInformation -Encoding UTF8

$textInstancesNameChangedCount = @($mappingRows | Where-Object { $_.name_changed }).Count
$secondaryValidationComponentCount = @($componentAuditRows | Where-Object { $_.requires_secondary_validation -eq "true" }).Count

$summaryRows = @(
    [pscustomobject]@{ summary_metric = "reviewed_pairs_equivalent"; value = $equivalentCount }
    [pscustomobject]@{ summary_metric = "reviewed_pairs_not_equivalent"; value = $notEquivalentCount }
    [pscustomobject]@{ summary_metric = "reviewed_pairs_uncertain"; value = $uncertainCount }
    [pscustomobject]@{ summary_metric = "review_pairs_without_decision"; value = $blankDecisionCount }
    [pscustomobject]@{ summary_metric = "total_text_instances_before_harmonization"; value = $textInstanceEntries.Count }
    [pscustomobject]@{ summary_metric = "total_harmonized_groups"; value = $orderedGroups.Count }
    [pscustomobject]@{ summary_metric = "multi_text_instance_harmonized_groups"; value = $multiTextInstanceGroupCount }
    [pscustomobject]@{ summary_metric = "multi_name_components_requiring_secondary_validation"; value = $secondaryValidationComponentCount }
    [pscustomobject]@{ summary_metric = "text_instances_name_changed"; value = $textInstancesNameChangedCount }
    [pscustomobject]@{ summary_metric = "full_skill_records_name_changed"; value = $fullRecordsNameChangedCount }
    [pscustomobject]@{ summary_metric = "harmonized_name_selection_rule"; value = "most_frequent_label_then_lexicographic_tiebreak_with_optional_manual_override" }
    [pscustomobject]@{ summary_metric = "harmonization_mode"; value = if ($equivalentCount -eq 0) { "no_merge_baseline" } else { "review_validated_merges_only" } }
)

$summaryRows | Export-Csv -LiteralPath $HarmonizationSummaryOutputPath -NoTypeInformation -Encoding UTF8

Write-Host ("Textual instances loaded: {0}" -f $textInstanceEntries.Count)
Write-Host ("Reviewed pairs: equivalent={0}, not_equivalent={1}, uncertain={2}, blank={3}" -f $equivalentCount, $notEquivalentCount, $uncertainCount, $blankDecisionCount)
Write-Host ("Harmonized groups created: {0}" -f $orderedGroups.Count)
Write-Host ("Groups with more than one textual instance: {0}" -f $multiTextInstanceGroupCount)
Write-Host ("Textual instances renamed: {0}" -f $textInstancesNameChangedCount)
Write-Host ("Full skill records renamed: {0}" -f $fullRecordsNameChangedCount)
