using System.Globalization;
using System.Text;

const int MaxFolds = 5;
const double LossEpsilon = 1e-6;

var root = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));
var harmonizedPath = Path.Combine(root, "data_processed", "04_skills_harmonized.csv");
var fullGraphsDirectory = Path.Combine(root, "outputs", "graphs_full");
var sparseDirectory = Path.Combine(root, "outputs", "graphs_sparse");
Directory.CreateDirectory(sparseDirectory);

var levelSpecs = new[]
{
    new LevelSpec("pooled", "06_weighted_edges_pooled.csv", "07_selected_graphs_pooled.csv", "07_edge_selection_probabilities_pooled.csv"),
    new LevelSpec("track", "06_weighted_edges_tracks.csv", "07_selected_graphs_tracks.csv", "07_edge_selection_probabilities_tracks.csv"),
    new LevelSpec("section", "06_weighted_edges_sections.csv", "07_selected_graphs_sections.csv", "07_edge_selection_probabilities_sections.csv"),
    new LevelSpec("programme", "06_weighted_edges_programmes.csv", "07_selected_graphs_programmes.csv", "07_edge_selection_probabilities_programmes.csv"),
    new LevelSpec("programme_year", "06_weighted_edges_programme_years.csv", "07_selected_graphs_programme_years.csv", "07_edge_selection_probabilities_programme_years.csv")
};

if (!File.Exists(harmonizedPath))
{
    throw new FileNotFoundException($"Required Step 7 input not found: {harmonizedPath}");
}

foreach (var spec in levelSpecs)
{
    var candidate = Path.Combine(fullGraphsDirectory, spec.FullEdgesFileName);
    if (!File.Exists(candidate))
    {
        throw new FileNotFoundException($"Required Step 7 input not found: {candidate}");
    }
}

var unitsByLevel = BuildUnits(harmonizedPath, levelSpecs);
LoadFullGraphs(unitsByLevel, fullGraphsDirectory, levelSpecs);

var surfaceRows = new List<ModelRow>();
var selectedRows = new List<SelectedRow>();
var summaryRows = new List<SummaryRow>();

