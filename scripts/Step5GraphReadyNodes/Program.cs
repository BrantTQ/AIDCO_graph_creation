using System.Globalization;
using System.Text;
using System.Text.Json;

var workspaceRoot = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));
var inputPath = Path.Combine(workspaceRoot, "data_processed", "04_skills_harmonized.json");
var unitDefinitionsDirectory = Path.Combine(workspaceRoot, "outputs", "unit_definitions");
var nodeTablesDirectory = Path.Combine(workspaceRoot, "outputs", "node_tables");

Directory.CreateDirectory(unitDefinitionsDirectory);
Directory.CreateDirectory(nodeTablesDirectory);

var analysisUnitsDefinitionPath = Path.Combine(unitDefinitionsDirectory, "05_analysis_units_definition.csv");
var decisionsPath = Path.Combine(unitDefinitionsDirectory, "05_unit_and_aggregation_decisions.csv");
var sectionsNodesPath = Path.Combine(nodeTablesDirectory, "05_graph_ready_nodes_sections.csv");
var tracksNodesPath = Path.Combine(nodeTablesDirectory, "05_graph_ready_nodes_tracks.csv");
var programmesNodesPath = Path.Combine(nodeTablesDirectory, "05_graph_ready_nodes_programmes.csv");
var programmeYearsNodesPath = Path.Combine(nodeTablesDirectory, "05_graph_ready_nodes_programme_years.csv");
var pooledNodesPath = Path.Combine(nodeTablesDirectory, "05_graph_ready_nodes_pooled.csv");
var nodeAggregationSummaryPath = Path.Combine(nodeTablesDirectory, "05_node_aggregation_summary.csv");
var provenancePath = Path.Combine(nodeTablesDirectory, "05_harmonized_node_provenance.csv");

if (!File.Exists(inputPath))
{
    throw new FileNotFoundException("Step 4 harmonized dataset not found.", inputPath);
}

var serializerOptions = new JsonSerializerOptions
{
    PropertyNameCaseInsensitive = true
};

var json = File.ReadAllText(inputPath);
var records = JsonSerializer.Deserialize<List<HarmonizedRecord>>(json, serializerOptions)
    ?? throw new InvalidOperationException("Failed to deserialize the harmonized dataset.");

if (records.Count == 0)
{
    throw new InvalidOperationException("The harmonized dataset is empty.");
}

var preparedRecords = records.Select(PreparedRecord.Create).ToList();

var pooledGroups = new[]
{
    CreateUnitContext(
        unitType: "pooled",
        unitId: "POOLED_ALL",
        unitLabel: "Pooled all-skills unit",
        definitionRule: "All harmonized skill records in the full harmonized dataset.",
        records: preparedRecords)
};

var trackGroups = preparedRecords
    .GroupBy(record => RequireNonEmpty(record.Source.edu_type, "edu_type"))
    .OrderBy(group => group.Key, StringComparer.Ordinal)
    .Select(group => CreateUnitContext(
        unitType: "track",
        unitId: group.Key,
        unitLabel: GetTrackLabel(group.Key),
        definitionRule: $"All harmonized skill records with edu_type == {group.Key} across all sections, programmes, and years.",
        records: group.ToList()))
    .ToList();

var sectionGroups = preparedRecords
    .GroupBy(record => RequireNonEmpty(record.Source.section, "section"))
    .OrderBy(group => group.Key, StringComparer.Ordinal)
    .Select(group => CreateUnitContext(
        unitType: "section",
        unitId: group.Key,
        unitLabel: group.Key,
        definitionRule: $"All harmonized skill records with section == {group.Key} across all years and programmes.",
        records: group.ToList()))
    .ToList();

var programmeGroups = preparedRecords
    .GroupBy(record => RequireNonEmpty(record.Source.programme, "programme"))
    .OrderBy(group => group.Key, StringComparer.Ordinal)
    .Select(group => CreateUnitContext(
        unitType: "programme",
        unitId: group.Key,
        unitLabel: group.Key,
        definitionRule: $"All harmonized skill records with programme == {group.Key} across all sections and years.",
        records: group.ToList()))
    .ToList();

