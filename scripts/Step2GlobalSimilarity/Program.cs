using System.Globalization;
using System.Text;
using System.Text.Json;

var repoRoot = Directory.GetCurrentDirectory();
var inputPath = Path.Combine(repoRoot, "data_processed", "01_unique_textual_instances_vectors.csv");
var outputDir = Path.Combine(repoRoot, "outputs", "similarity_tables");

const double DefaultScreeningCutoffNameOnly = 0.70622;
const double DefaultScreeningCutoffNameDescription = 0.701394;

if (!File.Exists(inputPath))
{
    throw new FileNotFoundException($"Unique textual-instance base file not found at '{inputPath}'.");
}

Directory.CreateDirectory(outputDir);

var baseRows = ReadBaseRows(inputPath);
if (baseRows.Count == 0)
{
    throw new InvalidOperationException("The unique textual-instance base file is empty.");
}

var instances = baseRows
    .OrderBy(row => row.TextInstanceId, StringComparer.Ordinal)
    .Select(row => new TextInstance(
        TextInstanceId: row.TextInstanceId,
        Name: row.Name,
        Description: row.Description,
        RequiresManualValidation: ParseBoolean(row.RequiresManualValidationText),
        NameVector: ParseVector(row.NameVectorText, "name_vector", row.TextInstanceId),
        DescriptionVector: ParseVector(row.DescriptionVectorText, "description_vector", row.TextInstanceId)))
    .ToList();

ValidateDimensions(instances);

var normalizedNameVectors = instances
    .Select(instance => NormalizeVector(instance.NameVector, "name_vector", instance.TextInstanceId))
    .ToArray();
var normalizedDescriptionVectors = instances
    .Select(instance => NormalizeVector(instance.DescriptionVector, "description_vector", instance.TextInstanceId))
    .ToArray();

var pairwisePath = Path.Combine(outputDir, "02_candidate_pairwise_similarity.csv");
var summaryPath = Path.Combine(outputDir, "02_candidate_screening_summary.csv");
var cutoffsPath = Path.Combine(outputDir, "02_screening_cutoff_selection.csv");
var exactNamePath = Path.Combine(outputDir, "02_exact_name_candidate_stratum.csv");
var calibrationTemplatePath = Path.Combine(outputDir, "02_screening_calibration_template.csv");

var exactNamePairs = new List<CandidatePair>();
var allPairs = new List<CandidatePair>();
var nameOnlySimilarities = new List<double>();
var combinedSimilarities = new List<double>();

long pairCounter = 0;
for (var leftIndex = 0; leftIndex < instances.Count; leftIndex += 1)
{
    var leftInstance = instances[leftIndex];
    var leftNameVector = normalizedNameVectors[leftIndex];
    var leftDescriptionVector = normalizedDescriptionVectors[leftIndex];

    for (var rightIndex = leftIndex + 1; rightIndex < instances.Count; rightIndex += 1)
    {
        var rightInstance = instances[rightIndex];
        var cosineNameOnly = Dot(leftNameVector, normalizedNameVectors[rightIndex]);
        var cosineNameDescription =
            (cosineNameOnly + Dot(leftDescriptionVector, normalizedDescriptionVectors[rightIndex])) / 2.0;

        pairCounter += 1;

        var exactNameMatch = string.Equals(leftInstance.Name, rightInstance.Name, StringComparison.Ordinal);
        var exactDescriptionMatch = string.Equals(leftInstance.Description, rightInstance.Description, StringComparison.Ordinal);
        var reviewStratum = exactNameMatch ? "exact_name_review_stratum" : "different_name_review_stratum";
        var requiresManualValidation = leftInstance.RequiresManualValidation || rightInstance.RequiresManualValidation;

        var pair = new CandidatePair(
            PairId: $"PAIR_{pairCounter:D6}",
            TextInstanceId1: leftInstance.TextInstanceId,
            TextInstanceId2: rightInstance.TextInstanceId,
            Name1: leftInstance.Name,
            Description1: leftInstance.Description,
            Name2: rightInstance.Name,
            Description2: rightInstance.Description,
            ExactNameMatch: exactNameMatch,
            ExactDescriptionMatch: exactDescriptionMatch,
            ReviewStratum: reviewStratum,
            RequiresManualValidation: requiresManualValidation,
            CosineNameOnly: cosineNameOnly,
            CosineNameDescription: cosineNameDescription);

        allPairs.Add(pair);
        if (exactNameMatch)
        {
            exactNamePairs.Add(pair);
        }

        nameOnlySimilarities.Add(cosineNameOnly);
        combinedSimilarities.Add(cosineNameDescription);
    }
}