foreach (var spec in levelSpecs)
{
    var units = unitsByLevel[spec.Level]
        .Values
        .OrderBy(x => x.UnitId, StringComparer.Ordinal)
        .ToArray();

    var levelModelRows = new List<ModelRow>();
    foreach (var sourceRepresentation in new[] { "name_only", "name_description" })
    {
        var representationFamily = MapRepresentationFamily(sourceRepresentation);
        var events = new List<EdgeEvent>();
        long totalPairEvaluations = 0;
        var unitsWithGraphs = 0;

        foreach (var unit in units)
        {
            if (!unit.Graphs.TryGetValue(sourceRepresentation, out var graph))
            {
                continue;
            }

            unitsWithGraphs += 1;
            var foldPlan = BuildFoldPlan(unit);
            foreach (var foldIndex in Enumerable.Range(0, foldPlan.FoldCount))
            {
                var trainCounts = new int[unit.NodeIds.Count];
                var holdoutCounts = new int[unit.NodeIds.Count];
                var trainOccurrences = 0;

                for (var occurrenceIndex = 0; occurrenceIndex < unit.OccurrenceNodeIndices.Count; occurrenceIndex += 1)
                {
                    var nodeIndex = unit.OccurrenceNodeIndices[occurrenceIndex];
                    if (foldPlan.Assignments[occurrenceIndex] == foldIndex)
                    {
                        holdoutCounts[nodeIndex] += 1;
                    }
                    else
                    {
                        trainCounts[nodeIndex] += 1;
                        trainOccurrences += 1;
                    }
                }

                totalPairEvaluations += Combination2(unit.NodeIds.Count);
                foreach (var edge in graph.Edges)
                {
                    var trainProbability = PairBootstrapPresenceProbability(
                        trainCounts[edge.SourceIndex],
                        trainCounts[edge.TargetIndex],
                        trainOccurrences
                    );
                    var holdoutPositive =
                        holdoutCounts[edge.SourceIndex] > 0 &&
                        holdoutCounts[edge.TargetIndex] > 0;

                    var modelLoss = holdoutPositive
                        ? -Math.Log(ClampProbability(trainProbability))
                        : -Math.Log(ClampProbability(1d - trainProbability));

                    events.Add(new EdgeEvent(edge.Weight, holdoutPositive ? 1L : 0L, modelLoss));
                }
            }
        }

        if (events.Count == 0 || totalPairEvaluations == 0)
        {
            continue;
        }

        events.Sort(static (left, right) => right.Weight.CompareTo(left.Weight));

        long cumulativePositiveEdges = 0;
        long cumulativeCandidateEdges = 0;
        double cumulativeModelLoss = 0d;

        for (var cursor = 0; cursor < events.Count;)
        {
            var threshold = events[cursor].Weight;
            long groupedPositiveEdges = 0;
            long groupedCandidateEdges = 0;
            double groupedModelLoss = 0d;

            while (cursor < events.Count && events[cursor].Weight == threshold)
            {
                groupedPositiveEdges += events[cursor].HoldoutPositive;
                groupedCandidateEdges += 1;
                groupedModelLoss += events[cursor].ModelLossContribution;
                cursor += 1;
            }

            cumulativePositiveEdges += groupedPositiveEdges;
            cumulativeCandidateEdges += groupedCandidateEdges;
            cumulativeModelLoss += groupedModelLoss;

            var cvLogLoss = cumulativeModelLoss / totalPairEvaluations;
            var baselineLoss = BaseRateLogLoss(cumulativePositiveEdges, totalPairEvaluations);
            var cvSkill = baselineLoss <= 0d ? 0d : 1d - (cumulativeModelLoss / baselineLoss);

            levelModelRows.Add(new ModelRow(
                spec.Level,
                representationFamily,
                sourceRepresentation,
                threshold,
                cvLogLoss,
                cvSkill,
                unitsWithGraphs,
                cumulativeCandidateEdges,
                totalPairEvaluations,
                false
            ));
        }
    }

    if (levelModelRows.Count == 0)
    {
        continue;
    }

    var bestRow = levelModelRows
        .OrderByDescending(x => x.CvSkill)
        .ThenBy(x => x.CvLogLoss)
        .ThenByDescending(x => x.Threshold)
        .ThenBy(x => x.RepresentationFamily, StringComparer.Ordinal)
        .First();

    var sparsificationSupported = bestRow.CvSkill > 0d;
    var selectedGraphMode = sparsificationSupported ? "thresholded_sparse" : "full_weighted_graph";
    var selectionNotes = sparsificationSupported
        ? "Selected by maximizing cross-validated log-loss skill at this aggregation level."
        : "Best cross-validated skill did not exceed zero; the full weighted graph is retained for this level.";

    foreach (var row in levelModelRows)
    {
        surfaceRows.Add(row with
        {
            SelectedFlag =
                row.Level == bestRow.Level &&
                row.RepresentationFamily == bestRow.RepresentationFamily &&
                row.SourceRepresentation == bestRow.SourceRepresentation &&
                row.Threshold == bestRow.Threshold
        });
    }

    selectedRows.Add(new SelectedRow(
        spec.Level,
        bestRow.RepresentationFamily,
        bestRow.SourceRepresentation,
        bestRow.Threshold,
        bestRow.CvSkill,
        bestRow.CvLogLoss,
        bestRow.UnitCount,
        bestRow.CandidateEdgeCount,
        bestRow.TotalPairEvaluations,
        sparsificationSupported,
        selectedGraphMode,
        selectionNotes
    ));

    using var selectedGraphWriter = CreateWriterWithHeader(
        Path.Combine(sparseDirectory, spec.SelectedGraphsFileName),
        new[]
        {
            "level","unit_type","unit_id","selected_representation_family","selected_source_representation",
            "sparsification_supported","selected_graph_mode","selected_threshold","source_node_id","source_node_name",
            "target_node_id","target_node_name","edge_weight"
        }
    );

    using var probabilityWriter = CreateWriterWithHeader(
        Path.Combine(sparseDirectory, spec.SelectionProbabilityFileName),
        new[]
        {
            "level","unit_type","unit_id","selected_representation_family","selected_source_representation",
            "sparsification_supported","selected_graph_mode","selected_threshold","source_node_id","source_node_name",
            "target_node_id","target_node_name","full_edge_weight","selected_edge_flag","edge_selection_probability",
            "node_a_occurrence_count","node_b_occurrence_count","unit_occurrence_count"
        }
    );

    foreach (var unit in units)
    {
        if (!unit.Graphs.TryGetValue(bestRow.SourceRepresentation, out var graph))
        {
            continue;
        }

        var retainedEdges = new List<Edge>();
        var fullOccurrenceCount = unit.OccurrenceNodeIndices.Count;

        foreach (var edge in graph.Edges)
        {
            var nodeACount = unit.FullNodeOccurrenceCounts[edge.SourceIndex];
            var nodeBCount = unit.FullNodeOccurrenceCounts[edge.TargetIndex];
            var selectionProbability = sparsificationSupported
                ? PairBootstrapPresenceProbability(nodeACount, nodeBCount, fullOccurrenceCount)
                : 1d;
            var selectedEdge = !sparsificationSupported || edge.Weight >= bestRow.Threshold;

            WriteRow(
                probabilityWriter,
                new[]
                {
                    spec.Level,unit.UnitType,unit.UnitId,bestRow.RepresentationFamily,bestRow.SourceRepresentation,
                    ToBooleanString(sparsificationSupported),selectedGraphMode,FormatNumber(bestRow.Threshold),
                    unit.NodeIds[edge.SourceIndex],unit.NodeNames[edge.SourceIndex],unit.NodeIds[edge.TargetIndex],
                    unit.NodeNames[edge.TargetIndex],FormatNumber(edge.Weight),ToBooleanString(selectedEdge),
                    FormatNumber(selectedEdge ? selectionProbability : 0d),nodeACount.ToString(CultureInfo.InvariantCulture),
                    nodeBCount.ToString(CultureInfo.InvariantCulture),fullOccurrenceCount.ToString(CultureInfo.InvariantCulture)
                }
            );

            if (!selectedEdge)
            {
                continue;
            }

            retainedEdges.Add(edge);
            WriteRow(
                selectedGraphWriter,
                new[]
                {
                    spec.Level,unit.UnitType,unit.UnitId,bestRow.RepresentationFamily,bestRow.SourceRepresentation,
                    ToBooleanString(sparsificationSupported),selectedGraphMode,FormatNumber(bestRow.Threshold),
                    unit.NodeIds[edge.SourceIndex],unit.NodeNames[edge.SourceIndex],unit.NodeIds[edge.TargetIndex],
                    unit.NodeNames[edge.TargetIndex],FormatNumber(edge.Weight)
                }
            );
        }

        var metrics = ComputeGraphMetrics(unit.NodeIds.Count, retainedEdges);
        summaryRows.Add(new SummaryRow(
            spec.Level,
            unit.UnitType,
            unit.UnitId,
            bestRow.RepresentationFamily,
            bestRow.SourceRepresentation,
            sparsificationSupported,
            selectedGraphMode,
            bestRow.Threshold,
            unit.NodeIds.Count,
            retainedEdges.Count,
            metrics.Density,
            metrics.ComponentCount,
            metrics.LargestComponentSize,
            metrics.LargestComponentShare,
            metrics.IsolatedNodeCount,
            metrics.IsolateShare,
            metrics.ConnectedNodeShare
        ));
    }
}

