using System.Globalization;
using System.Text;
using System.Text.Json;

var workspaceRoot = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));
var nodeTablesDirectory = Path.Combine(workspaceRoot, "outputs", "node_tables");
var similarityMatricesDirectory = Path.Combine(workspaceRoot, "outputs", "similarity_matrices");
var graphsFullDirectory = Path.Combine(workspaceRoot, "outputs", "graphs_full");

Directory.CreateDirectory(similarityMatricesDirectory);
Directory.CreateDirectory(graphsFullDirectory);

var familyConfigs = new[]
{
    new FamilyConfig(
        levelName: "pooled",
        inputPath: Path.Combine(nodeTablesDirectory, "05_graph_ready_nodes_pooled.csv"),
        matrixOutputPath: Path.Combine(similarityMatricesDirectory, "06_similarity_matrices_pooled.csv"),
        edgeOutputPath: Path.Combine(graphsFullDirectory, "06_weighted_edges_pooled.csv")),
    new FamilyConfig(
        levelName: "tracks",
        inputPath: Path.Combine(nodeTablesDirectory, "05_graph_ready_nodes_tracks.csv"),
        matrixOutputPath: Path.Combine(similarityMatricesDirectory, "06_similarity_matrices_tracks.csv"),
        edgeOutputPath: Path.Combine(graphsFullDirectory, "06_weighted_edges_tracks.csv")),
    new FamilyConfig(
        levelName: "sections",
        inputPath: Path.Combine(nodeTablesDirectory, "05_graph_ready_nodes_sections.csv"),
        matrixOutputPath: Path.Combine(similarityMatricesDirectory, "06_similarity_matrices_sections.csv"),
        edgeOutputPath: Path.Combine(graphsFullDirectory, "06_weighted_edges_sections.csv")),
    new FamilyConfig(
        levelName: "programmes",
        inputPath: Path.Combine(nodeTablesDirectory, "05_graph_ready_nodes_programmes.csv"),
        matrixOutputPath: Path.Combine(similarityMatricesDirectory, "06_similarity_matrices_programmes.csv"),
        edgeOutputPath: Path.Combine(graphsFullDirectory, "06_weighted_edges_programmes.csv")),
    new FamilyConfig(
        levelName: "programme_years",
        inputPath: Path.Combine(nodeTablesDirectory, "05_graph_ready_nodes_programme_years.csv"),
        matrixOutputPath: Path.Combine(similarityMatricesDirectory, "06_similarity_matrices_programme_years.csv"),
        edgeOutputPath: Path.Combine(graphsFullDirectory, "06_weighted_edges_programme_years.csv"))
};

var summaryPath = Path.Combine(graphsFullDirectory, "06_weighted_graph_summary.csv");
var metadataPath = Path.Combine(graphsFullDirectory, "06_weighted_graph_metadata.csv");
var storageDecisionsPath = Path.Combine(graphsFullDirectory, "06_graph_storage_decisions.csv");

var summaryRows = new List<GraphSummaryRow>();
var metadataRows = new List<GraphMetadataRow>();

foreach (var familyConfig in familyConfigs)
{
    if (!File.Exists(familyConfig.inputPath))
    {
        throw new FileNotFoundException("Required Step 5 node table not found.", familyConfig.inputPath);
    }

    var units = LoadNodeFamilies(familyConfig.inputPath)
        .OrderBy(group => group.Key, StringComparer.Ordinal)
        .ToList();

    using var matrixWriter = CreateWriter(familyConfig.matrixOutputPath);
    using var edgeWriter = CreateWriter(familyConfig.edgeOutputPath);

    WriteCsvRow(matrixWriter, [
        "unit_type",
        "unit_id",
        "representation",
        "node_id_row",
        "node_id_col",
        "similarity_value"
    ]);

    WriteCsvRow(edgeWriter, [
        "unit_type",
        "unit_id",
        "representation",
        "harmonized_skill_id_1",
        "harmonized_skill_id_2",
        "harmonized_name_1",
        "harmonized_name_2",
        "edge_weight"
    ]);

    foreach (var (_, nodes) in units)
    {
        var orderedNodes = nodes
            .OrderBy(node => node.HarmonizedSkillId, StringComparer.Ordinal)
            .ToList();

        foreach (var representation in Representations.All)
        {
            ProcessGraph(
                nodes: orderedNodes,
                representation: representation,
                matrixWriter: matrixWriter,
                edgeWriter: edgeWriter,
                matrixFileRelative: ToRelativePath(workspaceRoot, familyConfig.matrixOutputPath),
                edgeFileRelative: ToRelativePath(workspaceRoot, familyConfig.edgeOutputPath),
                summaryRows: summaryRows,
                metadataRows: metadataRows);
        }
    }
}