var programmeYearGroups = preparedRecords
    .GroupBy(record => $"{RequireNonEmpty(record.Source.programme, "programme")}__{RequireNonEmpty(record.Source.year, "year")}")
    .OrderBy(group => group.Key, StringComparer.Ordinal)
    .Select(group =>
    {
        var first = group.First();
        var programme = RequireNonEmpty(first.Source.programme, "programme");
        var year = RequireNonEmpty(first.Source.year, "year");
        return CreateUnitContext(
            unitType: "programme_year",
            unitId: $"{programme}__{year}",
            unitLabel: $"{programme} year {year}",
            definitionRule: $"All harmonized skill records with programme == {programme} and year == {year}.",
            records: group.ToList());
    })
    .ToList();

var pooledResult = BuildUnitFamily(pooledGroups);
var trackResult = BuildUnitFamily(trackGroups);
var sectionResult = BuildUnitFamily(sectionGroups);
var programmeResult = BuildUnitFamily(programmeGroups);
var programmeYearResult = BuildUnitFamily(programmeYearGroups);

var allAnalysisUnits = pooledResult.AnalysisUnits
    .Concat(trackResult.AnalysisUnits)
    .Concat(sectionResult.AnalysisUnits)
    .Concat(programmeResult.AnalysisUnits)
    .Concat(programmeYearResult.AnalysisUnits)
    .OrderBy(unit => GetUnitTypeSortOrder(unit.unit_type))
    .ThenBy(unit => unit.unit_id, StringComparer.Ordinal)
    .ToList();

var allNodeSummaries = pooledResult.NodeAggregationSummaries
    .Concat(trackResult.NodeAggregationSummaries)
    .Concat(sectionResult.NodeAggregationSummaries)
    .Concat(programmeResult.NodeAggregationSummaries)
    .Concat(programmeYearResult.NodeAggregationSummaries)
    .OrderBy(summary => GetUnitTypeSortOrder(summary.unit_type))
    .ThenBy(summary => summary.unit_id, StringComparer.Ordinal)
    .ToList();

var allProvenanceRows = pooledResult.ProvenanceRows
    .Concat(trackResult.ProvenanceRows)
    .Concat(sectionResult.ProvenanceRows)
    .Concat(programmeResult.ProvenanceRows)
    .Concat(programmeYearResult.ProvenanceRows)
    .OrderBy(row => GetUnitTypeSortOrder(row.unit_type))
    .ThenBy(row => row.unit_id, StringComparer.Ordinal)
    .ThenBy(row => row.harmonized_skill_id, StringComparer.Ordinal)
    .ToList();

var decisions = new List<UnitDecision>
{
    new(
        decision_id: "DEC_001",
        issue_type: "unit_definition",
        affected_component: "pooled_units",
        candidate_options: "single pooled unit; track-specific pooled units",
        chosen_option: "single pooled unit",
        rationale: "The pooled unit is the full harmonized dataset and serves as the most aggregated observational layer."),
    new(
        decision_id: "DEC_002",
        issue_type: "unit_definition",
        affected_component: "track_units",
        candidate_options: "edu_type only; edu_type x year",
        chosen_option: "edu_type only",
        rationale: "Track units summarize each education track across the available sections, programmes, and years."),
    new(
        decision_id: "DEC_003",
        issue_type: "unit_definition",
        affected_component: "section_units",
        candidate_options: "section only; section x year; section x programme",
        chosen_option: "section only",
        rationale: "Section units keep the disciplinary layer stable across years and programmes."),
    new(
        decision_id: "DEC_004",
        issue_type: "unit_definition",
        affected_component: "programme_units",
        candidate_options: "programme only; programme x section",
        chosen_option: "programme only",
        rationale: "Programmes are analyzed as full curricula across their sections and years."),
    new(
        decision_id: "DEC_005",
        issue_type: "unit_definition",
        affected_component: "programme_year_units",
        candidate_options: "programme x year; programme x year x section",
        chosen_option: "programme x year",
        rationale: "Programme-year is the progression-sensitive unit and is frozen explicitly in Step 5."),
    new(
        decision_id: "DEC_006",
        issue_type: "node_aggregation",
        affected_component: "node_vectors",
        candidate_options: "average raw occurrence vectors; average normalized occurrence vectors and renormalize",
        chosen_option: "average normalized occurrence vectors and renormalize",
        rationale: "This keeps node construction fixed across all unit levels and both semantic representations.")
};