WriteCsv(
    Path.Combine(sparseDirectory, "07_levelwise_model_selection_surface.csv"),
    new[]
    {
        "level","representation_family","source_representation","threshold","cv_logloss","cv_skill",
        "n_units","n_candidate_edges","total_pair_evaluations","selected_flag"
    },
    surfaceRows
        .OrderBy(x => x.Level, StringComparer.Ordinal)
        .ThenBy(x => x.RepresentationFamily, StringComparer.Ordinal)
        .ThenByDescending(x => x.Threshold)
        .Select(x => new[]
        {
            x.Level,
            x.RepresentationFamily,
            x.SourceRepresentation,
            FormatNumber(x.Threshold),
            FormatNumber(x.CvLogLoss),
            FormatNumber(x.CvSkill),
            x.UnitCount.ToString(CultureInfo.InvariantCulture),
            x.CandidateEdgeCount.ToString(CultureInfo.InvariantCulture),
            x.TotalPairEvaluations.ToString(CultureInfo.InvariantCulture),
            ToBooleanString(x.SelectedFlag)
        })
);

WriteCsv(
    Path.Combine(sparseDirectory, "07_levelwise_selected_models.csv"),
    new[]
    {
        "level","selected_representation_family","selected_source_representation","selected_threshold",
        "cv_skill","cv_logloss","n_units","n_candidate_edges","total_pair_evaluations",
        "sparsification_supported","selected_graph_mode","selection_notes"
    },
    selectedRows
        .OrderBy(x => x.Level, StringComparer.Ordinal)
        .Select(x => new[]
        {
            x.Level,
            x.SelectedRepresentationFamily,
            x.SelectedSourceRepresentation,
            FormatNumber(x.SelectedThreshold),
            FormatNumber(x.CvSkill),
            FormatNumber(x.CvLogLoss),
            x.UnitCount.ToString(CultureInfo.InvariantCulture),
            x.CandidateEdgeCount.ToString(CultureInfo.InvariantCulture),
            x.TotalPairEvaluations.ToString(CultureInfo.InvariantCulture),
            ToBooleanString(x.SparsificationSupported),
            x.SelectedGraphMode,
            x.SelectionNotes
        })
);