WriteSummary(summaryPath, summaryRows);
WriteMetadata(metadataPath, metadataRows);
WriteStorageDecisions(storageDecisionsPath);

Console.WriteLine($"Graph families processed: {familyConfigs.Length}");
Console.WriteLine($"Graphs summarized: {metadataRows.Count}");
Console.WriteLine($"Summary file: {summaryPath}");

static Dictionary<string, List<NodeRecord>> LoadNodeFamilies(string csvPath)
{
    using var reader = new StreamReader(csvPath, Encoding.UTF8);
    var headerLine = reader.ReadLine() ?? throw new InvalidOperationException($"Node table is empty: {csvPath}");
    var headers = ParseCsvLine(headerLine);
    var index = headers
        .Select((name, position) => new { name, position })
        .ToDictionary(item => item.name, item => item.position, StringComparer.Ordinal);

    var units = new Dictionary<string, List<NodeRecord>>(StringComparer.Ordinal);

    while (!reader.EndOfStream)
    {
        var line = reader.ReadLine();
        if (string.IsNullOrWhiteSpace(line))
        {
            continue;
        }

        var fields = ParseCsvLine(line);
        var unitId = GetRequiredField(fields, index, "unit_id");
        var unitType = GetRequiredField(fields, index, "unit_type");
        var record = new NodeRecord(
            UnitType: unitType,
            UnitId: unitId,
            HarmonizedSkillId: GetRequiredField(fields, index, "harmonized_skill_id"),
            HarmonizedName: GetRequiredField(fields, index, "harmonized_name"),
            NameVector: ParseVector(GetRequiredField(fields, index, "node_name_vector")),
            NameDescriptionVector: ParseVector(GetRequiredField(fields, index, "node_name_description_vector")));

        if (!units.TryGetValue(unitId, out var unitRecords))
        {
            unitRecords = new List<NodeRecord>();
            units[unitId] = unitRecords;
        }

        unitRecords.Add(record);
    }

    return units;
}

