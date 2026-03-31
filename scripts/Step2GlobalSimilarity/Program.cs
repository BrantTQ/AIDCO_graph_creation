using System.Globalization;
using System.Text;
using System.Text.Json;

var repoRoot = Directory.GetCurrentDirectory();
var inputPath = Path.Combine(repoRoot, "data_processed", "01_unique_skills_vectors.csv");
var outputDir = Path.Combine(repoRoot, "outputs", "similarity_tables");

if (!File.Exists(inputPath))
{
    throw new FileNotFoundException($"Unique skills base file not found at '{inputPath}'.");
}

Directory.CreateDirectory(outputDir);

var baseRows = ReadBaseRows(inputPath);
if (baseRows.Count == 0)
{
    throw new InvalidOperationException("The unique skills base file is empty.");
}

var skills = baseRows
    .OrderBy(row => row.Name, StringComparer.Ordinal)
    .Select((row, index) => new UniqueSkill(
        SkillId: $"SK_{index + 1:D4}",
        Name: row.Name,
        NameVector: ParseVector(row.NameVectorText, "name_vector", row.Name),
        DescriptionVector: ParseVector(row.DescriptionVectorText, "description_vector", row.Name)
    ))
    .ToList();

ValidateDimensions(skills);

Console.WriteLine($"Loaded {skills.Count.ToString(CultureInfo.InvariantCulture)} unique skill rows.");

var exactNameGroups = skills
    .GroupBy(skill => skill.Name, StringComparer.Ordinal)
    .Where(group => group.Count() > 1)
    .OrderByDescending(group => group.Count())
    .ThenBy(group => group.Key, StringComparer.Ordinal)
    .ToList();

var exactNameGroupsPath = Path.Combine(outputDir, "02_exact_name_groups.csv");
using (var writer = new StreamWriter(exactNameGroupsPath, false, new UTF8Encoding(false)))
{
    WriteCsvRow(writer, "exact_name_group_id", "name", "n_skills", "skill_ids");

    for (var groupIndex = 0; groupIndex < exactNameGroups.Count; groupIndex += 1)
    {
        var group = exactNameGroups[groupIndex].ToList();
        WriteCsvRow(
            writer,
            $"ENG_{groupIndex + 1:D4}",
            group[0].Name,
            group.Count.ToString(CultureInfo.InvariantCulture),
            string.Join("; ", group.Select(skill => skill.SkillId))
        );
    }
}

var totalUnorderedPairs = (long)skills.Count * (skills.Count - 1) / 2;
var sameNamePairCount = exactNameGroups
    .Select(group => (long)group.Count() * (group.Count() - 1) / 2)
    .Sum();
var screenedPairCount = totalUnorderedPairs - sameNamePairCount;

var normalizedNameVectors = skills
    .Select(skill => NormalizeVector(skill.NameVector, "name_vector", skill.Name))
    .ToArray();
var normalizedDescriptionVectors = skills
    .Select(skill => NormalizeVector(skill.DescriptionVector, "description_vector", skill.Name))
    .ToArray();

var nameOnlySimilarities = new List<double>(checked((int)screenedPairCount));
var combinedSimilarities = new List<double>(checked((int)screenedPairCount));

var pairwisePath = Path.Combine(outputDir, "02_global_pairwise_similarity.csv");
using (var writer = new StreamWriter(pairwisePath, false, new UTF8Encoding(false)))
{
    WriteCsvRow(
        writer,
        "pair_id",
        "skill_id_1",
        "skill_id_2",
        "name_1",
        "name_2",
        "cosine_name_only",
        "cosine_name_description"
    );

    long pairCounter = 0;
    for (var leftIndex = 0; leftIndex < skills.Count; leftIndex += 1)
    {
        var leftSkill = skills[leftIndex];
        var leftNameVector = normalizedNameVectors[leftIndex];
        var leftDescriptionVector = normalizedDescriptionVectors[leftIndex];

        for (var rightIndex = leftIndex + 1; rightIndex < skills.Count; rightIndex += 1)
        {
            var rightSkill = skills[rightIndex];
            if (string.Equals(leftSkill.Name, rightSkill.Name, StringComparison.Ordinal))
            {
                continue;
            }

            var cosineNameOnly = Dot(leftNameVector, normalizedNameVectors[rightIndex]);

            // For equal-length sub-vectors, cosine over the normalized concatenation is
            // equivalent to the average of the normalized name and description cosines.
            var cosineNameDescription =
                (cosineNameOnly + Dot(leftDescriptionVector, normalizedDescriptionVectors[rightIndex])) / 2.0;

            pairCounter += 1;
            nameOnlySimilarities.Add(cosineNameOnly);
            combinedSimilarities.Add(cosineNameDescription);

            WriteCsvRow(
                writer,
                $"PAIR_{pairCounter:D6}",
                leftSkill.SkillId,
                rightSkill.SkillId,
                leftSkill.Name,
                rightSkill.Name,
                FormatDouble(cosineNameOnly),
                FormatDouble(cosineNameDescription)
            );
        }
    }
}