WriteCsv(
    Path.Combine(sparseDirectory, "07_selected_graph_summary.csv"),
    new[]
    {
        "level","unit_type","unit_id","selected_representation_family","selected_source_representation",
        "sparsification_supported","selected_graph_mode","selected_threshold","n_nodes","n_retained_edges",
        "density","n_connected_components","largest_component_size","largest_component_share",
        "n_isolated_nodes","isolate_share","connected_node_share"
    },
    summaryRows
        .OrderBy(x => x.Level, StringComparer.Ordinal)
        .ThenBy(x => x.UnitId, StringComparer.Ordinal)
        .Select(x => new[]
        {
            x.Level,
            x.UnitType,
            x.UnitId,
            x.SelectedRepresentationFamily,
            x.SelectedSourceRepresentation,
            ToBooleanString(x.SparsificationSupported),
            x.SelectedGraphMode,
            FormatNumber(x.SelectedThreshold),
            x.NodeCount.ToString(CultureInfo.InvariantCulture),
            x.RetainedEdgeCount.ToString(CultureInfo.InvariantCulture),
            FormatNumber(x.Density),
            x.ConnectedComponentCount.ToString(CultureInfo.InvariantCulture),
            x.LargestComponentSize.ToString(CultureInfo.InvariantCulture),
            FormatNumber(x.LargestComponentShare),
            x.IsolatedNodeCount.ToString(CultureInfo.InvariantCulture),
            FormatNumber(x.IsolateShare),
            FormatNumber(x.ConnectedNodeShare)
        })
);

WriteCsv(
    Path.Combine(sparseDirectory, "07_selection_decision_log.csv"),
    new[] { "decision_key", "decision_value", "rationale" },
    new[]
    {
        new[]
        {
            "selection_framework",
            "levelwise_cross_validated_logloss_skill",
            "Representation and threshold are selected jointly and separately for each aggregation level by maximizing cross-validated skill relative to a holdout edge-rate baseline."
        },
        new[]
        {
            "fold_rule",
            $"deterministic_occurrence_kfold_with_k_capped_at_{MaxFolds}",
            "Occurrence rows are partitioned within each unit into deterministic folds; units with fewer than five occurrences use the maximum feasible number of folds."
        },
        new[]
        {
            "bootstrap_probability_estimator",
            "analytic_with_replacement_presence_probability",
            "Bootstrap edge-retention probabilities are computed analytically from train-fold node occurrence counts instead of estimated with Monte Carlo replicates."
        },
        new[]
        {
            "weight_rebuild_rule",
            "frozen_step6_weights_with_occurrence_presence_resampling",
            "The current implementation keeps Step 6 edge weights fixed and evaluates out-of-sample edge retention through occurrence-level node presence resampling; this is exact for units with one occurrence per node and approximate for collapsed nodes."
        },
        new[]
        {
            "support_rule",
            "best_cv_skill_greater_than_zero",
            "If the best skill at a level does not exceed zero, the final graph for that level reverts to the full weighted graph instead of a thresholded sparse graph."
        },
        new[]
        {
            "tie_break_order",
            "maximize_cv_skill_then_minimize_cv_logloss_then_maximize_threshold",
            "Ties on cross-validated skill are broken by lower average log-loss and then by the larger threshold to prefer the more parsimonious graph when predictive performance is indistinguishable."
        }
    }
);