static void ProcessGraph(
    IReadOnlyList<NodeRecord> nodes,
    Representation representation,
    StreamWriter matrixWriter,
    StreamWriter edgeWriter,
    string matrixFileRelative,
    string edgeFileRelative,
    ICollection<GraphSummaryRow> summaryRows,
    ICollection<GraphMetadataRow> metadataRows)
{
    if (nodes.Count == 0)
    {
        return;
    }

    var unitType = nodes[0].UnitType;
    var unitId = nodes[0].UnitId;

    var vectors = nodes
        .Select(node => representation.FieldSelector(node))
        .ToArray();

    var edgeWeights = new List<double>(Math.Max(1, nodes.Count * (nodes.Count - 1) / 2));
    var nPossibleEdges = (long)nodes.Count * (nodes.Count - 1) / 2;

    for (var i = 0; i < nodes.Count; i++)
    {
        var leftNode = nodes[i];
        var diagonal = Dot(vectors[i], vectors[i]);

        WriteCsvRow(matrixWriter, [
            unitType,
            unitId,
            representation.Id,
            leftNode.HarmonizedSkillId,
            leftNode.HarmonizedSkillId,
            FormatDouble(diagonal)
        ]);

        for (var j = i + 1; j < nodes.Count; j++)
        {
            var rightNode = nodes[j];
            var similarity = Dot(vectors[i], vectors[j]);
            var similarityText = FormatDouble(similarity);

            WriteCsvRow(matrixWriter, [
                unitType,
                unitId,
                representation.Id,
                leftNode.HarmonizedSkillId,
                rightNode.HarmonizedSkillId,
                similarityText
            ]);

            WriteCsvRow(matrixWriter, [
                unitType,
                unitId,
                representation.Id,
                rightNode.HarmonizedSkillId,
                leftNode.HarmonizedSkillId,
                similarityText
            ]);

            WriteCsvRow(edgeWriter, [
                unitType,
                unitId,
                representation.Id,
                leftNode.HarmonizedSkillId,
                rightNode.HarmonizedSkillId,
                leftNode.HarmonizedName,
                rightNode.HarmonizedName,
                similarityText
            ]);

            edgeWeights.Add(similarity);
        }
    }

    edgeWeights.Sort();
    var stats = ComputeStatistics(edgeWeights);

    summaryRows.Add(new GraphSummaryRow(
        unit_type: unitType,
        unit_id: unitId,
        representation: representation.Id,
        n_nodes: nodes.Count,
        n_possible_edges: nPossibleEdges,
        edge_weight_min: stats.Min,
        edge_weight_mean: stats.Mean,
        edge_weight_median: stats.Median,
        edge_weight_std: stats.Std,
        edge_weight_p75: stats.P75,
        edge_weight_p90: stats.P90,
        edge_weight_p95: stats.P95,
        edge_weight_max: stats.Max));

    metadataRows.Add(new GraphMetadataRow(
        graph_id: $"GRAPH_{unitType.ToUpperInvariant()}_{unitId.ToUpperInvariant()}_{representation.Id.ToUpperInvariant()}",
        unit_type: unitType,
        unit_id: unitId,
        representation: representation.Id,
        n_nodes: nodes.Count,
        n_possible_edges: nPossibleEdges,
        matrix_file: matrixFileRelative,
        edge_file: edgeFileRelative,
        notes: "Long-format similarity matrix retains diagonal self-similarities; edge list retains all unordered node pairs; no sparsification applied."));
}

static Statistics ComputeStatistics(IReadOnlyList<double> values)
{
    if (values.Count == 0)
    {
        return Statistics.Empty;
    }

    var min = values[0];
    var max = values[^1];
    var sum = 0d;
    foreach (var value in values)
    {
        sum += value;
    }

    var mean = sum / values.Count;
    var varianceSum = 0d;
    foreach (var value in values)
    {
        var diff = value - mean;
        varianceSum += diff * diff;
    }

    var std = Math.Sqrt(varianceSum / values.Count);

    return new Statistics(
        Min: FormatDouble(min),
        Mean: FormatDouble(mean),
        Median: FormatDouble(Percentile(values, 0.5)),
        Std: FormatDouble(std),
        P75: FormatDouble(Percentile(values, 0.75)),
        P90: FormatDouble(Percentile(values, 0.90)),
        P95: FormatDouble(Percentile(values, 0.95)),
        Max: FormatDouble(max));
}

static double Percentile(IReadOnlyList<double> sortedValues, double percentile)
{
    if (sortedValues.Count == 0)
    {
        return double.NaN;
    }

    if (sortedValues.Count == 1)
    {
        return sortedValues[0];
    }

    var position = percentile * (sortedValues.Count - 1);
    var lowerIndex = (int)Math.Floor(position);
    var upperIndex = (int)Math.Ceiling(position);

    if (lowerIndex == upperIndex)
    {
        return sortedValues[lowerIndex];
    }

    var weight = position - lowerIndex;
    return sortedValues[lowerIndex] + (sortedValues[upperIndex] - sortedValues[lowerIndex]) * weight;
}

static double Dot(double[] left, double[] right)
{
    if (left.Length != right.Length)
    {
        throw new InvalidOperationException("Vector length mismatch.");
    }

    var sum = 0d;
    for (var i = 0; i < left.Length; i++)
    {
        sum += left[i] * right[i];
    }

    return sum;
}