using (var writer = CreateWriter(pairwisePath))
{
    WriteCsvRow(writer, new[]
    {
        "pair_id",
        "text_instance_id_1",
        "text_instance_id_2",
        "name_1",
        "description_1",
        "name_2",
        "description_2",
        "exact_name_match",
        "exact_description_match",
        "review_stratum",
        "requires_manual_validation",
        "cosine_name_only",
        "cosine_name_description"
    });

    foreach (var pair in allPairs)
    {
        WriteCsvRow(writer, new[]
        {
            pair.PairId,
            pair.TextInstanceId1,
            pair.TextInstanceId2,
            pair.Name1,
            pair.Description1,
            pair.Name2,
            pair.Description2,
            FormatBoolean(pair.ExactNameMatch),
            FormatBoolean(pair.ExactDescriptionMatch),
            pair.ReviewStratum,
            FormatBoolean(pair.RequiresManualValidation),
            FormatDouble(pair.CosineNameOnly),
            FormatDouble(pair.CosineNameDescription)
        });
    }
}

using (var writer = CreateWriter(exactNamePath))
{
    WriteCsvRow(writer, new[]
    {
        "pair_id",
        "text_instance_id_1",
        "text_instance_id_2",
        "name_1",
        "description_1",
        "name_2",
        "description_2",
        "exact_description_match",
        "requires_manual_validation",
        "cosine_name_only",
        "cosine_name_description"
    });

    foreach (var pair in exactNamePairs)
    {
        WriteCsvRow(writer, new[]
        {
            pair.PairId,
            pair.TextInstanceId1,
            pair.TextInstanceId2,
            pair.Name1,
            pair.Description1,
            pair.Name2,
            pair.Description2,
            FormatBoolean(pair.ExactDescriptionMatch),
            FormatBoolean(pair.RequiresManualValidation),
            FormatDouble(pair.CosineNameOnly),
            FormatDouble(pair.CosineNameDescription)
        });
    }
}

var summaryRows = new[]
{
    BuildSummaryRow("name_only", nameOnlySimilarities),
    BuildSummaryRow("name_description", combinedSimilarities)
};

using (var writer = CreateWriter(summaryPath))
{
    WriteCsvRow(writer, new[]
    {
        "representation",
        "n_pairs",
        "similarity_min",
        "similarity_p25",
        "similarity_median",
        "similarity_mean",
        "similarity_p75",
        "similarity_p90",
        "similarity_p95",
        "similarity_max",
        "similarity_std"
    });

    foreach (var row in summaryRows)
    {
        WriteCsvRow(writer, new[]
        {
            row.Representation,
            row.Count.ToString(CultureInfo.InvariantCulture),
            FormatDouble(row.Min),
            FormatDouble(row.P25),
            FormatDouble(row.Median),
            FormatDouble(row.Mean),
            FormatDouble(row.P75),
            FormatDouble(row.P90),
            FormatDouble(row.P95),
            FormatDouble(row.Max),
            FormatDouble(row.StdDev)
        });
    }
}

using (var writer = CreateWriter(cutoffsPath))
{
    WriteCsvRow(writer, new[]
    {
        "screening_cutoff_name_only",
        "screening_cutoff_name_description",
        "cutoff_source",
        "cutoff_status",
        "notes"
    });

    WriteCsvRow(writer, new[]
    {
        FormatDouble(DefaultScreeningCutoffNameOnly),
        FormatDouble(DefaultScreeningCutoffNameDescription),
        "analyst_fixed_provisional",
        "pending_pilot_calibration",
        "These are provisional screening cutoffs used only to form the Step 3 manual-review candidate list. Final graph selection is deferred to Steps 7 and 8."
    });
}

