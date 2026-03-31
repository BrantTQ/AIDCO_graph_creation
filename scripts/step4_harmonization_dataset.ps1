[CmdletBinding()]
param(
    [string]$ReviewTemplatePath = "",
    [string]$UniqueSkillsPath = "",
    [string]$CleanSkillsJsonPath = "",
    [string]$UniqueSkillsMappingOutputPath = "",
    [string]$UniqueSkillsHarmonizedOutputPath = "",
    [string]$HarmonizedJsonOutputPath = "",
    [string]$HarmonizedCsvOutputPath = "",
    [string]$HarmonizationSummaryOutputPath = "",
    [string]$HarmonizedGroupsSummaryOutputPath = "",
    [string]$NameSelectionPath = ""
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

$scriptRoot = Split-Path -Parent $PSCommandPath

$ReviewTemplatePath = Resolve-DefaultPath -ProvidedPath $ReviewTemplatePath -FallbackRelativePath "..\outputs\review\03_review_template_unique_skills.csv" -ScriptRoot $scriptRoot
$UniqueSkillsPath = Resolve-DefaultPath -ProvidedPath $UniqueSkillsPath -FallbackRelativePath "..\data_processed\01_unique_skills_vectors.csv" -ScriptRoot $scriptRoot
$CleanSkillsJsonPath = Resolve-DefaultPath -ProvidedPath $CleanSkillsJsonPath -FallbackRelativePath "..\data_processed\01_skills_occurrence_clean.json" -ScriptRoot $scriptRoot
$UniqueSkillsMappingOutputPath = Resolve-DefaultPath -ProvidedPath $UniqueSkillsMappingOutputPath -FallbackRelativePath "..\data_processed\04_unique_skills_harmonization_mapping.csv" -ScriptRoot $scriptRoot
$UniqueSkillsHarmonizedOutputPath = Resolve-DefaultPath -ProvidedPath $UniqueSkillsHarmonizedOutputPath -FallbackRelativePath "..\data_processed\04_unique_skills_harmonized.csv" -ScriptRoot $scriptRoot
$HarmonizedJsonOutputPath = Resolve-DefaultPath -ProvidedPath $HarmonizedJsonOutputPath -FallbackRelativePath "..\data_processed\04_skills_harmonized.json" -ScriptRoot $scriptRoot
$HarmonizedCsvOutputPath = Resolve-DefaultPath -ProvidedPath $HarmonizedCsvOutputPath -FallbackRelativePath "..\data_processed\04_skills_harmonized.csv" -ScriptRoot $scriptRoot
$HarmonizationSummaryOutputPath = Resolve-DefaultPath -ProvidedPath $HarmonizationSummaryOutputPath -FallbackRelativePath "..\outputs\harmonization\04_harmonization_summary.csv" -ScriptRoot $scriptRoot
$HarmonizedGroupsSummaryOutputPath = Resolve-DefaultPath -ProvidedPath $HarmonizedGroupsSummaryOutputPath -FallbackRelativePath "..\outputs\harmonization\04_harmonized_groups_summary.csv" -ScriptRoot $scriptRoot
$NameSelectionPath = Resolve-DefaultPath -ProvidedPath $NameSelectionPath -FallbackRelativePath "..\outputs\harmonization\04_harmonized_name_selection.csv" -ScriptRoot $scriptRoot

foreach ($requiredInputPath in @($ReviewTemplatePath, $UniqueSkillsPath, $CleanSkillsJsonPath)) {
    if (-not (Test-Path -LiteralPath $requiredInputPath)) {
        throw "Required input file not found: $requiredInputPath"
    }
}

foreach ($outputPath in @(
    $UniqueSkillsMappingOutputPath,
    $UniqueSkillsHarmonizedOutputPath,
    $HarmonizedJsonOutputPath,
    $HarmonizedCsvOutputPath,
    $HarmonizationSummaryOutputPath,
    $HarmonizedGroupsSummaryOutputPath,
    $NameSelectionPath
)) {
    $directory = Split-Path -Parent $outputPath
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

$uniqueSkillsRaw = Import-Csv -LiteralPath $UniqueSkillsPath |
    Sort-Object -Property @{ Expression = { Get-OrdinalSortKey -Text ([string]$_.name) }; Ascending = $true }
if ($uniqueSkillsRaw.Count -eq 0) {
    throw "The unique-skills input is empty: $UniqueSkillsPath"
}

$nameToUniqueSkill = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
$idToUniqueSkill = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
$uniqueSkillEntries = New-Object System.Collections.Generic.List[object]

for ($index = 0; $index -lt $uniqueSkillsRaw.Count; $index++) {
    $row = $uniqueSkillsRaw[$index]
    $uniqueSkillId = "SK_{0:D4}" -f ($index + 1)
    $oldName = [string]$row.name

    if ($nameToUniqueSkill.ContainsKey($oldName)) {
        throw "Duplicate unique skill name found in input: $oldName"
    }

    $entry = [pscustomobject]@{
        unique_skill_id = $uniqueSkillId
        old_name = $oldName
        name_vector = $row.name_vector
        description_vector = $row.description_vector
    }

    $nameToUniqueSkill.Add($oldName, $entry)
    $idToUniqueSkill.Add($uniqueSkillId, $entry)
    $uniqueSkillEntries.Add($entry) | Out-Null
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
            if (-not $idToUniqueSkill.ContainsKey($row.unique_skill_id_1)) {
                throw "Unknown unique_skill_id_1 in review template: $($row.unique_skill_id_1)"
            }
            if (-not $idToUniqueSkill.ContainsKey($row.unique_skill_id_2)) {
                throw "Unknown unique_skill_id_2 in review template: $($row.unique_skill_id_2)"
            }

            $expectedName1 = $idToUniqueSkill[$row.unique_skill_id_1].old_name
            $expectedName2 = $idToUniqueSkill[$row.unique_skill_id_2].old_name
            if ($row.name_1 -cne $expectedName1) {
                throw "Review template name mismatch for $($row.unique_skill_id_1): expected '$expectedName1' but found '$($row.name_1)'"
            }
            if ($row.name_2 -cne $expectedName2) {
                throw "Review template name mismatch for $($row.unique_skill_id_2): expected '$expectedName2' but found '$($row.name_2)'"
            }

            $equivalentEdges.Add([pscustomobject]@{
                unique_skill_id_1 = $row.unique_skill_id_1
                unique_skill_id_2 = $row.unique_skill_id_2
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
foreach ($entry in $uniqueSkillEntries) {
    $parent[$entry.unique_skill_id] = $entry.unique_skill_id
    $rank[$entry.unique_skill_id] = 0
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
    Union-Nodes -LeftId $edge.unique_skill_id_1 -RightId $edge.unique_skill_id_2
}

$groupsByRoot = @{}
foreach ($entry in $uniqueSkillEntries) {
    $root = Find-Root -NodeId $entry.unique_skill_id
    if (-not $groupsByRoot.ContainsKey($root)) {
        $groupsByRoot[$root] = New-Object System.Collections.Generic.List[string]
    }
    $groupsByRoot[$root].Add($entry.unique_skill_id) | Out-Null
}

$orderedGroups = $groupsByRoot.GetEnumerator() |
    ForEach-Object {
        $memberIds = @($_.Value | Sort-Object)
        [pscustomobject]@{
            member_ids = $memberIds
            sort_key = [int](($memberIds[0] -replace "^SK_", ""))
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
$uniqueSkillsHarmonizedRows = New-Object System.Collections.Generic.List[object]
$groupSummaryRows = New-Object System.Collections.Generic.List[object]
$nameSelectionRows = New-Object System.Collections.Generic.List[object]

$harmonizedSkillIdToName = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
$uniqueSkillIdToMapping = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
$multiSkillGroupCount = 0

for ($groupIndex = 0; $groupIndex -lt $orderedGroups.Count; $groupIndex++) {
    $harmonizedSkillId = "HSK_{0:D4}" -f ($groupIndex + 1)
    $memberIds = $orderedGroups[$groupIndex].member_ids
    $memberEntries = @($memberIds | ForEach-Object { $idToUniqueSkill[$_] })
    $candidateNames = @($memberEntries.old_name | Sort-Object -Unique)

    $defaultChosenName = $candidateNames | Sort-Object | Select-Object -First 1
    $selectionRationale = if ($memberIds.Count -eq 1) {
        "singleton_original_name"
    } else {
        "auto_lexicographic_name"
    }

    $chosenHarmonizedName = $defaultChosenName
    if ($existingNameSelections.ContainsKey($harmonizedSkillId)) {
        $selectionRow = $existingNameSelections[$harmonizedSkillId]
        if (-not [string]::IsNullOrWhiteSpace($selectionRow.chosen_harmonized_name)) {
            $chosenHarmonizedName = $selectionRow.chosen_harmonized_name
            $selectionRationale = if ([string]::IsNullOrWhiteSpace($selectionRow.selection_rationale)) {
                "manual_override"
            } else {
                $selectionRow.selection_rationale
            }
        }
    }

    if ($memberIds.Count -gt 1) {
        $multiSkillGroupCount++
        $nameSelectionRows.Add([pscustomobject]@{
            harmonized_skill_id = $harmonizedSkillId
            candidate_names = Convert-EnumerableToJsonString -Value $candidateNames
            chosen_harmonized_name = $chosenHarmonizedName
            selection_rationale = $selectionRationale
        }) | Out-Null
    }

    $harmonizedSkillIdToName[$harmonizedSkillId] = $chosenHarmonizedName
    $groupSummaryRows.Add([pscustomobject]@{
        harmonized_skill_id = $harmonizedSkillId
        harmonized_name = $chosenHarmonizedName
        n_unique_skills = $memberIds.Count
        member_unique_skill_ids = Convert-EnumerableToJsonString -Value $memberIds
        member_old_names = Convert-EnumerableToJsonString -Value $candidateNames
    }) | Out-Null

    foreach ($memberEntry in $memberEntries) {
        $nameChanged = $memberEntry.old_name -cne $chosenHarmonizedName
        $harmonizationStatus = if ($memberIds.Count -eq 1) {
            "singleton"
        } elseif ($nameChanged) {
            "merged_name_changed"
        } else {
            "merged_name_retained"
        }

        $mappingRow = [pscustomobject]@{
            unique_skill_id = $memberEntry.unique_skill_id
            old_name = $memberEntry.old_name
            harmonized_skill_id = $harmonizedSkillId
            harmonized_name = $chosenHarmonizedName
            name_changed = $nameChanged
            harmonization_status = $harmonizationStatus
        }

        $mappingRows.Add($mappingRow) | Out-Null
        $uniqueSkillIdToMapping[$memberEntry.unique_skill_id] = $mappingRow

        $uniqueSkillsHarmonizedRows.Add([pscustomobject]@{
            unique_skill_id = $memberEntry.unique_skill_id
            old_name = $memberEntry.old_name
            harmonized_skill_id = $harmonizedSkillId
            harmonized_name = $chosenHarmonizedName
            name_changed = $nameChanged
            harmonization_status = $harmonizationStatus
            name_vector = $memberEntry.name_vector
            description_vector = $memberEntry.description_vector
        }) | Out-Null
    }
}

$mappingRows = @($mappingRows | Sort-Object -Property unique_skill_id)
$uniqueSkillsHarmonizedRows = @($uniqueSkillsHarmonizedRows | Sort-Object -Property unique_skill_id)
$groupSummaryRows = @($groupSummaryRows | Sort-Object -Property harmonized_skill_id)

$mappingRows | Export-Csv -LiteralPath $UniqueSkillsMappingOutputPath -NoTypeInformation -Encoding UTF8
$uniqueSkillsHarmonizedRows | Export-Csv -LiteralPath $UniqueSkillsHarmonizedOutputPath -NoTypeInformation -Encoding UTF8
$groupSummaryRows | Export-Csv -LiteralPath $HarmonizedGroupsSummaryOutputPath -NoTypeInformation -Encoding UTF8

if ($nameSelectionRows.Count -gt 0) {
    $nameSelectionRows | Export-Csv -LiteralPath $NameSelectionPath -NoTypeInformation -Encoding UTF8
}

$mappingByName = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
foreach ($row in $mappingRows) {
    $mappingByName.Add($row.old_name, $row)
}

$cleanedSkillRecords = Get-Content -LiteralPath $CleanSkillsJsonPath -Raw | ConvertFrom-Json
$harmonizedRecords = New-Object System.Collections.Generic.List[object]
$harmonizedRecordsCsv = New-Object System.Collections.Generic.List[object]
$fullRecordsNameChangedCount = 0

foreach ($record in $cleanedSkillRecords) {
    $oldName = [string]$record.name
    if (-not $mappingByName.ContainsKey($oldName)) {
        throw "No harmonization mapping found for skill name '$oldName'"
    }

    $mapping = $mappingByName[$oldName]
    if ([bool]$mapping.name_changed) {
        $fullRecordsNameChangedCount++
    }

    $harmonizedRecord = [ordered]@{
        occurrence_id = $record.occurrence_id
        source_record_index = $record.source_record_index
        occurrence_index_within_record = $record.occurrence_index_within_record
        skill_id = $record.skill_id
        old_name = $oldName
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

$uniqueSkillsNameChangedCount = @($mappingRows | Where-Object { $_.name_changed }).Count

$summaryRows = @(
    [pscustomobject]@{ summary_metric = "reviewed_pairs_equivalent"; value = $equivalentCount }
    [pscustomobject]@{ summary_metric = "reviewed_pairs_not_equivalent"; value = $notEquivalentCount }
    [pscustomobject]@{ summary_metric = "reviewed_pairs_uncertain"; value = $uncertainCount }
    [pscustomobject]@{ summary_metric = "review_pairs_without_decision"; value = $blankDecisionCount }
    [pscustomobject]@{ summary_metric = "total_unique_skills_before_harmonization"; value = $uniqueSkillEntries.Count }
    [pscustomobject]@{ summary_metric = "total_harmonized_groups"; value = $orderedGroups.Count }
    [pscustomobject]@{ summary_metric = "multi_skill_harmonized_groups"; value = $multiSkillGroupCount }
    [pscustomobject]@{ summary_metric = "unique_skills_name_changed"; value = $uniqueSkillsNameChangedCount }
    [pscustomobject]@{ summary_metric = "full_skill_records_name_changed"; value = $fullRecordsNameChangedCount }
    [pscustomobject]@{ summary_metric = "harmonized_json_path"; value = $HarmonizedJsonOutputPath }
    [pscustomobject]@{ summary_metric = "harmonized_name_selection_rule"; value = "lexicographic_name_with_optional_manual_override" }
)

$summaryRows | Export-Csv -LiteralPath $HarmonizationSummaryOutputPath -NoTypeInformation -Encoding UTF8

Write-Host ("Unique skills loaded: {0}" -f $uniqueSkillEntries.Count)
Write-Host ("Reviewed pairs: equivalent={0}, not_equivalent={1}, uncertain={2}, blank={3}" -f $equivalentCount, $notEquivalentCount, $uncertainCount, $blankDecisionCount)
Write-Host ("Harmonized groups created: {0}" -f $orderedGroups.Count)
Write-Host ("Groups with more than one unique skill: {0}" -f $multiSkillGroupCount)
Write-Host ("Unique skills renamed: {0}" -f $uniqueSkillsNameChangedCount)
Write-Host ("Full skill records renamed: {0}" -f $fullRecordsNameChangedCount)