static string GetRequiredField(IReadOnlyList<string> fields, IReadOnlyDictionary<string, int> index, string columnName)
{
    if (!index.TryGetValue(columnName, out var position))
    {
        throw new InvalidOperationException($"Missing required column '{columnName}'.");
    }

    if (position >= fields.Count)
    {
        throw new InvalidOperationException($"Row does not contain column '{columnName}'.");
    }

    var value = fields[position];
    if (string.IsNullOrWhiteSpace(value))
    {
        throw new InvalidOperationException($"Encountered an empty value for required column '{columnName}'.");
    }

    return value;
}

static double[] ParseVector(string vectorText)
{
    return JsonSerializer.Deserialize<double[]>(vectorText)
        ?? throw new InvalidOperationException("Failed to parse vector JSON.");
}

static List<string> ParseCsvLine(string line)
{
    var fields = new List<string>();
    var builder = new StringBuilder();
    var inQuotes = false;

    for (var i = 0; i < line.Length; i++)
    {
        var character = line[i];

        if (inQuotes)
        {
            if (character == '"')
            {
                if (i + 1 < line.Length && line[i + 1] == '"')
                {
                    builder.Append('"');
                    i++;
                }
                else
                {
                    inQuotes = false;
                }
            }
            else
            {
                builder.Append(character);
            }
        }
        else
        {
            if (character == ',')
            {
                fields.Add(builder.ToString());
                builder.Clear();
            }
            else if (character == '"')
            {
                inQuotes = true;
            }
            else
            {
                builder.Append(character);
            }
        }
    }

    fields.Add(builder.ToString());
    return fields;
}

static StreamWriter CreateWriter(string path)
{
    var directory = Path.GetDirectoryName(path);
    if (!string.IsNullOrWhiteSpace(directory))
    {
        Directory.CreateDirectory(directory);
    }

    return new StreamWriter(path, false, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false), bufferSize: 1 << 20);
}

static void WriteSummary(string path, IReadOnlyList<GraphSummaryRow> rows)
{
    using var writer = CreateWriter(path);
    WriteCsvRow(writer, [
        "unit_type",
        "unit_id",
        "representation",
        "n_nodes",
        "n_possible_edges",
        "edge_weight_min",
        "edge_weight_mean",
        "edge_weight_median",
        "edge_weight_std",
        "edge_weight_p75",
        "edge_weight_p90",
        "edge_weight_p95",
        "edge_weight_max"
    ]);

    foreach (var row in rows
        .OrderBy(item => UnitTypeOrder(item.unit_type))
        .ThenBy(item => item.unit_id, StringComparer.Ordinal)
        .ThenBy(item => item.representation, StringComparer.Ordinal))
    {
        WriteCsvRow(writer, [
            row.unit_type,
            row.unit_id,
            row.representation,
            row.n_nodes.ToString(CultureInfo.InvariantCulture),
            row.n_possible_edges.ToString(CultureInfo.InvariantCulture),
            row.edge_weight_min,
            row.edge_weight_mean,
            row.edge_weight_median,
            row.edge_weight_std,
            row.edge_weight_p75,
            row.edge_weight_p90,
            row.edge_weight_p95,
            row.edge_weight_max
        ]);
    }
}

static void WriteMetadata(string path, IReadOnlyList<GraphMetadataRow> rows)
{
    using var writer = CreateWriter(path);
    WriteCsvRow(writer, [
        "graph_id",
        "unit_type",
        "unit_id",
        "representation",
        "n_nodes",
        "n_possible_edges",
        "matrix_file",
        "edge_file",
        "notes"
    ]);

    foreach (var row in rows
        .OrderBy(item => UnitTypeOrder(item.unit_type))
        .ThenBy(item => item.unit_id, StringComparer.Ordinal)
        .ThenBy(item => item.representation, StringComparer.Ordinal))
    {
        WriteCsvRow(writer, [
            row.graph_id,
            row.unit_type,
            row.unit_id,
            row.representation,
            row.n_nodes.ToString(CultureInfo.InvariantCulture),
            row.n_possible_edges.ToString(CultureInfo.InvariantCulture),
            row.matrix_file,
            row.edge_file,
            row.notes
        ]);
    }
}

