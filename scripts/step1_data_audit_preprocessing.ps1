param(
    [string]$InputPath = (Join-Path $PSScriptRoot "..\all_tracks_embeddings_enriched.json"),
    [string]$ProcessedDir = (Join-Path $PSScriptRoot "..\data_processed"),
    [string]$DiagnosticsDir = (Join-Path $PSScriptRoot "..\outputs\diagnostics")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$expectedFields = @(
    "skill_id",
    "name",
    "description",
    "sections",
    "programmes",
    "year",
    "edu_type",
    "chunk_id",
    "name_vector",
    "description_vector"
)

function Ensure-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Convert-ToArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @($Value)
    }

    return @($Value)
}

function Normalize-Whitespace {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $normalized = $Value.Trim()
    $normalized = [regex]::Replace($normalized, "\s+", " ")

    return $normalized
}

function Normalize-TextField {
    param(
        [AllowNull()][string]$Value,
        [string]$FieldName
    )

    $normalized = Normalize-Whitespace $Value

    if ($null -eq $normalized) {
        return $null
    }

    if ($FieldName -in @("sections", "programmes", "edu_type", "chunk_id")) {
        return $normalized.ToUpperInvariant()
    }

    return $normalized
}

function Parse-ListLikeString {
    param(
        [object]$Value,
        [string]$FieldName
    )

    $items = New-Object System.Collections.Generic.List[string]

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        foreach ($item in $Value) {
            $normalizedItem = Normalize-TextField -Value ([string]$item) -FieldName $FieldName
            if (-not [string]::IsNullOrWhiteSpace($normalizedItem)) {
                $items.Add($normalizedItem)
            }
        }

        return @($items)
    }

    $text = Normalize-Whitespace ([string]$Value)
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }

    if ($text.StartsWith("[") -and $text.EndsWith("]")) {
        try {
            $jsonLike = $text.Replace("'", '"')
            $parsed = ConvertFrom-Json -InputObject $jsonLike
            foreach ($item in (Convert-ToArray $parsed)) {
                $normalizedItem = Normalize-TextField -Value ([string]$item) -FieldName $FieldName
                if (-not [string]::IsNullOrWhiteSpace($normalizedItem)) {
                    $items.Add($normalizedItem)
                }
            }
        }
        catch {
            $normalizedItem = Normalize-TextField -Value $text -FieldName $FieldName
            if (-not [string]::IsNullOrWhiteSpace($normalizedItem)) {
                $items.Add($normalizedItem)
            }
        }

        return @($items)
    }

    $singleItem = Normalize-TextField -Value $text -FieldName $FieldName
    if (-not [string]::IsNullOrWhiteSpace($singleItem)) {
        $items.Add($singleItem)
    }

    return @($items)
}

function Expand-WithBroadcast {
    param(
        [object[]]$Values,
        [int]$TargetLength
    )

    $valuesArray = @(Convert-ToArray $Values)

    if ($TargetLength -eq 0) {
        return @()
    }

    if ($valuesArray.Count -eq $TargetLength) {
        return @($valuesArray)
    }

    if ($valuesArray.Count -eq 1 -and $TargetLength -gt 1) {
        return @((1..$TargetLength | ForEach-Object { [string]$valuesArray[0] }))
    }

    return @()
}