WriteCsv(analysisUnitsDefinitionPath, allAnalysisUnits);
WriteCsv(decisionsPath, decisions);
WriteCsv(sectionsNodesPath, sectionResult.NodeRows);
WriteCsv(tracksNodesPath, trackResult.NodeRows);
WriteCsv(programmesNodesPath, programmeResult.NodeRows);
WriteCsv(programmeYearsNodesPath, programmeYearResult.NodeRows);
WriteCsv(pooledNodesPath, pooledResult.NodeRows);
WriteCsv(nodeAggregationSummaryPath, allNodeSummaries);
WriteCsv(provenancePath, allProvenanceRows);

Console.WriteLine($"Loaded harmonized records: {preparedRecords.Count}");
Console.WriteLine($"Pooled units: {pooledGroups.Length}");
Console.WriteLine($"Track units: {trackGroups.Count}");
Console.WriteLine($"Section units: {sectionGroups.Count}");
Console.WriteLine($"Programme units: {programmeGroups.Count}");
Console.WriteLine($"Programme-year units: {programmeYearGroups.Count}");
Console.WriteLine($"Pooled nodes written: {pooledResult.NodeRows.Count}");
Console.WriteLine($"Track nodes written: {trackResult.NodeRows.Count}");
Console.WriteLine($"Section nodes written: {sectionResult.NodeRows.Count}");
Console.WriteLine($"Programme nodes written: {programmeResult.NodeRows.Count}");
Console.WriteLine($"Programme-year nodes written: {programmeYearResult.NodeRows.Count}");

static string RequireNonEmpty(string? value, string fieldName)
{
    if (string.IsNullOrWhiteSpace(value))
    {
        throw new InvalidOperationException($"Encountered an empty required field: {fieldName}");
    }

    return value.Trim();
}

static string GetTrackLabel(string trackId) => trackId switch
{
    "CLS" => "Classic track (CLS)",
    "GEN" => "General track (GEN)",
    _ => trackId
};

static int GetUnitTypeSortOrder(string unitType) => unitType switch
{
    "pooled" => 1,
    "track" => 2,
    "section" => 3,
    "programme" => 4,
    "programme_year" => 5,
    _ => 99
};

static UnitContext CreateUnitContext(
    string unitType,
    string unitId,
    string unitLabel,
    string definitionRule,
    IReadOnlyList<PreparedRecord> records)
{
    return new UnitContext(unitType, unitId, unitLabel, definitionRule, records);
}