if (nameOnlySimilarities.Count != screenedPairCount || combinedSimilarities.Count != screenedPairCount)
{
    throw new InvalidOperationException("The computed pair count does not match the expected screened pair count.");
}

var summaryRows = new[]
{
    BuildSummaryRow("name_only", nameOnlySimilarities),
    BuildSummaryRow("name_description", combinedSimilarities)
};

var summaryPath = Path.Combine(outputDir, "02_similarity_summary.csv");
using (var writer = new StreamWriter(summaryPath, false, new UTF8Encoding(false)))
{
    WriteCsvRow(
        writer,
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
    );

    foreach (var row in summaryRows)
    {
        WriteCsvRow(
            writer,
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
        );
    }
}

var cutoffSelectionPath = Path.Combine(outputDir, "02_cutoff_selection.csv");
using (var writer = new StreamWriter(cutoffSelectionPath, false, new UTF8Encoding(false)))
{
    WriteCsvRow(
        writer,
        "chosen_cutoff_name_only",
        "chosen_cutoff_name_description",
        "chosen_representation",
        "notes"
    );
    WriteCsvRow(
        writer,
        string.Empty,
        string.Empty,
        string.Empty,
        "Base file is already deduplicated by exact skill name; fill the chosen cutoffs after inspecting the pairwise and summary files."
    );
}

Console.WriteLine($"Exact-name groups: {exactNameGroups.Count.ToString(CultureInfo.InvariantCulture)}");
Console.WriteLine($"Same-name unordered pairs excluded: {sameNamePairCount.ToString(CultureInfo.InvariantCulture)}");
Console.WriteLine($"Different-name unordered pairs written: {screenedPairCount.ToString(CultureInfo.InvariantCulture)}");

static List<BaseRow> ReadBaseRows(string path)
{
    using var reader = new StreamReader(path);
    var headerLine = reader.ReadLine() ?? throw new InvalidOperationException("The unique skills base file has no header row.");
    var header = ParseCsvLine(headerLine);

    if (header.Count != 3 ||
        !string.Equals(header[0], "name", StringComparison.OrdinalIgnoreCase) ||
        !string.Equals(header[1], "name_vector", StringComparison.OrdinalIgnoreCase) ||
        !string.Equals(header[2], "description_vector", StringComparison.OrdinalIgnoreCase))
    {
        throw new InvalidOperationException("Unexpected header in the unique skills base file. Expected: name, name_vector, description_vector.");
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
        if (fields.Count != 3)
        {
            throw new InvalidOperationException($"Expected 3 columns in the unique skills base file, found {fields.Count.ToString(CultureInfo.InvariantCulture)}.");
        }

        rows.Add(new BaseRow(fields[0], fields[1], fields[2]));
    }

    return rows;
}

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

static double[] ParseVector(string vectorText, string fieldName, string skillName)
{
    var vector = JsonSerializer.Deserialize<double[]>(vectorText);
    if (vector is null || vector.Length == 0)
    {
        throw new InvalidOperationException($"Skill '{skillName}' has an invalid {fieldName} value.");
    }

    return vector;
}

static void ValidateDimensions(IReadOnlyList<UniqueSkill> skills)
{
    var expectedNameDimension = skills[0].NameVector.Length;
    var expectedDescriptionDimension = skills[0].DescriptionVector.Length;

    foreach (var skill in skills)
    {
        if (skill.NameVector.Length != expectedNameDimension)
        {
            throw new InvalidOperationException($"Skill '{skill.Name}' has name_vector dimension {skill.NameVector.Length.ToString(CultureInfo.InvariantCulture)} instead of {expectedNameDimension.ToString(CultureInfo.InvariantCulture)}.");
        }

        if (skill.DescriptionVector.Length != expectedDescriptionDimension)
        {
            throw new InvalidOperationException($"Skill '{skill.Name}' has description_vector dimension {skill.DescriptionVector.Length.ToString(CultureInfo.InvariantCulture)} instead of {expectedDescriptionDimension.ToString(CultureInfo.InvariantCulture)}.");
        }
    }
}

static double[] NormalizeVector(double[] vector, string fieldName, string skillName)
{
    var squaredNorm = 0.0;
    for (var index = 0; index < vector.Length; index += 1)
    {
        squaredNorm += vector[index] * vector[index];
    }

    if (squaredNorm <= 0.0)
    {
        throw new InvalidOperationException($"Skill '{skillName}' has a zero-norm {fieldName}.");
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
        StdDev: Math.Sqrt(varianceSum / values.Count)
    );
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

static string FormatDouble(double value) =>
    value.ToString("F6", CultureInfo.InvariantCulture);

static void WriteCsvRow(StreamWriter writer, params string?[] values)
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

internal sealed record BaseRow(string Name, string NameVectorText, string DescriptionVectorText);

internal sealed record UniqueSkill(string SkillId, string Name, double[] NameVector, double[] DescriptionVector);

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
    double StdDev
);