Console.WriteLine($"Levels processed: {selectedRows.Count}");
Console.WriteLine($"Selection surface rows: {surfaceRows.Count}");

static Dictionary<string, Dictionary<string, UnitData>> BuildUnits(string harmonizedPath, IReadOnlyList<LevelSpec> levelSpecs)
{
    var unitsByLevel = levelSpecs.ToDictionary(
        x => x.Level,
        x => new Dictionary<string, UnitData>(StringComparer.Ordinal),
        StringComparer.Ordinal
    );

    using var reader = new StreamReader(harmonizedPath, Encoding.UTF8);
    var header = ParseCsvLine(reader.ReadLine()!);
    var index = BuildIndex(header);

    while (!reader.EndOfStream)
    {
        var line = reader.ReadLine();
        if (string.IsNullOrWhiteSpace(line))
        {
            continue;
        }

        var fields = ParseCsvLine(line);
        var occurrence = new OccurrenceRow(
            GetField(fields, index, "harmonized_skill_id"),
            GetField(fields, index, "harmonized_name"),
            GetField(fields, index, "section"),
            GetField(fields, index, "programme"),
            GetField(fields, index, "year"),
            GetField(fields, index, "edu_type")
        );

        AddOccurrenceToUnit(unitsByLevel["pooled"], "pooled", "POOLED_ALL", occurrence);
        AddOccurrenceToUnit(unitsByLevel["track"], "track", occurrence.Track, occurrence);
        AddOccurrenceToUnit(unitsByLevel["section"], "section", occurrence.Section, occurrence);
        AddOccurrenceToUnit(unitsByLevel["programme"], "programme", occurrence.Programme, occurrence);
        AddOccurrenceToUnit(unitsByLevel["programme_year"], "programme_year", $"{occurrence.Programme}__{occurrence.Year}", occurrence);
    }

    foreach (var levelUnits in unitsByLevel.Values)
    {
        foreach (var unit in levelUnits.Values)
        {
            unit.FullNodeOccurrenceCounts = new int[unit.NodeIds.Count];
            foreach (var nodeIndex in unit.OccurrenceNodeIndices)
            {
                unit.FullNodeOccurrenceCounts[nodeIndex] += 1;
            }
        }
    }

    return unitsByLevel;
}

static void AddOccurrenceToUnit(
    Dictionary<string, UnitData> units,
    string unitType,
    string unitId,
    OccurrenceRow occurrence
)
{
    if (string.IsNullOrWhiteSpace(unitId))
    {
        return;
    }

    if (!units.TryGetValue(unitId, out var unit))
    {
        unit = new UnitData(unitType, unitId);
        units[unitId] = unit;
    }

    if (!unit.NodeIndex.TryGetValue(occurrence.HarmonizedSkillId, out var nodeIndex))
    {
        nodeIndex = unit.NodeIds.Count;
        unit.NodeIndex[occurrence.HarmonizedSkillId] = nodeIndex;
        unit.NodeIds.Add(occurrence.HarmonizedSkillId);
        unit.NodeNames.Add(occurrence.HarmonizedName);
    }

    unit.OccurrenceNodeIndices.Add(nodeIndex);
}