var calibrationPairs = BuildCalibrationTemplate(allPairs);
using (var writer = CreateWriter(calibrationTemplatePath))
{
    WriteCsvRow(writer, new[]
    {
        "pair_id",
        "text_instance_id_1",
        "text_instance_id_2",
        "name_1",
        "description_1",
        "name_2",
        "description_2",
        "review_stratum",
        "cosine_name_only",
        "cosine_name_description",
        "max_similarity",
        "pilot_label",
        "pilot_notes"
    });

    foreach (var pair in calibrationPairs)
    {
        var maxSimilarity = Math.Max(pair.CosineNameOnly, pair.CosineNameDescription);
        WriteCsvRow(writer, new[]
        {
            pair.PairId,
            pair.TextInstanceId1,
            pair.TextInstanceId2,
            pair.Name1,
            pair.Description1,
            pair.Name2,
            pair.Description2,
            pair.ReviewStratum,
            FormatDouble(pair.CosineNameOnly),
            FormatDouble(pair.CosineNameDescription),
            FormatDouble(maxSimilarity),
            string.Empty,
            string.Empty
        });
    }
}

Console.WriteLine($"Loaded textual instances: {instances.Count.ToString(CultureInfo.InvariantCulture)}");
Console.WriteLine($"Candidate pairs written: {allPairs.Count.ToString(CultureInfo.InvariantCulture)}");
Console.WriteLine($"Exact-name review-stratum pairs: {exactNamePairs.Count.ToString(CultureInfo.InvariantCulture)}");
Console.WriteLine($"Calibration template rows: {calibrationPairs.Count.ToString(CultureInfo.InvariantCulture)}");

static List<BaseRow> ReadBaseRows(string path)
{
    using var reader = new StreamReader(path);
    var headerLine = reader.ReadLine() ?? throw new InvalidOperationException("The unique textual-instance base file has no header row.");
    var header = ParseCsvLine(headerLine);
    var index = header
        .Select((name, position) => new { name, position })
        .ToDictionary(item => item.name, item => item.position, StringComparer.OrdinalIgnoreCase);

    foreach (var requiredColumn in new[]
    {
        "text_instance_id",
        "name",
        "description",
        "requires_manual_validation",
        "name_vector",
        "description_vector"
    })
    {
        if (!index.ContainsKey(requiredColumn))
        {
            throw new InvalidOperationException($"Expected column '{requiredColumn}' in the unique textual-instance base file.");
        }
    }

    var rows = new List<BaseRow>();
    string? line;
    while ((line = reader.ReadLine()) is not null)
    {
        if (string.IsNullOrWhiteSpace(line))
        {
            continue;
        }

        var fields = ParseCsvLine(line);
        rows.Add(new BaseRow(
            TextInstanceId: GetField(fields, index, "text_instance_id"),
            Name: GetField(fields, index, "name"),
            Description: GetField(fields, index, "description"),
            RequiresManualValidationText: GetField(fields, index, "requires_manual_validation"),
            NameVectorText: GetField(fields, index, "name_vector"),
            DescriptionVectorText: GetField(fields, index, "description_vector")));
    }

    return rows;
}

static string GetField(IReadOnlyList<string> fields, IReadOnlyDictionary<string, int> index, string columnName)
{
    if (!index.TryGetValue(columnName, out var position))
    {
        throw new InvalidOperationException($"Missing required column '{columnName}'.");
    }

    return position < fields.Count ? fields[position] : string.Empty;
}