static UnitFamilyResult BuildUnitFamily(IEnumerable<UnitContext> units)
{
    var analysisUnits = new List<AnalysisUnitRow>();
    var nodeRows = new List<NodeRow>();
    var summaryRows = new List<NodeAggregationSummaryRow>();
    var provenanceRows = new List<ProvenanceRow>();

    foreach (var unit in units)
    {
        var nodeGroups = unit.Records
            .GroupBy(record => RequireNonEmpty(record.Source.harmonized_skill_id, "harmonized_skill_id"))
            .OrderBy(group => group.Key, StringComparer.Ordinal)
            .ToList();

        foreach (var nodeGroup in nodeGroups)
        {
            var orderedRecords = nodeGroup
                .OrderBy(record => RequireNonEmpty(record.Source.occurrence_id, "occurrence_id"), StringComparer.Ordinal)
                .ToList();

            var harmonizedName = RequireNonEmpty(orderedRecords[0].Source.harmonized_name, "harmonized_name");
            if (orderedRecords.Any(record => !string.Equals(record.Source.harmonized_name, harmonizedName, StringComparison.Ordinal)))
            {
                throw new InvalidOperationException($"Inconsistent harmonized_name values detected for {nodeGroup.Key} in unit {unit.UnitType}:{unit.UnitId}.");
            }

            var sourceSkillIds = orderedRecords
                .Select(record => RequireNonEmpty(record.Source.skill_id, "skill_id"))
                .Distinct(StringComparer.Ordinal)
                .OrderBy(value => value, StringComparer.Ordinal)
                .ToList();

            var sourceTextInstanceIds = orderedRecords
                .Select(record => RequireNonEmpty(record.Source.text_instance_id, "text_instance_id"))
                .Distinct(StringComparer.Ordinal)
                .OrderBy(value => value, StringComparer.Ordinal)
                .ToList();

            var sourceOldNames = orderedRecords
                .Select(record => RequireNonEmpty(record.Source.old_name, "old_name"))
                .Distinct(StringComparer.Ordinal)
                .OrderBy(value => value, StringComparer.Ordinal)
                .ToList();

            var sourceProgrammes = orderedRecords
                .Select(record => RequireNonEmpty(record.Source.programme, "programme"))
                .Distinct(StringComparer.Ordinal)
                .OrderBy(value => value, StringComparer.Ordinal)
                .ToList();

            var sourceSections = orderedRecords
                .Select(record => RequireNonEmpty(record.Source.section, "section"))
                .Distinct(StringComparer.Ordinal)
                .OrderBy(value => value, StringComparer.Ordinal)
                .ToList();

            var sourceYears = orderedRecords
                .Select(record => RequireNonEmpty(record.Source.year, "year"))
                .Distinct(StringComparer.Ordinal)
                .OrderBy(value => value, StringComparer.Ordinal)
                .ToList();

            var sourceEduTypes = orderedRecords
                .Select(record => RequireNonEmpty(record.Source.edu_type, "edu_type"))
                .Distinct(StringComparer.Ordinal)
                .OrderBy(value => value, StringComparer.Ordinal)
                .ToList();

            var nodeNameVector = Normalize(AverageVectors(orderedRecords.Select(record => record.NormalizedNameVector)));
            var nodeNameDescriptionVector = Normalize(AverageVectors(orderedRecords.Select(record => record.NormalizedCombinedVector)));

            nodeRows.Add(new NodeRow(
                unit_type: unit.UnitType,
                unit_id: unit.UnitId,
                harmonized_skill_id: nodeGroup.Key,
                harmonized_name: harmonizedName,
                node_name_vector: SerializeVector(nodeNameVector),
                node_name_description_vector: SerializeVector(nodeNameDescriptionVector),
                n_source_records: orderedRecords.Count,
                n_source_years: sourceYears.Count,
                n_source_programmes: sourceProgrammes.Count,
                n_source_sections: sourceSections.Count,
                n_source_edu_types: sourceEduTypes.Count));

            provenanceRows.Add(new ProvenanceRow(
                unit_type: unit.UnitType,
                unit_id: unit.UnitId,
                harmonized_skill_id: nodeGroup.Key,
                harmonized_name: harmonizedName,
                source_skill_ids: SerializeStringList(sourceSkillIds),
                source_text_instance_ids: SerializeStringList(sourceTextInstanceIds),
                source_old_names: SerializeStringList(sourceOldNames),
                source_programmes: SerializeStringList(sourceProgrammes),
                source_sections: SerializeStringList(sourceSections),
                source_years: SerializeStringList(sourceYears),
                source_edu_types: SerializeStringList(sourceEduTypes)));
        }

        var nGraphNodes = nodeGroups.Count;
        var nSourceRecords = unit.Records.Count;
        var nCollapsedNodes = nodeGroups.Count(group => group.Count() > 1);
        var meanRecordsPerNode = nGraphNodes == 0
            ? 0d
            : (double)nSourceRecords / nGraphNodes;

        analysisUnits.Add(new AnalysisUnitRow(
            unit_type: unit.UnitType,
            unit_id: unit.UnitId,
            unit_label: unit.UnitLabel,
            definition_rule: unit.DefinitionRule,
            n_source_records: nSourceRecords,
            n_graph_nodes: nGraphNodes));

        summaryRows.Add(new NodeAggregationSummaryRow(
            unit_type: unit.UnitType,
            unit_id: unit.UnitId,
            n_source_records: nSourceRecords,
            n_harmonized_skill_ids: nGraphNodes,
            n_graph_nodes: nGraphNodes,
            n_collapsed_nodes: nCollapsedNodes,
            mean_records_per_node: meanRecordsPerNode.ToString("0.######", CultureInfo.InvariantCulture)));
    }

    return new UnitFamilyResult(analysisUnits, nodeRows, summaryRows, provenanceRows);
}