static void LoadFullGraphs(
    Dictionary<string, Dictionary<string, UnitData>> unitsByLevel,
    string fullGraphsDirectory,
    IReadOnlyList<LevelSpec> levelSpecs
)
{
    foreach (var spec in levelSpecs)
    {
        var path = Path.Combine(fullGraphsDirectory, spec.FullEdgesFileName);
        using var reader = new StreamReader(path, Encoding.UTF8);
        var header = ParseCsvLine(reader.ReadLine()!);
        var index = BuildIndex(header);

        while (!reader.EndOfStream)
        {
            var line = reader.ReadLine();
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            var fields = ParseCsvLine(line);
            var unitId = GetField(fields, index, "unit_id");
            var sourceRepresentation = GetField(fields, index, "representation");
            var nodeA = GetField(fields, index, "harmonized_skill_id_1");
            var nodeB = GetField(fields, index, "harmonized_skill_id_2");
            var weight = double.Parse(GetField(fields, index, "edge_weight"), CultureInfo.InvariantCulture);

            var unit = unitsByLevel[spec.Level][unitId];
            if (!unit.Graphs.TryGetValue(sourceRepresentation, out var graph))
            {
                graph = new GraphData(sourceRepresentation, MapRepresentationFamily(sourceRepresentation));
                unit.Graphs[sourceRepresentation] = graph;
            }

            graph.Edges.Add(new Edge(unit.NodeIndex[nodeA], unit.NodeIndex[nodeB], weight));
        }
    }
}

static FoldPlan BuildFoldPlan(UnitData unit)
{
    var occurrenceCount = unit.OccurrenceNodeIndices.Count;
    if (occurrenceCount <= 1)
    {
        return new FoldPlan(1, new[] { 0 });
    }

    var foldCount = Math.Min(MaxFolds, occurrenceCount);
    var assignments = new int[occurrenceCount];
    var order = Enumerable.Range(0, occurrenceCount).ToArray();
    Shuffle(order, StableSeed(unit.UnitType, unit.UnitId));

    for (var index = 0; index < order.Length; index += 1)
    {
        assignments[order[index]] = index % foldCount;
    }

    return new FoldPlan(foldCount, assignments);
}

static long Combination2(int count) => count < 2 ? 0L : (long)count * (count - 1L) / 2L;

static double PairBootstrapPresenceProbability(int nodeACount, int nodeBCount, int sampleSize)
{
    if (sampleSize <= 0 || nodeACount <= 0 || nodeBCount <= 0)
    {
        return 0d;
    }

    var remainingAfterA = Math.Max(0, sampleSize - nodeACount);
    var remainingAfterB = Math.Max(0, sampleSize - nodeBCount);
    var remainingAfterBoth = Math.Max(0, sampleSize - nodeACount - nodeBCount);

    var pAAbsent = Math.Pow(remainingAfterA / (double)sampleSize, sampleSize);
    var pBAbsent = Math.Pow(remainingAfterB / (double)sampleSize, sampleSize);
    var pBothAbsent = Math.Pow(remainingAfterBoth / (double)sampleSize, sampleSize);

    return Math.Clamp(1d - pAAbsent - pBAbsent + pBothAbsent, 0d, 1d);
}

static double BaseRateLogLoss(long positiveCount, long totalCount)
{
    if (totalCount <= 0)
    {
        return 0d;
    }

    var rate = ClampProbability(positiveCount / (double)totalCount);
    return
        positiveCount * -Math.Log(rate) +
        (totalCount - positiveCount) * -Math.Log(1d - rate);
}

static double ClampProbability(double value) => Math.Clamp(value, LossEpsilon, 1d - LossEpsilon);