static List<CandidatePair> BuildCalibrationTemplate(IReadOnlyList<CandidatePair> allPairs)
{
    var candidates = allPairs
        .Select(pair => new
        {
            Pair = pair,
            MaxSimilarity = Math.Max(pair.CosineNameOnly, pair.CosineNameDescription),
            SimilarityBin = GetSimilarityBin(Math.Max(pair.CosineNameOnly, pair.CosineNameDescription))
        })
        .GroupBy(item => new { item.Pair.ReviewStratum, item.SimilarityBin })
        .OrderBy(group => group.Key.ReviewStratum, StringComparer.Ordinal)
        .ThenBy(group => group.Key.SimilarityBin, StringComparer.Ordinal)
        .SelectMany(group => group
            .OrderByDescending(item => item.MaxSimilarity)
            .ThenBy(item => item.Pair.PairId, StringComparer.Ordinal)
            .Take(12)
            .Select(item => item.Pair))
        .DistinctBy(pair => pair.PairId)
        .OrderBy(pair => pair.ReviewStratum, StringComparer.Ordinal)
        .ThenByDescending(pair => Math.Max(pair.CosineNameOnly, pair.CosineNameDescription))
        .ThenBy(pair => pair.PairId, StringComparer.Ordinal)
        .ToList();

    return candidates;
}

static string GetSimilarityBin(double similarity)
{
    if (similarity >= 0.90) return "0.90_to_1.00";
    if (similarity >= 0.80) return "0.80_to_0.89";
    if (similarity >= 0.70) return "0.70_to_0.79";
    if (similarity >= 0.60) return "0.60_to_0.69";
    return "below_0.60";
}

static bool ParseBoolean(string text) =>
    string.Equals(text?.Trim(), "true", StringComparison.OrdinalIgnoreCase);

static List<string> ParseCsvLine(string line)
{
    var fields = new List<string>();
    var current = new StringBuilder();
    var inQuotes = false;

    for (var index = 0; index < line.Length; index += 1)
    {
        var character = line[index];

        if (inQuotes)
        {
            if (character == '"')
            {
                if (index + 1 < line.Length && line[index + 1] == '"')
                {
                    current.Append('"');
                    index += 1;
                }
                else
                {
                    inQuotes = false;
                }
            }
            else
            {
                current.Append(character);
            }
        }
        else
        {
            switch (character)
            {
                case ',':
                    fields.Add(current.ToString());
                    current.Clear();
                    break;
                case '"':
                    inQuotes = true;
                    break;
                default:
                    current.Append(character);
                    break;
            }
        }
    }

    fields.Add(current.ToString());
    return fields;
}

static double[] ParseVector(string vectorText, string fieldName, string instanceId)
{
    var vector = JsonSerializer.Deserialize<double[]>(vectorText);
    if (vector is null || vector.Length == 0)
    {
        throw new InvalidOperationException($"Text instance '{instanceId}' has an invalid {fieldName} value.");
    }

    return vector;
}

static void ValidateDimensions(IReadOnlyList<TextInstance> instances)
{
    var expectedNameDimension = instances[0].NameVector.Length;
    var expectedDescriptionDimension = instances[0].DescriptionVector.Length;

    foreach (var instance in instances)
    {
        if (instance.NameVector.Length != expectedNameDimension)
        {
            throw new InvalidOperationException($"Text instance '{instance.TextInstanceId}' has name_vector dimension {instance.NameVector.Length.ToString(CultureInfo.InvariantCulture)} instead of {expectedNameDimension.ToString(CultureInfo.InvariantCulture)}.");
        }

        if (instance.DescriptionVector.Length != expectedDescriptionDimension)
        {
            throw new InvalidOperationException($"Text instance '{instance.TextInstanceId}' has description_vector dimension {instance.DescriptionVector.Length.ToString(CultureInfo.InvariantCulture)} instead of {expectedDescriptionDimension.ToString(CultureInfo.InvariantCulture)}.");
        }
    }
}

static double[] NormalizeVector(double[] vector, string fieldName, string instanceId)
{
    var squaredNorm = 0.0;
    for (var index = 0; index < vector.Length; index += 1)
    {
        squaredNorm += vector[index] * vector[index];
    }

    if (squaredNorm <= 0.0)
    {
        throw new InvalidOperationException($"Text instance '{instanceId}' has a zero-norm {fieldName}.");
    }

    var norm = Math.Sqrt(squaredNorm);
    var normalized = new double[vector.Length];
    for (var index = 0; index < vector.Length; index += 1)
    {
        normalized[index] = vector[index] / norm;
    }

    return normalized;
}