function Get-FieldValue {
    param(
        [pscustomobject]$Record,
        [string]$FieldName
    )

    $property = $Record.PSObject.Properties[$FieldName]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Test-VectorField {
    param(
        [object]$Value,
        [string]$FieldName,
        [int]$ExpectedDimension
    )

    $items = @(Convert-ToArray $Value)
    $numericValues = New-Object System.Collections.Generic.List[double]
    $nonNumericCount = 0
    $invalidType = $false

    if ($null -eq $Value) {
        return [pscustomobject]@{
            field_name = $FieldName
            is_present = $false
            is_array = $false
            is_empty = $true
            invalid_type = $false
            dimension = 0
            non_numeric_count = 0
            wrong_dimension = $false
            is_valid = $false
            values = @()
        }
    }

    if (($Value -isnot [System.Array]) -and ($Value -isnot [System.Collections.IEnumerable] -or $Value -is [string])) {
        $invalidType = $true
        return [pscustomobject]@{
            field_name = $FieldName
            is_present = $true
            is_array = $false
            is_empty = $false
            invalid_type = $true
            dimension = 0
            non_numeric_count = 0
            wrong_dimension = $false
            is_valid = $false
            values = @()
        }
    }

    foreach ($item in $items) {
        try {
            $numericValue = [double]$item
            if ([double]::IsNaN($numericValue) -or [double]::IsInfinity($numericValue)) {
                $nonNumericCount++
                continue
            }

            $numericValues.Add($numericValue)
        }
        catch {
            $nonNumericCount++
        }
    }

    $dimension = $items.Count
    $wrongDimension = ($ExpectedDimension -gt 0 -and $dimension -ne $ExpectedDimension)
    $isEmpty = ($dimension -eq 0)
    $isValid = (-not $invalidType -and -not $isEmpty -and $nonNumericCount -eq 0 -and -not $wrongDimension)

    return [pscustomobject]@{
        field_name = $FieldName
        is_present = $true
        is_array = $true
        is_empty = $isEmpty
        invalid_type = $invalidType
        dimension = $dimension
        non_numeric_count = $nonNumericCount
        wrong_dimension = $wrongDimension
        is_valid = $isValid
        values = @($numericValues)
    }
}

function Get-ExpectedVectorDimension {
    param(
        [object[]]$Records,
        [string]$FieldName
    )

    $dimensions = foreach ($record in $Records) {
        $value = Get-FieldValue -Record $record -FieldName $FieldName
        if ($null -eq $value) {
            continue
        }

        if (($value -is [System.Array]) -or ($value -is [System.Collections.IEnumerable] -and $value -isnot [string])) {
            $items = @(Convert-ToArray $value)
            if ($items.Count -eq 0) {
                continue
            }

            $hasNonNumeric = $false
            foreach ($item in $items) {
                try {
                    $null = [double]$item
                }
                catch {
                    $hasNonNumeric = $true
                    break
                }
            }

            if (-not $hasNonNumeric) {
                $items.Count
            }
        }
    }

    $mode = $dimensions |
        Group-Object |
        Sort-Object -Property @{ Expression = "Count"; Descending = $true }, @{ Expression = "Name"; Descending = $false } |
        Select-Object -First 1

    if ($null -eq $mode) {
        return 0
    }

    return [int]$mode.Name
}

function Get-StableYearLookup {
    param([object[]]$Records)

    $lookup = @{}

    foreach ($record in $Records) {
        $sections = @(Parse-ListLikeString -Value (Get-FieldValue -Record $record -FieldName "sections") -FieldName "sections")
        $programmes = @(Parse-ListLikeString -Value (Get-FieldValue -Record $record -FieldName "programmes") -FieldName "programmes")
        $years = @(Parse-ListLikeString -Value (Get-FieldValue -Record $record -FieldName "year") -FieldName "year")

        $expandedProgrammes = @(Expand-WithBroadcast -Values $programmes -TargetLength $sections.Count)
        $expandedYears = @(Expand-WithBroadcast -Values $years -TargetLength $sections.Count)

        if ($sections.Count -eq 0 -or $expandedProgrammes.Count -eq 0 -or $expandedYears.Count -eq 0) {
            continue
        }

        for ($i = 0; $i -lt $sections.Count; $i++) {
            $key = "$($sections[$i])||$($expandedProgrammes[$i])"
            if (-not $lookup.ContainsKey($key)) {
                $lookup[$key] = New-Object System.Collections.Generic.HashSet[string]
            }

            [void]$lookup[$key].Add([string]$expandedYears[$i])
        }
    }

    $stable = @{}
    foreach ($key in $lookup.Keys) {
        if ($lookup[$key].Count -eq 1) {
            $stable[$key] = @($lookup[$key])[0]
        }
    }

    return $stable
}

function Get-ChunkPairs {
    param([string[]]$ChunkIds)

    $pairs = @{}
    foreach ($chunkId in $ChunkIds) {
        if ($chunkId -match "^CH_(?<section>[^_]+)_(?<programme>[^_]+)_(?<chunk_number>.+)$") {
            $pairKey = "$($Matches.section)||$($Matches.programme)"
            if (-not $pairs.ContainsKey($pairKey)) {
                $pairs[$pairKey] = [ordered]@{
                    section = $Matches.section
                    programme = $Matches.programme
                    chunk_ids = New-Object System.Collections.Generic.List[string]
                }
            }

            $pairs[$pairKey].chunk_ids.Add($chunkId)
        }
    }

    return $pairs
}

function Get-DeterministicJson {
    param([object]$Value)

    return (ConvertTo-Json -InputObject $Value -Compress -Depth 10)
}

function Get-Sha256 {
    param([string]$Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Export-CsvWithSchema {
    param(
        [object[]]$Rows,
        [string[]]$Columns,
        [string]$Path
    )

    $rowArray = @(Convert-ToArray $Rows)
    if ($rowArray.Count -eq 0) {
        $header = ($Columns -join ",")
        Set-Content -LiteralPath $Path -Value $header -Encoding UTF8
        return
    }

    $rowArray |
        Select-Object -Property $Columns |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

Ensure-Directory -Path $ProcessedDir
Ensure-Directory -Path $DiagnosticsDir

$rawData = @(Convert-ToArray (Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json))

$nameVectorDimension = Get-ExpectedVectorDimension -Records $rawData -FieldName "name_vector"
$descriptionVectorDimension = Get-ExpectedVectorDimension -Records $rawData -FieldName "description_vector"
$stableYearLookup = Get-StableYearLookup -Records $rawData

$standardizationEvents = New-Object System.Collections.Generic.List[object]
$vectorIntegrityReport = New-Object System.Collections.Generic.List[object]
$cleanOccurrences = New-Object System.Collections.Generic.List[object]
$schemaSummary = New-Object System.Collections.Generic.List[object]
$decisionLog = New-Object System.Collections.Generic.List[object]
$excludedRows = New-Object System.Collections.Generic.List[object]

$mismatchedLengthRecords = 0
$chunkResolvedRecords = 0
$yearLookupMisses = 0

foreach ($field in $expectedFields) {
    $nonNullCount = 0
    $nullCount = 0
    $emptyStringCount = 0
    $invalidTypeCount = 0

    foreach ($record in $rawData) {
        $property = $record.PSObject.Properties[$field]
        if ($null -eq $property -or $null -eq $property.Value) {
            $nullCount++
            continue
        }

        $nonNullCount++
        $value = $property.Value

        switch ($field) {
            "name_vector" {
                if (($value -isnot [System.Array]) -and ($value -isnot [System.Collections.IEnumerable] -or $value -is [string])) {
                    $invalidTypeCount++
                }
            }
            "description_vector" {
                if (($value -isnot [System.Array]) -and ($value -isnot [System.Collections.IEnumerable] -or $value -is [string])) {
                    $invalidTypeCount++
                }
            }
            default {
                if ($value -isnot [string]) {
                    $invalidTypeCount++
                }
                elseif ([string]::IsNullOrWhiteSpace($value)) {
                    $emptyStringCount++
                }
            }
        }
    }

    $expectedType = switch ($field) {
        "name_vector" { "numeric_array" }
        "description_vector" { "numeric_array" }
        "sections" { "string_or_list_like_string" }
        "programmes" { "string_or_list_like_string" }
        "year" { "string_or_list_like_string" }
        "chunk_id" { "string_or_list_like_string" }
        default { "string" }
    }

    $schemaSummary.Add([pscustomobject]@{
        field_name = $field
        expected_type = $expectedType
        non_null_count = $nonNullCount
        null_count = $nullCount
        empty_string_count = $emptyStringCount
        invalid_type_count = $invalidTypeCount
    })
}

for ($recordIndex = 0; $recordIndex -lt $rawData.Count; $recordIndex++) {
    $record = $rawData[$recordIndex]

    $rawSkillId = Get-FieldValue -Record $record -FieldName "skill_id"
    $rawName = Get-FieldValue -Record $record -FieldName "name"
    $rawDescription = Get-FieldValue -Record $record -FieldName "description"
    $rawSections = Get-FieldValue -Record $record -FieldName "sections"
    $rawProgrammes = Get-FieldValue -Record $record -FieldName "programmes"
    $rawYear = Get-FieldValue -Record $record -FieldName "year"
    $rawEduType = Get-FieldValue -Record $record -FieldName "edu_type"
    $rawChunkId = Get-FieldValue -Record $record -FieldName "chunk_id"

    $skillId = Normalize-TextField -Value ([string]$rawSkillId) -FieldName "skill_id"
    $name = Normalize-TextField -Value ([string]$rawName) -FieldName "name"
    $description = Normalize-TextField -Value ([string]$rawDescription) -FieldName "description"
    $eduType = Normalize-TextField -Value ([string]$rawEduType) -FieldName "edu_type"

    foreach ($event in @(
        @{ field_name = "skill_id"; raw_value = [string]$rawSkillId; standardized_value = $skillId; rule_applied = "trim_whitespace_and_uppercase_identifier" },
        @{ field_name = "name"; raw_value = [string]$rawName; standardized_value = $name; rule_applied = "trim_and_collapse_whitespace" },
        @{ field_name = "description"; raw_value = [string]$rawDescription; standardized_value = $description; rule_applied = "trim_and_collapse_whitespace" },
        @{ field_name = "edu_type"; raw_value = [string]$rawEduType; standardized_value = $eduType; rule_applied = "trim_whitespace_and_uppercase_identifier" }
    )) {
        if ($event.raw_value -ne $event.standardized_value) {
            $standardizationEvents.Add([pscustomobject]$event)
        }
    }

    $sections = @(Parse-ListLikeString -Value $rawSections -FieldName "sections")
    $programmes = @(Parse-ListLikeString -Value $rawProgrammes -FieldName "programmes")
    $years = @(Parse-ListLikeString -Value $rawYear -FieldName "year")
    $chunkIds = @(Parse-ListLikeString -Value $rawChunkId -FieldName "chunk_id")

    foreach ($fieldEvent in @(
        @{ field_name = "sections"; raw_value = [string]$rawSections; standardized_value = (Get-DeterministicJson -Value $sections); rule_applied = "parsed_list_like_string_and_standardized_items" },
        @{ field_name = "programmes"; raw_value = [string]$rawProgrammes; standardized_value = (Get-DeterministicJson -Value $programmes); rule_applied = "parsed_list_like_string_and_standardized_items" },
        @{ field_name = "year"; raw_value = [string]$rawYear; standardized_value = (Get-DeterministicJson -Value $years); rule_applied = "parsed_list_like_string_and_standardized_items" },
        @{ field_name = "chunk_id"; raw_value = [string]$rawChunkId; standardized_value = (Get-DeterministicJson -Value $chunkIds); rule_applied = "parsed_list_like_string_and_standardized_items" }
    )) {
        if ($fieldEvent.raw_value -ne $fieldEvent.standardized_value) {
            $standardizationEvents.Add([pscustomobject]$fieldEvent)
        }
    }

    $nameVectorStatus = Test-VectorField -Value (Get-FieldValue -Record $record -FieldName "name_vector") -FieldName "name_vector" -ExpectedDimension $nameVectorDimension
    $descriptionVectorStatus = Test-VectorField -Value (Get-FieldValue -Record $record -FieldName "description_vector") -FieldName "description_vector" -ExpectedDimension $descriptionVectorDimension

    $vectorIntegrityReport.Add([pscustomobject]@{
        source_record_index = $recordIndex
        skill_id = $skillId
        name_vector_valid = $nameVectorStatus.is_valid
        name_vector_dimension = $nameVectorStatus.dimension
        name_vector_non_numeric_count = $nameVectorStatus.non_numeric_count
        name_vector_wrong_dimension = $nameVectorStatus.wrong_dimension
        name_vector_invalid_type = $nameVectorStatus.invalid_type
        description_vector_valid = $descriptionVectorStatus.is_valid
        description_vector_dimension = $descriptionVectorStatus.dimension
        description_vector_non_numeric_count = $descriptionVectorStatus.non_numeric_count
        description_vector_wrong_dimension = $descriptionVectorStatus.wrong_dimension
        description_vector_invalid_type = $descriptionVectorStatus.invalid_type
        overall_vector_status = if ($nameVectorStatus.is_valid -and $descriptionVectorStatus.is_valid) { "valid" } else { "invalid" }
    })

    if ($sections.Count -gt 0 -and (
        ($programmes.Count -notin @(0, 1, $sections.Count)) -or
        ($years.Count -notin @(0, 1, $sections.Count))
    )) {
        $mismatchedLengthRecords++
    }

    if (-not $nameVectorStatus.is_valid -or -not $descriptionVectorStatus.is_valid) {
        $excludedRows.Add([pscustomobject]@{
            source_record_index = $recordIndex
            skill_id = $skillId
            exclusion_reason = "invalid_vector"
        })
        continue
    }

    $chunkPairs = Get-ChunkPairs -ChunkIds $chunkIds
    $occurrencePairs = @()

    $expandedProgrammes = @(Expand-WithBroadcast -Values $programmes -TargetLength $sections.Count)
    $expandedYears = @(Expand-WithBroadcast -Values $years -TargetLength $sections.Count)
    if ($sections.Count -gt 0 -and $expandedProgrammes.Count -gt 0 -and $expandedYears.Count -gt 0) {
        for ($i = 0; $i -lt $sections.Count; $i++) {
            $occurrencePairs += [pscustomobject]@{
                section = [string]$sections[$i]
                programme = [string]$expandedProgrammes[$i]
                year = [string]$expandedYears[$i]
                chunk_ids = @()
                resolution_method = "direct_broadcast_from_metadata_lists"
            }
        }
    }
    elseif ($chunkPairs.Count -gt 0) {
        $chunkResolvedRecords++
        foreach ($pairKey in ($chunkPairs.Keys | Sort-Object)) {
            $section = [string]$chunkPairs[$pairKey].section
            $programme = [string]$chunkPairs[$pairKey].programme
            $yearKey = "$section||$programme"

            if (-not $stableYearLookup.ContainsKey($yearKey)) {
                $yearLookupMisses++
                $excludedRows.Add([pscustomobject]@{
                    source_record_index = $recordIndex
                    skill_id = $skillId
                    exclusion_reason = "missing_year_lookup_for_chunk_pair"
                })
                continue
            }

            $occurrencePairs += [pscustomobject]@{
                section = $section
                programme = $programme
                year = [string]$stableYearLookup[$yearKey]
                chunk_ids = @($chunkPairs[$pairKey].chunk_ids)
                resolution_method = "chunk_id_pairs_plus_stable_year_lookup"
            }
        }
    }
    else {
        $excludedRows.Add([pscustomobject]@{
            source_record_index = $recordIndex
            skill_id = $skillId
            exclusion_reason = "unresolved_occurrence_provenance"
        })
        continue
    }

    for ($occurrenceIndex = 0; $occurrenceIndex -lt $occurrencePairs.Count; $occurrenceIndex++) {
        $pair = $occurrencePairs[$occurrenceIndex]
        $occurrenceId = "{0}__{1}__{2}__{3}" -f $skillId, $pair.section, $pair.programme, $pair.year

        $cleanOccurrences.Add([pscustomobject][ordered]@{
            occurrence_id = $occurrenceId
            source_record_index = $recordIndex
            occurrence_index_within_record = $occurrenceIndex + 1
            skill_id = $skillId
            name = $name
            description = $description
            section = $pair.section
            programme = $pair.programme
            year = $pair.year
            edu_type = $eduType
            chunk_ids = @($pair.chunk_ids)
            chunk_id_count = @($pair.chunk_ids).Count
            provenance_resolution_method = $pair.resolution_method
            name_vector_dimension = $nameVectorStatus.dimension
            description_vector_dimension = $descriptionVectorStatus.dimension
            name_vector = @($nameVectorStatus.values)
            description_vector = @($descriptionVectorStatus.values)
            raw_name = [string]$rawName
            raw_description = [string]$rawDescription
            raw_sections = [string]$rawSections
            raw_programmes = [string]$rawProgrammes
            raw_year = [string]$rawYear
            raw_edu_type = [string]$rawEduType
            raw_chunk_id = [string]$rawChunkId
        })
    }
}

$duplicateIndex = @{}
foreach ($occurrence in $cleanOccurrences) {
    $duplicateKeySource = [ordered]@{
        name = $occurrence.name
        description = $occurrence.description
        section = $occurrence.section
        programme = $occurrence.programme
        year = $occurrence.year
        edu_type = $occurrence.edu_type
        name_vector_hash = Get-Sha256 -Text (Get-DeterministicJson -Value $occurrence.name_vector)
        description_vector_hash = Get-Sha256 -Text (Get-DeterministicJson -Value $occurrence.description_vector)
    }

    $duplicateKey = Get-Sha256 -Text (Get-DeterministicJson -Value $duplicateKeySource)
    if (-not $duplicateIndex.ContainsKey($duplicateKey)) {
        $duplicateIndex[$duplicateKey] = New-Object System.Collections.Generic.List[object]
    }

    $duplicateIndex[$duplicateKey].Add($occurrence)
}

$duplicateReport = New-Object System.Collections.Generic.List[object]
$duplicateGroups = @($duplicateIndex.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 } | Sort-Object Name)
$rowsToKeep = New-Object System.Collections.Generic.HashSet[string]

foreach ($occurrence in $cleanOccurrences) {
    [void]$rowsToKeep.Add($occurrence.occurrence_id)
}

$duplicateGroupNumber = 0
foreach ($group in $duplicateGroups) {
    $duplicateGroupNumber++
    $duplicateGroupId = "DUP_{0:d4}" -f $duplicateGroupNumber
    $orderedGroup = @($group.Value | Sort-Object source_record_index, occurrence_index_within_record, skill_id)
    $keepOccurrence = $orderedGroup[0]

    for ($i = 1; $i -lt $orderedGroup.Count; $i++) {
        [void]$rowsToKeep.Remove($orderedGroup[$i].occurrence_id)
    }

    foreach ($occurrence in $orderedGroup) {
        $duplicateReport.Add([pscustomobject]@{
            duplicate_group_id = $duplicateGroupId
            occurrence_id = $occurrence.occurrence_id
            skill_id = $occurrence.skill_id
            name = $occurrence.name
            description = $occurrence.description
            sections = $occurrence.section
            programmes = $occurrence.programme
            year = $occurrence.year
            edu_type = $occurrence.edu_type
            duplicate_type = "exact_occurrence_duplicate"
            recommended_action = if ($occurrence.occurrence_id -eq $keepOccurrence.occurrence_id) { "keep_reference_row" } else { "remove_duplicate_copy" }
        })
    }
}

$deduplicatedOccurrences = @($cleanOccurrences | Where-Object { $rowsToKeep.Contains($_.occurrence_id) })

$metadataStandardizationSummary = @(
    $standardizationEvents |
        Group-Object field_name, raw_value, standardized_value, rule_applied |
        ForEach-Object {
            $first = $_.Group[0]
            [pscustomobject]@{
                field_name = $first.field_name
                raw_value = $first.raw_value
                standardized_value = $first.standardized_value
                n_affected_records = $_.Count
                rule_applied = $first.rule_applied
            }
        } |
        Sort-Object field_name, raw_value, standardized_value
)

$vectorIntegritySummary = @()
foreach ($fieldName in @("name_vector", "description_vector")) {
    $fieldRows = @($vectorIntegrityReport | ForEach-Object {
        [pscustomobject]@{
            valid = if ($fieldName -eq "name_vector") { $_.name_vector_valid } else { $_.description_vector_valid }
            wrong_dimension = if ($fieldName -eq "name_vector") { $_.name_vector_wrong_dimension } else { $_.description_vector_wrong_dimension }
            non_numeric_count = if ($fieldName -eq "name_vector") { $_.name_vector_non_numeric_count } else { $_.description_vector_non_numeric_count }
            dimension = if ($fieldName -eq "name_vector") { $_.name_vector_dimension } else { $_.description_vector_dimension }
        }
    })

    $nonNumericSum = ($fieldRows | Measure-Object -Property non_numeric_count -Sum).Sum
    if ($null -eq $nonNumericSum) {
        $nonNumericSum = 0
    }

    $vectorIntegritySummary += [pscustomobject]@{
        vector_field = $fieldName
        expected_dimension = if ($fieldName -eq "name_vector") { $nameVectorDimension } else { $descriptionVectorDimension }
        valid_count = @($fieldRows | Where-Object { $_.valid }).Count
        invalid_count = @($fieldRows | Where-Object { -not $_.valid }).Count
        non_numeric_count = $nonNumericSum
        wrong_dimension_count = @($fieldRows | Where-Object { $_.wrong_dimension }).Count
        empty_count = @($fieldRows | Where-Object { $_.dimension -eq 0 }).Count
    }
}

$coverageSummary = @(
    $deduplicatedOccurrences |
        Group-Object edu_type, section, programme, year |
        ForEach-Object {
            $first = $_.Group[0]
            [pscustomobject]@{
                edu_type = $first.edu_type
                section = $first.section
                programme = $first.programme
                year = $first.year
                n_skill_occurrences = $_.Count
                n_unique_names = @($_.Group.name | Sort-Object -Unique).Count
            }
        } |
        Sort-Object edu_type, section, programme, year
)

$deduplicatedOccurrences = @(
    $deduplicatedOccurrences |
        Sort-Object `
            @{ Expression = { [string]$_.name }; Ascending = $true }, `
            @{ Expression = { [string]$_.description }; Ascending = $true }, `
            @{ Expression = { [string]$_.occurrence_id }; Ascending = $true }
)

$textInstanceGroups = $deduplicatedOccurrences |
    Group-Object name, description |
    Sort-Object Name

$textInstanceAssignments = @{}
$textInstanceRows = New-Object System.Collections.Generic.List[object]
$textInstanceGroupIndex = 0

foreach ($group in $textInstanceGroups) {
    $textInstanceGroupIndex++
    $textInstanceId = "TXI_{0:D4}" -f $textInstanceGroupIndex
    $orderedGroup = @($group.Group | Sort-Object occurrence_id)
    $referenceRow = $orderedGroup[0]

    foreach ($occurrence in $orderedGroup) {
        $textInstanceAssignments[$occurrence.occurrence_id] = $textInstanceId
    }

    $textInstanceRows.Add([pscustomobject][ordered]@{
        text_instance_id = $textInstanceId
        name = $referenceRow.name
        description = $referenceRow.description
        n_occurrences = $orderedGroup.Count
        n_sections = @($orderedGroup | ForEach-Object { $_.section } | Sort-Object -Unique).Count
        n_programmes = @($orderedGroup | ForEach-Object { $_.programme } | Sort-Object -Unique).Count
        n_years = @($orderedGroup | ForEach-Object { $_.year } | Sort-Object -Unique).Count
        requires_manual_validation = if (@($orderedGroup | Where-Object { $_.provenance_resolution_method -eq "chunk_id_pairs_plus_stable_year_lookup" }).Count -gt 0) { "true" } else { "false" }
        provenance_resolution_confidence = if (@($orderedGroup | Where-Object { $_.provenance_resolution_method -eq "chunk_id_pairs_plus_stable_year_lookup" }).Count -gt 0) { "mixed_or_manual_validation_required" } else { "high" }
        occurrence_ids = Get-DeterministicJson -Value @($orderedGroup | ForEach-Object { $_.occurrence_id })
        sections = Get-DeterministicJson -Value @($orderedGroup | ForEach-Object { $_.section } | Sort-Object -Unique)
        programmes = Get-DeterministicJson -Value @($orderedGroup | ForEach-Object { $_.programme } | Sort-Object -Unique)
        years = Get-DeterministicJson -Value @($orderedGroup | ForEach-Object { $_.year } | Sort-Object -Unique)
        edu_types = Get-DeterministicJson -Value @($orderedGroup | ForEach-Object { $_.edu_type } | Sort-Object -Unique)
        name_vector = Get-DeterministicJson -Value $referenceRow.name_vector
        description_vector = Get-DeterministicJson -Value $referenceRow.description_vector
    }) | Out-Null
}

$deduplicatedOccurrences = @(
    foreach ($row in $deduplicatedOccurrences) {
        [pscustomobject][ordered]@{
            text_instance_id = $textInstanceAssignments[$row.occurrence_id]
            occurrence_id = $row.occurrence_id
            source_record_index = $row.source_record_index
            occurrence_index_within_record = $row.occurrence_index_within_record
            skill_id = $row.skill_id
            name = $row.name
            description = $row.description
            section = $row.section
            programme = $row.programme
            year = $row.year
            edu_type = $row.edu_type
            chunk_ids = @($row.chunk_ids)
            chunk_id_count = $row.chunk_id_count
            provenance_resolution_method = $row.provenance_resolution_method
            provenance_resolution_confidence = if ($row.provenance_resolution_method -eq "chunk_id_pairs_plus_stable_year_lookup") { "manual_validation_required" } else { "high" }
            requires_manual_validation = ($row.provenance_resolution_method -eq "chunk_id_pairs_plus_stable_year_lookup")
            name_vector_dimension = $row.name_vector_dimension
            description_vector_dimension = $row.description_vector_dimension
            name_vector = @($row.name_vector)
            description_vector = @($row.description_vector)
            raw_name = $row.raw_name
            raw_description = $row.raw_description
            raw_sections = $row.raw_sections
            raw_programmes = $row.raw_programmes
            raw_year = $row.raw_year
            raw_edu_type = $row.raw_edu_type
            raw_chunk_id = $row.raw_chunk_id
        }
    }
)

$provenanceAuditRows = @(
    $deduplicatedOccurrences |
        Where-Object { $_.requires_manual_validation } |
        Sort-Object source_record_index, occurrence_index_within_record |
        ForEach-Object {
            [pscustomobject][ordered]@{
                text_instance_id = $_.text_instance_id
                occurrence_id = $_.occurrence_id
                source_record_index = $_.source_record_index
                skill_id = $_.skill_id
                name = $_.name
                description = $_.description
                section = $_.section
                programme = $_.programme
                year = $_.year
                edu_type = $_.edu_type
                chunk_ids = Get-DeterministicJson -Value $_.chunk_ids
                provenance_resolution_method = $_.provenance_resolution_method
                provenance_resolution_confidence = $_.provenance_resolution_confidence
                requires_manual_validation = "true"
                validation_note = "Resolved from chunk_id section-programme pairs plus stable year lookup; manually verify provenance before freezing downstream assignments."
            }
        }
)

$sensitivityOccurrences = @($deduplicatedOccurrences | Where-Object { -not $_.requires_manual_validation })

$decisionLog.Add([pscustomobject]@{
    decision_id = "STEP1_DEC_001"
    issue_type = "list_like_metadata_storage"
    affected_field = "sections;programmes;year;chunk_id"
    detected_problem = "Raw metadata fields are stored as list-like strings, and 26 records cannot be resolved by simple section-programme-year broadcasting alone."
    candidate_options = "preserve list-like strings; explode only exact length matches; explode to occurrence rows using unique section-programme pairs encoded in chunk_id plus stable year lookup"
    chosen_option = "explode_to_occurrence_rows_using_chunk_pairs_and_year_lookup"
    rationale = "Chunk identifiers provide complete section-programme provenance for all records, and section-programme pairs map to a single year in the raw metadata."
    n_affected_records = $rawData.Count
    status = "implemented"
})

if ($duplicateGroups.Count -gt 0) {
    $decisionLog.Add([pscustomobject]@{
        decision_id = "STEP1_DEC_002"
        issue_type = "exact_duplicate_policy"
        affected_field = "occurrence_level_rows"
        detected_problem = "Exact duplicate occurrence rows were detected after provenance expansion."
        candidate_options = "keep all and flag; remove duplicate copy and keep one reference row; merge duplicates with provenance note"
        chosen_option = "remove_duplicate_copy_and_keep_reference_row"
        rationale = "Literal duplicates add no analytical information at the occurrence level and can be removed conservatively while preserving a duplicate report."
        n_affected_records = @($duplicateReport | Where-Object { $_.recommended_action -eq "remove_duplicate_copy" }).Count
        status = "implemented"
    })
}

$decisionLog.Add([pscustomobject]@{
    decision_id = "STEP1_DEC_003"
    issue_type = "ambiguous_provenance_audit"
    affected_field = "occurrence_level_rows"
    detected_problem = "26 raw records required chunk-based provenance repair instead of direct metadata broadcasting."
    candidate_options = "treat repaired rows as fully trusted; flag repaired rows for manual validation; exclude repaired rows from the main cleaned dataset"
    chosen_option = "keep_rows_but_flag_for_manual_validation_and_export_sensitivity_dataset_excluding_them"
    rationale = "Later analytical units depend on section, programme, and year assignments, so repaired rows are retained with an explicit audit trail and a no-ambiguity sensitivity version of the cleaned dataset."
    n_affected_records = @($deduplicatedOccurrences | Where-Object { $_.requires_manual_validation } | Select-Object -ExpandProperty source_record_index -Unique).Count
    status = "implemented"
})

$recordsWithAllExpectedFields = @($rawData | Where-Object {
    $record = $_
    @($expectedFields | Where-Object { $null -ne $record.PSObject.Properties[$_] }).Count -eq $expectedFields.Count
}).Count

$dataAuditSummary = @(
    [pscustomobject]@{ metric_group = "raw"; metric_name = "raw_record_count"; metric_value = $rawData.Count },
    [pscustomobject]@{ metric_group = "raw"; metric_name = "records_with_all_expected_fields"; metric_value = $recordsWithAllExpectedFields },
    [pscustomobject]@{ metric_group = "vectors"; metric_name = "name_vector_expected_dimension"; metric_value = $nameVectorDimension },
    [pscustomobject]@{ metric_group = "vectors"; metric_name = "description_vector_expected_dimension"; metric_value = $descriptionVectorDimension },
    [pscustomobject]@{ metric_group = "vectors"; metric_name = "valid_name_vectors"; metric_value = @($vectorIntegrityReport | Where-Object { $_.name_vector_valid }).Count },
    [pscustomobject]@{ metric_group = "vectors"; metric_name = "valid_description_vectors"; metric_value = @($vectorIntegrityReport | Where-Object { $_.description_vector_valid }).Count },
    [pscustomobject]@{ metric_group = "provenance"; metric_name = "records_with_list_length_mismatch"; metric_value = $mismatchedLengthRecords },
    [pscustomobject]@{ metric_group = "provenance"; metric_name = "records_resolved_from_chunk_pairs"; metric_value = $chunkResolvedRecords },
    [pscustomobject]@{ metric_group = "provenance"; metric_name = "chunk_pair_year_lookup_misses"; metric_value = $yearLookupMisses },
    [pscustomobject]@{ metric_group = "provenance"; metric_name = "occurrence_rows_requiring_manual_validation"; metric_value = @($deduplicatedOccurrences | Where-Object { $_.requires_manual_validation }).Count },
    [pscustomobject]@{ metric_group = "provenance"; metric_name = "raw_records_requiring_manual_validation"; metric_value = @($deduplicatedOccurrences | Where-Object { $_.requires_manual_validation } | Select-Object -ExpandProperty source_record_index -Unique).Count },
    [pscustomobject]@{ metric_group = "occurrences"; metric_name = "occurrence_rows_before_deduplication"; metric_value = $cleanOccurrences.Count },
    [pscustomobject]@{ metric_group = "occurrences"; metric_name = "exact_duplicate_groups"; metric_value = $duplicateGroups.Count },
    [pscustomobject]@{ metric_group = "occurrences"; metric_name = "occurrence_rows_after_deduplication"; metric_value = $deduplicatedOccurrences.Count },
    [pscustomobject]@{ metric_group = "occurrences"; metric_name = "occurrence_rows_after_excluding_manual_validation_cases"; metric_value = $sensitivityOccurrences.Count },
    [pscustomobject]@{ metric_group = "occurrences"; metric_name = "excluded_raw_records"; metric_value = $excludedRows.Count },
    [pscustomobject]@{ metric_group = "text_instances"; metric_name = "unique_textual_instances"; metric_value = $textInstanceRows.Count },
    [pscustomobject]@{ metric_group = "coverage"; metric_name = "distinct_edu_types"; metric_value = @($deduplicatedOccurrences | ForEach-Object { $_.edu_type } | Sort-Object -Unique).Count },
    [pscustomobject]@{ metric_group = "coverage"; metric_name = "distinct_sections"; metric_value = @($deduplicatedOccurrences | ForEach-Object { $_.section } | Sort-Object -Unique).Count },
    [pscustomobject]@{ metric_group = "coverage"; metric_name = "distinct_programmes"; metric_value = @($deduplicatedOccurrences | ForEach-Object { $_.programme } | Sort-Object -Unique).Count },
    [pscustomobject]@{ metric_group = "coverage"; metric_name = "distinct_years"; metric_value = @($deduplicatedOccurrences | ForEach-Object { $_.year } | Sort-Object -Unique).Count }
)

$cleanOccurrencesCsv = @(
    foreach ($row in $deduplicatedOccurrences) {
        [pscustomobject][ordered]@{
            occurrence_id = $row.occurrence_id
            source_record_index = $row.source_record_index
            occurrence_index_within_record = $row.occurrence_index_within_record
            skill_id = $row.skill_id
            name = $row.name
            description = $row.description
            section = $row.section
            programme = $row.programme
            year = $row.year
            edu_type = $row.edu_type
            text_instance_id = $row.text_instance_id
            chunk_ids = Get-DeterministicJson -Value $row.chunk_ids
            chunk_id_count = $row.chunk_id_count
            provenance_resolution_method = $row.provenance_resolution_method
            provenance_resolution_confidence = $row.provenance_resolution_confidence
            requires_manual_validation = if ($row.requires_manual_validation) { "true" } else { "false" }
            name_vector_dimension = $row.name_vector_dimension
            description_vector_dimension = $row.description_vector_dimension
            name_vector = Get-DeterministicJson -Value $row.name_vector
            description_vector = Get-DeterministicJson -Value $row.description_vector
            raw_name = $row.raw_name
            raw_description = $row.raw_description
            raw_sections = $row.raw_sections
            raw_programmes = $row.raw_programmes
            raw_year = $row.raw_year
            raw_edu_type = $row.raw_edu_type
            raw_chunk_id = $row.raw_chunk_id
        }
    }
)

$sensitivityOccurrencesCsv = @(
    foreach ($row in $sensitivityOccurrences) {
        [pscustomobject][ordered]@{
            text_instance_id = $row.text_instance_id
            occurrence_id = $row.occurrence_id
            source_record_index = $row.source_record_index
            occurrence_index_within_record = $row.occurrence_index_within_record
            skill_id = $row.skill_id
            name = $row.name
            description = $row.description
            section = $row.section
            programme = $row.programme
            year = $row.year
            edu_type = $row.edu_type
            chunk_ids = Get-DeterministicJson -Value $row.chunk_ids
            chunk_id_count = $row.chunk_id_count
            provenance_resolution_method = $row.provenance_resolution_method
            provenance_resolution_confidence = $row.provenance_resolution_confidence
            requires_manual_validation = "false"
            name_vector_dimension = $row.name_vector_dimension
            description_vector_dimension = $row.description_vector_dimension
            name_vector = Get-DeterministicJson -Value $row.name_vector
            description_vector = Get-DeterministicJson -Value $row.description_vector
            raw_name = $row.raw_name
            raw_description = $row.raw_description
            raw_sections = $row.raw_sections
            raw_programmes = $row.raw_programmes
            raw_year = $row.raw_year
            raw_edu_type = $row.raw_edu_type
            raw_chunk_id = $row.raw_chunk_id
        }
    }
)

$cleanJsonPath = Join-Path $ProcessedDir "01_skills_occurrence_clean.json"
$cleanCsvPath = Join-Path $ProcessedDir "01_skills_occurrence_clean.csv"
$sensitivityJsonPath = Join-Path $ProcessedDir "01_skills_occurrence_clean_sensitivity_excluding_ambiguous.json"
$sensitivityCsvPath = Join-Path $ProcessedDir "01_skills_occurrence_clean_sensitivity_excluding_ambiguous.csv"
$uniqueTextInstancesPath = Join-Path $ProcessedDir "01_unique_textual_instances_vectors.csv"
$auditSummaryPath = Join-Path $DiagnosticsDir "01_data_audit_summary.csv"
$schemaSummaryPath = Join-Path $DiagnosticsDir "01_schema_validation_summary.csv"
$vectorReportPath = Join-Path $DiagnosticsDir "01_vector_integrity_report.csv"
$vectorSummaryPath = Join-Path $DiagnosticsDir "01_vector_integrity_summary.csv"
$duplicateReportPath = Join-Path $DiagnosticsDir "01_duplicate_report.csv"
$coveragePath = Join-Path $DiagnosticsDir "01_coverage_by_curricular_origin.csv"
$provenanceAuditPath = Join-Path $DiagnosticsDir "01_provenance_resolution_audit.csv"
$metadataLogPath = Join-Path $DiagnosticsDir "01_metadata_standardization_log.csv"
$decisionLogPath = Join-Path $DiagnosticsDir "01_preprocessing_decision_log.csv"

$deduplicatedOccurrences | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $cleanJsonPath -Encoding UTF8
$cleanOccurrencesCsv | Export-Csv -LiteralPath $cleanCsvPath -NoTypeInformation -Encoding UTF8
$sensitivityOccurrences | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $sensitivityJsonPath -Encoding UTF8
$sensitivityOccurrencesCsv | Export-Csv -LiteralPath $sensitivityCsvPath -NoTypeInformation -Encoding UTF8
$textInstanceRows | Export-Csv -LiteralPath $uniqueTextInstancesPath -NoTypeInformation -Encoding UTF8

Export-CsvWithSchema -Rows $dataAuditSummary -Columns @("metric_group", "metric_name", "metric_value") -Path $auditSummaryPath
Export-CsvWithSchema -Rows $schemaSummary -Columns @("field_name", "expected_type", "non_null_count", "null_count", "empty_string_count", "invalid_type_count") -Path $schemaSummaryPath
Export-CsvWithSchema -Rows $vectorIntegrityReport -Columns @(
    "source_record_index",
    "skill_id",
    "name_vector_valid",
    "name_vector_dimension",
    "name_vector_non_numeric_count",
    "name_vector_wrong_dimension",
    "name_vector_invalid_type",
    "description_vector_valid",
    "description_vector_dimension",
    "description_vector_non_numeric_count",
    "description_vector_wrong_dimension",
    "description_vector_invalid_type",
    "overall_vector_status"
) -Path $vectorReportPath
Export-CsvWithSchema -Rows $vectorIntegritySummary -Columns @("vector_field", "expected_dimension", "valid_count", "invalid_count", "non_numeric_count", "wrong_dimension_count", "empty_count") -Path $vectorSummaryPath
Export-CsvWithSchema -Rows $duplicateReport -Columns @("duplicate_group_id", "occurrence_id", "skill_id", "name", "description", "sections", "programmes", "year", "edu_type", "duplicate_type", "recommended_action") -Path $duplicateReportPath
Export-CsvWithSchema -Rows $coverageSummary -Columns @("edu_type", "section", "programme", "year", "n_skill_occurrences", "n_unique_names") -Path $coveragePath
Export-CsvWithSchema -Rows $provenanceAuditRows -Columns @("text_instance_id", "occurrence_id", "source_record_index", "skill_id", "name", "description", "section", "programme", "year", "edu_type", "chunk_ids", "provenance_resolution_method", "provenance_resolution_confidence", "requires_manual_validation", "validation_note") -Path $provenanceAuditPath
Export-CsvWithSchema -Rows $metadataStandardizationSummary -Columns @("field_name", "raw_value", "standardized_value", "n_affected_records", "rule_applied") -Path $metadataLogPath
Export-CsvWithSchema -Rows $decisionLog -Columns @("decision_id", "issue_type", "affected_field", "detected_problem", "candidate_options", "chosen_option", "rationale", "n_affected_records", "status") -Path $decisionLogPath

[pscustomobject]@{
    raw_record_count = $rawData.Count
    occurrence_rows_before_deduplication = $cleanOccurrences.Count
    occurrence_rows_after_deduplication = $deduplicatedOccurrences.Count
    occurrence_rows_after_excluding_manual_validation_cases = $sensitivityOccurrences.Count
    occurrence_rows_requiring_manual_validation = @($deduplicatedOccurrences | Where-Object { $_.requires_manual_validation }).Count
    unique_textual_instances = $textInstanceRows.Count
    duplicate_groups = $duplicateGroups.Count
    name_vector_dimension = $nameVectorDimension
    description_vector_dimension = $descriptionVectorDimension
    list_length_mismatch_records = $mismatchedLengthRecords
    year_lookup_misses = $yearLookupMisses
    clean_json = $cleanJsonPath
    clean_csv = $cleanCsvPath
    sensitivity_json = $sensitivityJsonPath
    sensitivity_csv = $sensitivityCsvPath
    unique_textual_instances_csv = $uniqueTextInstancesPath
    diagnostics_dir = $DiagnosticsDir
} | Format-List