static GraphMetrics ComputeGraphMetrics(int nodeCount, IReadOnlyList<Edge> edges)
{
    var degrees = new int[nodeCount];
    var dsu = new DisjointSet(nodeCount);

    foreach (var edge in edges)
    {
        degrees[edge.SourceIndex] += 1;
        degrees[edge.TargetIndex] += 1;
        dsu.Union(edge.SourceIndex, edge.TargetIndex);
    }

    var componentSizes = dsu.ComponentSizes();
    var componentCount = componentSizes.Count;
    var largestComponentSize = componentSizes.Count == 0 ? 0 : componentSizes.Max();
    var isolatedNodeCount = degrees.Count(x => x == 0);
    var possibleEdges = Combination2(nodeCount);
    var density = possibleEdges == 0 ? 0d : edges.Count / (double)possibleEdges;
    var largestComponentShare = nodeCount == 0 ? 0d : largestComponentSize / (double)nodeCount;
    var isolateShare = nodeCount == 0 ? 0d : isolatedNodeCount / (double)nodeCount;
    var connectedNodeShare = nodeCount == 0 ? 0d : (nodeCount - isolatedNodeCount) / (double)nodeCount;

    return new GraphMetrics(
        density,
        componentCount,
        largestComponentSize,
        largestComponentShare,
        isolatedNodeCount,
        isolateShare,
        connectedNodeShare
    );
}

static void Shuffle(int[] values, int seed)
{
    var random = new Random(seed);
    for (var index = values.Length - 1; index > 0; index -= 1)
    {
        var swapIndex = random.Next(index + 1);
        (values[index], values[swapIndex]) = (values[swapIndex], values[index]);
    }
}

static int StableSeed(string left, string right)
{
    unchecked
    {
        const int offset = unchecked((int)2166136261);
        const int prime = 16777619;
        var hash = offset;
        foreach (var ch in $"{left}||{right}")
        {
            hash ^= ch;
            hash *= prime;
        }
        return hash;
    }
}

static string MapRepresentationFamily(string sourceRepresentation) =>
    sourceRepresentation == "name_description" ? "concat" : "name_only";

static StreamWriter CreateWriterWithHeader(string path, IReadOnlyList<string> header)
{
    var directory = Path.GetDirectoryName(path);
    if (!string.IsNullOrWhiteSpace(directory))
    {
        Directory.CreateDirectory(directory);
    }

    var writer = new StreamWriter(path, false, new UTF8Encoding(false));
    WriteRow(writer, header);
    return writer;
}

static void WriteCsv(string path, IReadOnlyList<string> header, IEnumerable<IReadOnlyList<string>> rows)
{
    using var writer = CreateWriterWithHeader(path, header);
    foreach (var row in rows)
    {
        WriteRow(writer, row);
    }
}

static void WriteRow(TextWriter writer, IReadOnlyList<string> values)
{
    for (var index = 0; index < values.Count; index += 1)
    {
        if (index > 0)
        {
            writer.Write(',');
        }
        writer.Write(Escape(values[index]));
    }
    writer.WriteLine();
}

static string Escape(string value) =>
    value.IndexOfAny(new[] { ',', '"', '\r', '\n' }) < 0
        ? value
        : "\"" + value.Replace("\"", "\"\"") + "\"";

static string[] ParseCsvLine(string line)
{
    var fields = new List<string>();
    var builder = new StringBuilder();
    var quoted = false;

    for (var index = 0; index < line.Length; index += 1)
    {
        var current = line[index];
        if (quoted)
        {
            if (current == '"')
            {
                if (index + 1 < line.Length && line[index + 1] == '"')
                {
                    builder.Append('"');
                    index += 1;
                }
                else
                {
                    quoted = false;
                }
            }
            else
            {
                builder.Append(current);
            }
        }
        else
        {
            if (current == ',')
            {
                fields.Add(builder.ToString());
                builder.Clear();
            }
            else if (current == '"')
            {
                quoted = true;
            }
            else
            {
                builder.Append(current);
            }
        }
    }

    fields.Add(builder.ToString());
    return fields.ToArray();
}

static Dictionary<string, int> BuildIndex(IReadOnlyList<string> header)
{
    var index = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
    for (var position = 0; position < header.Count; position += 1)
    {
        index[header[position]] = position;
    }
    return index;
}

static string GetField(IReadOnlyList<string> fields, IReadOnlyDictionary<string, int> index, string name) =>
    index.TryGetValue(name, out var position) && position < fields.Count ? fields[position] : string.Empty;

static string FormatNumber(double value) =>
    double.IsNaN(value) ? string.Empty : value.ToString("0.############", CultureInfo.InvariantCulture);