static double Dot(double[] left, double[] right)
{
    if (left.Length != right.Length)
    {
        throw new InvalidOperationException("Vector dimensions do not match.");
    }

    var sum = 0.0;
    for (var index = 0; index < left.Length; index += 1)
    {
        sum += left[index] * right[index];
    }

    return sum;
}

static SimilaritySummaryRow BuildSummaryRow(string representation, List<double> values)
{
    if (values.Count == 0)
    {
        throw new InvalidOperationException($"No similarity values were computed for representation '{representation}'.");
    }

    values.Sort();

    var min = values[0];
    var max = values[^1];
    var sum = 0.0;
    for (var index = 0; index < values.Count; index += 1)
    {
        sum += values[index];
    }

    var mean = sum / values.Count;
    var varianceSum = 0.0;
    for (var index = 0; index < values.Count; index += 1)
    {
        var deviation = values[index] - mean;
        varianceSum += deviation * deviation;
    }

    return new SimilaritySummaryRow(
        Representation: representation,
        Count: values.Count,
        Min: min,
        P25: Quantile(values, 0.25),
        Median: Quantile(values, 0.50),
        Mean: mean,
        P75: Quantile(values, 0.75),
        P90: Quantile(values, 0.90),
        P95: Quantile(values, 0.95),
        Max: max,
        StdDev: Math.Sqrt(varianceSum / values.Count));
}

static double Quantile(IReadOnlyList<double> sortedValues, double probability)
{
    if (sortedValues.Count == 1)
    {
        return sortedValues[0];
    }

    var position = probability * (sortedValues.Count - 1);
    var lowerIndex = (int)Math.Floor(position);
    var upperIndex = (int)Math.Ceiling(position);

    if (lowerIndex == upperIndex)
    {
        return sortedValues[lowerIndex];
    }

    var weight = position - lowerIndex;
    return sortedValues[lowerIndex] + (sortedValues[upperIndex] - sortedValues[lowerIndex]) * weight;
}

static StreamWriter CreateWriter(string path)
{
    var directory = Path.GetDirectoryName(path);
    if (!string.IsNullOrWhiteSpace(directory))
    {
        Directory.CreateDirectory(directory);
    }

    return new StreamWriter(path, false, new UTF8Encoding(false));
}

static void WriteCsvRow(TextWriter writer, IReadOnlyList<string?> values)
{
    writer.WriteLine(string.Join(",", values.Select(EscapeCsv)));
}

static string EscapeCsv(string? value)
{
    if (value is null)
    {
        return string.Empty;
    }

    if (!value.Contains('"') && !value.Contains(',') && !value.Contains('\n') && !value.Contains('\r'))
    {
        return value;
    }

    return $"\"{value.Replace("\"", "\"\"", StringComparison.Ordinal)}\"";
}

static string FormatDouble(double value) =>
    value.ToString("0.######", CultureInfo.InvariantCulture);

static string FormatBoolean(bool value) => value ? "true" : "false";

internal sealed record BaseRow(
    string TextInstanceId,
    string Name,
    string Description,
    string RequiresManualValidationText,
    string NameVectorText,
    string DescriptionVectorText);

internal sealed record TextInstance(
    string TextInstanceId,
    string Name,
    string Description,
    bool RequiresManualValidation,
    double[] NameVector,
    double[] DescriptionVector);

internal sealed record CandidatePair(
    string PairId,
    string TextInstanceId1,
    string TextInstanceId2,
    string Name1,
    string Description1,
    string Name2,
    string Description2,
    bool ExactNameMatch,
    bool ExactDescriptionMatch,
    string ReviewStratum,
    bool RequiresManualValidation,
    double CosineNameOnly,
    double CosineNameDescription);

internal sealed record SimilaritySummaryRow(
    string Representation,
    int Count,
    double Min,
    double P25,
    double Median,
    double Mean,
    double P75,
    double P90,
    double P95,
    double Max,
    double StdDev);