static double[] AverageVectors(IEnumerable<double[]> vectors)
{
    using var enumerator = vectors.GetEnumerator();
    if (!enumerator.MoveNext())
    {
        throw new InvalidOperationException("Cannot average an empty set of vectors.");
    }

    var first = enumerator.Current;
    var sum = new double[first.Length];
    AddInPlace(sum, first);
    var count = 1;

    while (enumerator.MoveNext())
    {
        AddInPlace(sum, enumerator.Current);
        count++;
    }

    for (var i = 0; i < sum.Length; i++)
    {
        sum[i] /= count;
    }

    return sum;
}

static void AddInPlace(double[] target, double[] source)
{
    if (target.Length != source.Length)
    {
        throw new InvalidOperationException("Vector length mismatch.");
    }

    for (var i = 0; i < target.Length; i++)
    {
        target[i] += source[i];
    }
}

static double[] Normalize(double[] vector)
{
    var norm = 0d;
    for (var i = 0; i < vector.Length; i++)
    {
        norm += vector[i] * vector[i];
    }

    norm = Math.Sqrt(norm);
    if (norm == 0d)
    {
        return vector.ToArray();
    }

    var normalized = new double[vector.Length];
    for (var i = 0; i < vector.Length; i++)
    {
        normalized[i] = vector[i] / norm;
    }

    return normalized;
}

static string SerializeVector(double[] vector)
{
    var builder = new StringBuilder();
    builder.Append('[');
    for (var i = 0; i < vector.Length; i++)
    {
        if (i > 0)
        {
            builder.Append(',');
        }

        builder.Append(vector[i].ToString("0.#################", CultureInfo.InvariantCulture));
    }

    builder.Append(']');
    return builder.ToString();
}

static string SerializeStringList(IEnumerable<string> values)
{
    return JsonSerializer.Serialize(values);
}