static string ToBooleanString(bool value) => value ? "TRUE" : "FALSE";

readonly record struct LevelSpec(
    string Level,
    string FullEdgesFileName,
    string SelectedGraphsFileName,
    string SelectionProbabilityFileName
);

sealed class UnitData
{
    public UnitData(string unitType, string unitId)
    {
        UnitType = unitType;
        UnitId = unitId;
    }

    public string UnitType { get; }
    public string UnitId { get; }
    public Dictionary<string, int> NodeIndex { get; } = new(StringComparer.Ordinal);
    public List<string> NodeIds { get; } = new();
    public List<string> NodeNames { get; } = new();
    public List<int> OccurrenceNodeIndices { get; } = new();
    public int[] FullNodeOccurrenceCounts { get; set; } = Array.Empty<int>();
    public Dictionary<string, GraphData> Graphs { get; } = new(StringComparer.Ordinal);
}

sealed class GraphData
{
    public GraphData(string sourceRepresentation, string representationFamily)
    {
        SourceRepresentation = sourceRepresentation;
        RepresentationFamily = representationFamily;
    }

    public string SourceRepresentation { get; }
    public string RepresentationFamily { get; }
    public List<Edge> Edges { get; } = new();
}

readonly record struct OccurrenceRow(
    string HarmonizedSkillId,
    string HarmonizedName,
    string Section,
    string Programme,
    string Year,
    string Track
);

readonly record struct Edge(int SourceIndex, int TargetIndex, double Weight);
readonly record struct FoldPlan(int FoldCount, int[] Assignments);
readonly record struct EdgeEvent(double Weight, long HoldoutPositive, double ModelLossContribution);
readonly record struct ModelRow(string Level, string RepresentationFamily, string SourceRepresentation, double Threshold, double CvLogLoss, double CvSkill, int UnitCount, long CandidateEdgeCount, long TotalPairEvaluations, bool SelectedFlag);
readonly record struct SelectedRow(string Level, string SelectedRepresentationFamily, string SelectedSourceRepresentation, double SelectedThreshold, double CvSkill, double CvLogLoss, int UnitCount, long CandidateEdgeCount, long TotalPairEvaluations, bool SparsificationSupported, string SelectedGraphMode, string SelectionNotes);
readonly record struct SummaryRow(string Level, string UnitType, string UnitId, string SelectedRepresentationFamily, string SelectedSourceRepresentation, bool SparsificationSupported, string SelectedGraphMode, double SelectedThreshold, int NodeCount, int RetainedEdgeCount, double Density, int ConnectedComponentCount, int LargestComponentSize, double LargestComponentShare, int IsolatedNodeCount, double IsolateShare, double ConnectedNodeShare);
readonly record struct GraphMetrics(double Density, int ComponentCount, int LargestComponentSize, double LargestComponentShare, int IsolatedNodeCount, double IsolateShare, double ConnectedNodeShare);

sealed class DisjointSet
{
    private readonly int[] _parent;
    private readonly int[] _size;

    public DisjointSet(int count)
    {
        _parent = new int[count];
        _size = new int[count];
        for (var index = 0; index < count; index += 1)
        {
            _parent[index] = index;
            _size[index] = 1;
        }
    }

    public void Union(int left, int right)
    {
        var rootLeft = Find(left);
        var rootRight = Find(right);
        if (rootLeft == rootRight)
        {
            return;
        }

        if (_size[rootLeft] < _size[rootRight])
        {
            (rootLeft, rootRight) = (rootRight, rootLeft);
        }

        _parent[rootRight] = rootLeft;
        _size[rootLeft] += _size[rootRight];
    }

    public IReadOnlyList<int> ComponentSizes()
    {
        var map = new Dictionary<int, int>();
        for (var index = 0; index < _parent.Length; index += 1)
        {
            var root = Find(index);
            map[root] = map.TryGetValue(root, out var count) ? count + 1 : 1;
        }
        return map.Values.ToArray();
    }

    private int Find(int value)
    {
        if (_parent[value] != value)
        {
            _parent[value] = Find(_parent[value]);
        }
        return _parent[value];
    }
}