static void WriteStorageDecisions(string path)
{
    using var writer = CreateWriter(path);
    WriteCsvRow(writer, [
        "decision_id",
        "issue_type",
        "affected_component",
        "candidate_options",
        "chosen_option",
        "rationale"
    ]);

    WriteCsvRow(writer, [
        "DEC_001",
        "matrix_storage",
        "similarity_matrices",
        "long format; wide matrix format",
        "long format",
        "Long format preserves one reusable storage schema across units of very different sizes and keeps matrices easy to filter by unit and representation."
    ]);

    WriteCsvRow(writer, [
        "DEC_002",
        "edge_storage",
        "weighted_edge_lists",
        "all unordered pairs; only positive similarities",
        "all unordered pairs",
        "Step 6 keeps the full weighted graph dense and unsparsified, so the edge lists retain every unordered node pair regardless of the cosine sign."
    ]);

    WriteCsvRow(writer, [
        "DEC_003",
        "metadata_storage",
        "graph_metadata",
        "embedded in edge files; separate metadata file",
        "separate metadata file",
        "A separate metadata table makes it easier to compare graph sizes and file locations across all analytical units and both representations."
    ]);
}

static void WriteCsvRow(StreamWriter writer, IReadOnlyList<string?> values)
{
    writer.WriteLine(string.Join(",", values.Select(CsvEscape)));
}

static string CsvEscape(string? value)
{
    if (string.IsNullOrEmpty(value))
    {
        return string.Empty;
    }

    var escaped = value.Replace("\"", "\"\"");
    return escaped.IndexOfAny([',', '"', '\n', '\r']) >= 0
        ? $"\"{escaped}\""
        : escaped;
}

static string FormatDouble(double value)
{
    return value.ToString("0.######", CultureInfo.InvariantCulture);
}

static string ToRelativePath(string root, string path)
{
    return Path.GetRelativePath(root, path).Replace('\\', '/');
}

static int UnitTypeOrder(string unitType) => unitType switch
{
    "pooled" => 1,
    "track" => 2,
    "section" => 3,
    "programme" => 4,
    "programme_year" => 5,
    _ => 99
};

readonly record struct FamilyConfig(string levelName, string inputPath, string matrixOutputPath, string edgeOutputPath);

readonly record struct NodeRecord(
    string UnitType,
    string UnitId,
    string HarmonizedSkillId,
    string HarmonizedName,
    double[] NameVector,
    double[] NameDescriptionVector);

readonly record struct Representation(string Id, Func<NodeRecord, double[]> FieldSelector)
{
    public static readonly Representation NameOnly = new("name_only", node => node.NameVector);
    public static readonly Representation NameDescription = new("name_description", node => node.NameDescriptionVector);
}

static class Representations
{
    public static readonly Representation[] All =
    [
        Representation.NameOnly,
        Representation.NameDescription
    ];
}

readonly record struct Statistics(
    string Min,
    string Mean,
    string Median,
    string Std,
    string P75,
    string P90,
    string P95,
    string Max)
{
    public static readonly Statistics Empty = new("", "", "", "", "", "", "", "");
}

readonly record struct GraphSummaryRow(
    string unit_type,
    string unit_id,
    string representation,
    int n_nodes,
    long n_possible_edges,
    string edge_weight_min,
    string edge_weight_mean,
    string edge_weight_median,
    string edge_weight_std,
    string edge_weight_p75,
    string edge_weight_p90,
    string edge_weight_p95,
    string edge_weight_max);

readonly record struct GraphMetadataRow(
    string graph_id,
    string unit_type,
    string unit_id,
    string representation,
    int n_nodes,
    long n_possible_edges,
    string matrix_file,
    string edge_file,
    string notes);