static void WriteCsv<T>(string path, IReadOnlyList<T> rows)
{
    var properties = typeof(T).GetProperties();
    using var writer = new StreamWriter(path, false, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
    writer.WriteLine(string.Join(",", properties.Select(property => CsvEscape(property.Name))));

    foreach (var row in rows)
    {
        writer.WriteLine(string.Join(",", properties.Select(property => CsvEscape(property.GetValue(row)))));
    }
}

static string CsvEscape(object? value)
{
    if (value is null)
    {
        return string.Empty;
    }

    var text = value switch
    {
        bool booleanValue => booleanValue ? "true" : "false",
        _ => Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty
    };

    if (text.Contains('"'))
    {
        text = text.Replace("\"", "\"\"");
    }

    return text.IndexOfAny([',', '"', '\n', '\r']) >= 0
        ? $"\"{text}\""
        : text;
}

sealed class HarmonizedRecord
{
    public string occurrence_id { get; set; } = string.Empty;
    public string skill_id { get; set; } = string.Empty;
    public string text_instance_id { get; set; } = string.Empty;
    public string old_name { get; set; } = string.Empty;
    public string harmonized_name { get; set; } = string.Empty;
    public string harmonized_skill_id { get; set; } = string.Empty;
    public string section { get; set; } = string.Empty;
    public string programme { get; set; } = string.Empty;
    public string year { get; set; } = string.Empty;
    public string edu_type { get; set; } = string.Empty;
    public double[] name_vector { get; set; } = [];
    public double[] description_vector { get; set; } = [];
}

sealed class PreparedRecord
{
    public required HarmonizedRecord Source { get; init; }
    public required double[] NormalizedNameVector { get; init; }
    public required double[] NormalizedCombinedVector { get; init; }

    public static PreparedRecord Create(HarmonizedRecord record)
    {
        if (record.name_vector.Length == 0 || record.description_vector.Length == 0)
        {
            throw new InvalidOperationException($"Missing vectors for occurrence {record.occurrence_id}.");
        }

        var normalizedName = NormalizeLocal(record.name_vector);
        var normalizedDescription = NormalizeLocal(record.description_vector);
        var combined = new double[normalizedName.Length + normalizedDescription.Length];
        Array.Copy(normalizedName, 0, combined, 0, normalizedName.Length);
        Array.Copy(normalizedDescription, 0, combined, normalizedName.Length, normalizedDescription.Length);
        var normalizedCombined = NormalizeLocal(combined);

        return new PreparedRecord
        {
            Source = record,
            NormalizedNameVector = normalizedName,
            NormalizedCombinedVector = normalizedCombined
        };
    }

    private static double[] NormalizeLocal(double[] vector)
    {
        var norm = 0d;
        for (var i = 0; i < vector.Length; i++)
        {
            norm += vector[i] * vector[i];
        }

        norm = Math.Sqrt(norm);
        if (norm == 0d)
        {
            return vector.ToArray();
        }

        var normalized = new double[vector.Length];
        for (var i = 0; i < vector.Length; i++)
        {
            normalized[i] = vector[i] / norm;
        }

        return normalized;
    }
}

sealed record UnitContext(
    string UnitType,
    string UnitId,
    string UnitLabel,
    string DefinitionRule,
    IReadOnlyList<PreparedRecord> Records);

sealed record AnalysisUnitRow(
    string unit_type,
    string unit_id,
    string unit_label,
    string definition_rule,
    int n_source_records,
    int n_graph_nodes);

sealed record NodeRow(
    string unit_type,
    string unit_id,
    string harmonized_skill_id,
    string harmonized_name,
    string node_name_vector,
    string node_name_description_vector,
    int n_source_records,
    int n_source_years,
    int n_source_programmes,
    int n_source_sections,
    int n_source_edu_types);

sealed record NodeAggregationSummaryRow(
    string unit_type,
    string unit_id,
    int n_source_records,
    int n_harmonized_skill_ids,
    int n_graph_nodes,
    int n_collapsed_nodes,
    string mean_records_per_node);

sealed record ProvenanceRow(
    string unit_type,
    string unit_id,
    string harmonized_skill_id,
    string harmonized_name,
    string source_skill_ids,
    string source_text_instance_ids,
    string source_old_names,
    string source_programmes,
    string source_sections,
    string source_years,
    string source_edu_types);

sealed record UnitDecision(
    string decision_id,
    string issue_type,
    string affected_component,
    string candidate_options,
    string chosen_option,
    string rationale);

sealed record UnitFamilyResult(
    IReadOnlyList<AnalysisUnitRow> AnalysisUnits,
    IReadOnlyList<NodeRow> NodeRows,
    IReadOnlyList<NodeAggregationSummaryRow> NodeAggregationSummaries,
    IReadOnlyList<ProvenanceRow> ProvenanceRows);
