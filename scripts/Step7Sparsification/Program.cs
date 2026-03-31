using System.Globalization;
using System.Numerics;
using System.Text;

const double LambdaMin = 0.90;
const double IotaMax = 0.10;
const double SusceptibilityTolerance = 1e-12;

var workspaceRoot = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));
var graphsFullDirectory = Path.Combine(workspaceRoot, "outputs", "graphs_full");
var graphsSparseDirectory = Path.Combine(workspaceRoot, "outputs", "graphs_sparse");
var harmonizedDatasetPath = Path.Combine(workspaceRoot, "data_processed", "04_skills_harmonized.csv");
var pooledWeightedEdgesPath = Path.Combine(graphsFullDirectory, "06_weighted_edges_pooled.csv");

Directory.CreateDirectory(graphsSparseDirectory);

foreach (var requiredPath in new[] { harmonizedDatasetPath, pooledWeightedEdgesPath })
{
    if (!File.Exists(requiredPath))
    {
        throw new FileNotFoundException("Required Step 7 input not found.", requiredPath);
    }
}

var pooledCutoffsPath = Path.Combine(graphsSparseDirectory, "07_pooled_reference_cutoffs.csv");
var pooledCurvesPath = Path.Combine(graphsSparseDirectory, "07_pooled_reference_susceptibility_curves.csv");
var comparisonSafeAllTracksPath = Path.Combine(graphsSparseDirectory, "07_pooled_reference_sparse_graphs_all_tracks.csv");
var comparisonSafeSectionsPath = Path.Combine(graphsSparseDirectory, "07_pooled_reference_sparse_graphs_sections.csv");
var comparisonSafeTracksPath = Path.Combine(graphsSparseDirectory, "07_pooled_reference_sparse_graphs_tracks.csv");
var comparisonSafeProgrammesPath = Path.Combine(graphsSparseDirectory, "07_pooled_reference_sparse_graphs_programmes.csv");
var comparisonSafeProgrammeYearsPath = Path.Combine(graphsSparseDirectory, "07_pooled_reference_sparse_graphs_programme_years.csv");
var comparisonSafeSummaryPath = Path.Combine(graphsSparseDirectory, "07_pooled_reference_sparse_graph_summary.csv");
var localCutoffsPath = Path.Combine(graphsSparseDirectory, "07_local_diagnostic_cutoffs.csv");
var localCurvesPath = Path.Combine(graphsSparseDirectory, "07_local_diagnostic_susceptibility_curves.csv");
var localSectionsPath = Path.Combine(graphsSparseDirectory, "07_local_diagnostic_sparse_graphs_sections.csv");
var localTracksPath = Path.Combine(graphsSparseDirectory, "07_local_diagnostic_sparse_graphs_tracks.csv");
var localProgrammesPath = Path.Combine(graphsSparseDirectory, "07_local_diagnostic_sparse_graphs_programmes.csv");
var localProgrammeYearsPath = Path.Combine(graphsSparseDirectory, "07_local_diagnostic_sparse_graphs_programme_years.csv");
var localSummaryPath = Path.Combine(graphsSparseDirectory, "07_local_diagnostic_summary.csv");
var decisionLogPath = Path.Combine(graphsSparseDirectory, "07_step7_decision_log.csv");

var decisionLogRows = new List<DecisionLogRow>
{
    new(
        "pooled_reference_usability_rule",
        "lambda_min",
        LambdaMin.ToString("0.##", CultureInfo.InvariantCulture),
        "Minimum acceptable largest-component share for an admissible pooled-reference susceptibility maximizer."),
    new(
        "pooled_reference_usability_rule",
        "iota_max",
        IotaMax.ToString("0.##", CultureInfo.InvariantCulture),
        "Maximum acceptable isolate share for an admissible pooled-reference susceptibility maximizer."),
    new(
        "representation_mapping",
        "name_description_to_concat",
        "enabled",
        "The current pipeline stores the concatenated name-plus-description representation as name_description; Step 7 exports it under the restarted-workflow family label concat."),
    new(
        "representation_availability",
        "fusion",
        "missing",
        "The restarted Step 7 spec mentions fusion, but the current Step 6 outputs contain only name_only and name_description. Step 7 therefore runs on the available families name_only and concat.")
};

var pooledGraphs = LoadPooledGraphs(pooledWeightedEdgesPath);
var availableRepresentations = pooledGraphs
    .OrderBy(graph => graph.RepresentationFamily, StringComparer.Ordinal)
    .Select(graph => new { graph.RepresentationFamily, graph.SourceRepresentation })
    .ToList();

decisionLogRows.AddRange(availableRepresentations.Select(item => new DecisionLogRow(
    "representation_availability",
    item.RepresentationFamily,
    "available",
    $"Loaded from Step 6 source representation {item.SourceRepresentation}.")));

var unitDefinitionsByType = BuildUnitDefinitions(harmonizedDatasetPath);
decisionLogRows.Add(new DecisionLogRow(
    "primary_graph_rule",
    "comparison_safe_graphs",
    "induced_subgraphs_of_pooled_sparse_reference_graph",
    "Sections, tracks, programmes, and programme-year graphs are built as induced subgraphs of the pooled sparse reference graph so that all primary comparisons share the same thresholded universe."));
decisionLogRows.Add(new DecisionLogRow(
    "local_diagnostic_rule",
    "robustness_graphs",
    "local_susceptibility_on_induced_full_pooled_subgraphs",
    "Local robustness graphs are obtained by rerunning the same susceptibility procedure on the full pooled weighted graph induced to each analytical unit."));

var pooledCutoffRows = new List<PooledReferenceCutoffRow>();
var comparisonSafeSummaryRows = new List<ComparisonSafeSummaryRow>();
var localCutoffRows = new List<LocalDiagnosticCutoffRow>();
var localSummaryRows = new List<LocalDiagnosticSummaryRow>();

using var pooledCurvesWriter = CreateWriter(pooledCurvesPath);
WriteCsvRow(pooledCurvesWriter, new[]
{
    "representation_family",
    "source_representation",
    "threshold",
    "susceptibility",
    "n_retained_edges",
    "retained_edge_share",
    "n_connected_components",
    "largest_component_size",
    "largest_component_share",
    "n_isolated_nodes",
    "isolate_share",
    "connected_node_share",
    "is_susceptibility_maximizer",
    "is_admissible_maximizer",
    "is_selected_tau"
});

using var localCurvesWriter = CreateWriter(localCurvesPath);
WriteCsvRow(localCurvesWriter, new[]
{
    "representation_family",
    "source_representation",
    "unit_type",
    "unit_id",
    "threshold",
    "susceptibility",
    "n_retained_edges",
    "retained_edge_share",
    "n_connected_components",
    "largest_component_size",
    "largest_component_share",
    "n_isolated_nodes",
    "isolate_share",
    "connected_node_share",
    "is_susceptibility_maximizer",
    "is_admissible_maximizer",
    "is_selected_tau"
});

using var comparisonSafeAllTracksWriter = CreateSparseEdgeWriter(comparisonSafeAllTracksPath);
using var comparisonSafeSectionsWriter = CreateSparseEdgeWriter(comparisonSafeSectionsPath);
using var comparisonSafeTracksWriter = CreateSparseEdgeWriter(comparisonSafeTracksPath);
using var comparisonSafeProgrammesWriter = CreateSparseEdgeWriter(comparisonSafeProgrammesPath);
using var comparisonSafeProgrammeYearsWriter = CreateSparseEdgeWriter(comparisonSafeProgrammeYearsPath);
using var localSectionsWriter = CreateSparseEdgeWriter(localSectionsPath);
using var localTracksWriter = CreateSparseEdgeWriter(localTracksPath);
using var localProgrammesWriter = CreateSparseEdgeWriter(localProgrammesPath);
using var localProgrammeYearsWriter = CreateSparseEdgeWriter(localProgrammeYearsPath);

var pooledReferenceGraphCount = 0;
var localDiagnosticGraphCount = 0;
var pooledCurveRowCount = 0;
var localCurveRowCount = 0;

foreach (var pooledGraph in pooledGraphs.OrderBy(graph => graph.RepresentationFamily, StringComparer.Ordinal))
{
    pooledReferenceGraphCount += 1;

    var pooledEvaluation = EvaluateGraph(pooledGraph, LambdaMin, IotaMax);

    foreach (var curvePoint in pooledEvaluation.CurvePoints)
    {
        pooledCurveRowCount += 1;
        WriteCsvRow(pooledCurvesWriter, new[]
        {
            pooledGraph.RepresentationFamily,
            pooledGraph.SourceRepresentation,
            FormatDouble(curvePoint.Threshold),
            FormatDouble(curvePoint.Susceptibility),
            curvePoint.RetainedEdgeCount.ToString(CultureInfo.InvariantCulture),
            FormatDouble(curvePoint.RetainedEdgeShare),
            curvePoint.ConnectedComponents.ToString(CultureInfo.InvariantCulture),
            curvePoint.LargestComponentSize.ToString(CultureInfo.InvariantCulture),
            FormatDouble(curvePoint.LargestComponentShare),
            curvePoint.IsolatedNodeCount.ToString(CultureInfo.InvariantCulture),
            FormatDouble(curvePoint.IsolateShare),
            FormatDouble(curvePoint.ConnectedNodeShare),
            FormatBoolean(curvePoint.IsSusceptibilityMaximizer),
            FormatBoolean(curvePoint.IsAdmissibleMaximizer),
            FormatBoolean(curvePoint.IsSelectedTau)
        });
    }

    pooledCutoffRows.Add(new PooledReferenceCutoffRow(
        pooledGraph.RepresentationFamily,
        pooledGraph.SourceRepresentation,
        pooledEvaluation.SelectedThreshold,
        pooledEvaluation.SelectionRule,
        LambdaMin,
        IotaMax,
        pooledEvaluation.MaxSusceptibility,
        pooledEvaluation.MaximizingThresholdCount,
        pooledEvaluation.AdmissibleMaximizingThresholdCount,
        pooledEvaluation.SelectedFromAdmissibleMaximizers,
        pooledGraph.NodeCount,
        pooledEvaluation.SelectedMetrics.RetainedEdgeCount,
        pooledEvaluation.SelectedMetrics.RetainedEdgeShare,
        pooledEvaluation.SelectedMetrics.ConnectedComponents,
        pooledEvaluation.SelectedMetrics.LargestComponentSize,
        pooledEvaluation.SelectedMetrics.LargestComponentShare,
        pooledEvaluation.SelectedMetrics.IsolatedNodeCount,
        pooledEvaluation.SelectedMetrics.IsolateShare,
        pooledEvaluation.SelectedMetrics.ConnectedNodeShare));

    WriteSparseEdges(
        comparisonSafeAllTracksWriter,
        pooledGraph.RepresentationFamily,
        pooledGraph.SourceRepresentation,
        "all_tracks",
        "ALL_TRACKS",
        pooledEvaluation.SelectedThreshold,
        pooledGraph,
        pooledEvaluation.SelectedRetainedEdgeIndexes);

    comparisonSafeSummaryRows.Add(new ComparisonSafeSummaryRow(
        pooledGraph.RepresentationFamily,
        pooledGraph.SourceRepresentation,
        "all_tracks",
        "ALL_TRACKS",
        pooledEvaluation.SelectedThreshold,
        pooledGraph.NodeCount,
        pooledEvaluation.SelectedMetrics.RetainedEdgeCount,
        pooledEvaluation.SelectedMetrics.RetainedEdgeShare,
        pooledEvaluation.SelectedMetrics.Density,
        pooledEvaluation.SelectedMetrics.ConnectedComponents,
        pooledEvaluation.SelectedMetrics.LargestComponentSize,
        pooledEvaluation.SelectedMetrics.LargestComponentShare,
        pooledEvaluation.SelectedMetrics.IsolatedNodeCount,
        pooledEvaluation.SelectedMetrics.IsolateShare,
        pooledEvaluation.SelectedMetrics.ConnectedNodeShare));

    foreach (var unitType in UnitDefinition.UnitTypeOrder)
    {
        var comparisonSafeWriter = GetComparisonSafeWriter(
            unitType,
            comparisonSafeSectionsWriter,
            comparisonSafeTracksWriter,
            comparisonSafeProgrammesWriter,
            comparisonSafeProgrammeYearsWriter);
        var localWriter = GetLocalWriter(
            unitType,
            localSectionsWriter,
            localTracksWriter,
            localProgrammesWriter,
            localProgrammeYearsWriter);

        foreach (var unit in unitDefinitionsByType[unitType])
        {
            var comparisonSafeGraph = BuildInducedSubgraph(
                pooledGraph,
                unit.NodeIdSet,
                pooledEvaluation.SelectedRetainedEdgeIndexes);
            var fullUnitEdgeCount = comparisonSafeGraph.NodeCount < 2
                ? 0
                : comparisonSafeGraph.NodeCount * (comparisonSafeGraph.NodeCount - 1) / 2;

            var comparisonSafeMetrics = ComputeSummaryMetrics(
                comparisonSafeGraph.NodeCount,
                fullUnitEdgeCount,
                comparisonSafeGraph.EdgeCount,
                comparisonSafeGraph.NodeCount == 0
                    ? Array.Empty<int>()
                    : BuildComponentSizes(comparisonSafeGraph.NodeCount, comparisonSafeGraph.Edges));

            WriteSparseEdges(
                comparisonSafeWriter,
                pooledGraph.RepresentationFamily,
                pooledGraph.SourceRepresentation,
                unit.UnitType,
                unit.UnitId,
                pooledEvaluation.SelectedThreshold,
                comparisonSafeGraph);

            comparisonSafeSummaryRows.Add(new ComparisonSafeSummaryRow(
                pooledGraph.RepresentationFamily,
                pooledGraph.SourceRepresentation,
                unit.UnitType,
                unit.UnitId,
                pooledEvaluation.SelectedThreshold,
                comparisonSafeGraph.NodeCount,
                comparisonSafeGraph.EdgeCount,
                comparisonSafeMetrics.RetainedEdgeShare,
                comparisonSafeMetrics.Density,
                comparisonSafeMetrics.ConnectedComponents,
                comparisonSafeMetrics.LargestComponentSize,
                comparisonSafeMetrics.LargestComponentShare,
                comparisonSafeMetrics.IsolatedNodeCount,
                comparisonSafeMetrics.IsolateShare,
                comparisonSafeMetrics.ConnectedNodeShare));

            var localFullGraph = BuildInducedSubgraph(pooledGraph, unit.NodeIdSet);
            var localEvaluation = EvaluateGraph(localFullGraph, LambdaMin, IotaMax);
            localDiagnosticGraphCount += 1;

            foreach (var curvePoint in localEvaluation.CurvePoints)
            {
                localCurveRowCount += 1;
                WriteCsvRow(localCurvesWriter, new[]
                {
                    pooledGraph.RepresentationFamily,
                    pooledGraph.SourceRepresentation,
                    unit.UnitType,
                    unit.UnitId,
                    FormatDouble(curvePoint.Threshold),
                    FormatDouble(curvePoint.Susceptibility),
                    curvePoint.RetainedEdgeCount.ToString(CultureInfo.InvariantCulture),
                    FormatDouble(curvePoint.RetainedEdgeShare),
                    curvePoint.ConnectedComponents.ToString(CultureInfo.InvariantCulture),
                    curvePoint.LargestComponentSize.ToString(CultureInfo.InvariantCulture),
                    FormatDouble(curvePoint.LargestComponentShare),
                    curvePoint.IsolatedNodeCount.ToString(CultureInfo.InvariantCulture),
                    FormatDouble(curvePoint.IsolateShare),
                    FormatDouble(curvePoint.ConnectedNodeShare),
                    FormatBoolean(curvePoint.IsSusceptibilityMaximizer),
                    FormatBoolean(curvePoint.IsAdmissibleMaximizer),
                    FormatBoolean(curvePoint.IsSelectedTau)
                });
            }

            localCutoffRows.Add(new LocalDiagnosticCutoffRow(
                pooledGraph.RepresentationFamily,
                pooledGraph.SourceRepresentation,
                unit.UnitType,
                unit.UnitId,
                localEvaluation.SelectedThreshold,
                pooledEvaluation.SelectedThreshold,
                localEvaluation.SelectionRule,
                localEvaluation.MaxSusceptibility,
                localEvaluation.MaximizingThresholdCount,
                localEvaluation.AdmissibleMaximizingThresholdCount,
                localEvaluation.SelectedFromAdmissibleMaximizers,
                localFullGraph.NodeCount,
                localEvaluation.SelectedMetrics.RetainedEdgeCount,
                localEvaluation.SelectedMetrics.RetainedEdgeShare,
                localEvaluation.SelectedMetrics.ConnectedComponents,
                localEvaluation.SelectedMetrics.LargestComponentSize,
                localEvaluation.SelectedMetrics.LargestComponentShare,
                localEvaluation.SelectedMetrics.IsolatedNodeCount,
                localEvaluation.SelectedMetrics.IsolateShare,
                localEvaluation.SelectedMetrics.ConnectedNodeShare));

            WriteSparseEdges(
                localWriter,
                pooledGraph.RepresentationFamily,
                pooledGraph.SourceRepresentation,
                unit.UnitType,
                unit.UnitId,
                localEvaluation.SelectedThreshold,
                localFullGraph,
                localEvaluation.SelectedRetainedEdgeIndexes);

            localSummaryRows.Add(new LocalDiagnosticSummaryRow(
                pooledGraph.RepresentationFamily,
                pooledGraph.SourceRepresentation,
                unit.UnitType,
                unit.UnitId,
                localEvaluation.SelectedThreshold,
                pooledEvaluation.SelectedThreshold,
                localFullGraph.NodeCount,
                localEvaluation.SelectedMetrics.RetainedEdgeCount,
                localEvaluation.SelectedMetrics.RetainedEdgeShare,
                localEvaluation.SelectedMetrics.Density,
                localEvaluation.SelectedMetrics.ConnectedComponents,
                localEvaluation.SelectedMetrics.LargestComponentSize,
                localEvaluation.SelectedMetrics.LargestComponentShare,
                localEvaluation.SelectedMetrics.IsolatedNodeCount,
                localEvaluation.SelectedMetrics.IsolateShare,
                localEvaluation.SelectedMetrics.ConnectedNodeShare,
                comparisonSafeGraph.EdgeCount,
                comparisonSafeMetrics.Density,
                comparisonSafeMetrics.ConnectedComponents,
                comparisonSafeMetrics.LargestComponentShare,
                comparisonSafeMetrics.IsolateShare));
        }
    }
}

WriteCsv(
    pooledCutoffsPath,
    new[]
    {
        "representation_family",
        "source_representation",
        "selected_threshold",
        "selection_rule",
        "lambda_min",
        "iota_max",
        "max_susceptibility",
        "n_maximizing_thresholds",
        "n_admissible_maximizing_thresholds",
        "selected_from_admissible_maximizers",
        "n_nodes",
        "n_retained_edges",
        "retained_edge_share",
        "n_connected_components",
        "largest_component_size",
        "largest_component_share",
        "n_isolated_nodes",
        "isolate_share",
        "connected_node_share"
    },
    pooledCutoffRows
        .OrderBy(row => row.RepresentationFamily, StringComparer.Ordinal)
        .Select(row => new[]
        {
            row.RepresentationFamily,
            row.SourceRepresentation,
            FormatDouble(row.SelectedThreshold),
            row.SelectionRule,
            FormatDouble(row.LambdaMin),
            FormatDouble(row.IotaMax),
            FormatDouble(row.MaxSusceptibility),
            row.MaximizingThresholdCount.ToString(CultureInfo.InvariantCulture),
            row.AdmissibleMaximizingThresholdCount.ToString(CultureInfo.InvariantCulture),
            FormatBoolean(row.SelectedFromAdmissibleMaximizers),
            row.NodeCount.ToString(CultureInfo.InvariantCulture),
            row.RetainedEdgeCount.ToString(CultureInfo.InvariantCulture),
            FormatDouble(row.RetainedEdgeShare),
            row.ConnectedComponents.ToString(CultureInfo.InvariantCulture),
            row.LargestComponentSize.ToString(CultureInfo.InvariantCulture),
            FormatDouble(row.LargestComponentShare),
            row.IsolatedNodeCount.ToString(CultureInfo.InvariantCulture),
            FormatDouble(row.IsolateShare),
            FormatDouble(row.ConnectedNodeShare)
        }));

WriteCsv(
    comparisonSafeSummaryPath,
    new[]
    {
        "representation_family",
        "source_representation",
        "unit_type",
        "unit_id",
        "reference_threshold",
        "n_nodes",
        "n_retained_edges",
        "retained_edge_share",
        "density",
        "n_connected_components",
        "largest_component_size",
        "largest_component_share",
        "n_isolated_nodes",
        "isolate_share",
        "connected_node_share"
    },
    comparisonSafeSummaryRows
        .OrderBy(row => row.RepresentationFamily, StringComparer.Ordinal)
        .ThenBy(row => UnitDefinition.GetSortIndex(row.UnitType))
        .ThenBy(row => row.UnitId, StringComparer.Ordinal)
        .Select(row => new[]
        {
            row.RepresentationFamily,
            row.SourceRepresentation,
            row.UnitType,
            row.UnitId,
            FormatDouble(row.ReferenceThreshold),
            row.NodeCount.ToString(CultureInfo.InvariantCulture),
            row.RetainedEdgeCount.ToString(CultureInfo.InvariantCulture),
            FormatDouble(row.RetainedEdgeShare),
            FormatDouble(row.Density),
            row.ConnectedComponents.ToString(CultureInfo.InvariantCulture),
            row.LargestComponentSize.ToString(CultureInfo.InvariantCulture),
            FormatDouble(row.LargestComponentShare),
            row.IsolatedNodeCount.ToString(CultureInfo.InvariantCulture),
            FormatDouble(row.IsolateShare),
            FormatDouble(row.ConnectedNodeShare)
        }));

WriteCsv(
    localCutoffsPath,
    new[]
    {
        "representation_family",
        "source_representation",
        "unit_type",
        "unit_id",
        "selected_threshold",
        "pooled_reference_threshold",
        "selection_rule",
        "max_susceptibility",
        "n_maximizing_thresholds",
        "n_admissible_maximizing_thresholds",
        "selected_from_admissible_maximizers",
        "n_nodes",
        "n_retained_edges",
        "retained_edge_share",
        "n_connected_components",
        "largest_component_size",
        "largest_component_share",
        "n_isolated_nodes",
        "isolate_share",
        "connected_node_share"
    },
    localCutoffRows
        .OrderBy(row => row.RepresentationFamily, StringComparer.Ordinal)
        .ThenBy(row => UnitDefinition.GetSortIndex(row.UnitType))
        .ThenBy(row => row.UnitId, StringComparer.Ordinal)
        .Select(row => new[]
        {
            row.RepresentationFamily,
            row.SourceRepresentation,
            row.UnitType,
            row.UnitId,
            FormatDouble(row.SelectedThreshold),
            FormatDouble(row.PooledReferenceThreshold),
            row.SelectionRule,
            FormatDouble(row.MaxSusceptibility),
            row.MaximizingThresholdCount.ToString(CultureInfo.InvariantCulture),
            row.AdmissibleMaximizingThresholdCount.ToString(CultureInfo.InvariantCulture),
            FormatBoolean(row.SelectedFromAdmissibleMaximizers),
            row.NodeCount.ToString(CultureInfo.InvariantCulture),
            row.RetainedEdgeCount.ToString(CultureInfo.InvariantCulture),
            FormatDouble(row.RetainedEdgeShare),
            row.ConnectedComponents.ToString(CultureInfo.InvariantCulture),
            row.LargestComponentSize.ToString(CultureInfo.InvariantCulture),
            FormatDouble(row.LargestComponentShare),
            row.IsolatedNodeCount.ToString(CultureInfo.InvariantCulture),
            FormatDouble(row.IsolateShare),
            FormatDouble(row.ConnectedNodeShare)
        }));

WriteCsv(
    localSummaryPath,
    new[]
    {
        "representation_family",
        "source_representation",
        "unit_type",
        "unit_id",
        "local_threshold",
        "pooled_reference_threshold",
        "n_nodes",
        "n_local_retained_edges",
        "local_retained_edge_share",
        "local_density",
        "local_n_connected_components",
        "local_largest_component_size",
        "local_largest_component_share",
        "local_n_isolated_nodes",
        "local_isolate_share",
        "local_connected_node_share",
        "pooled_reference_edges_in_unit",
        "pooled_reference_density_in_unit",
        "pooled_reference_n_connected_components_in_unit",
        "pooled_reference_largest_component_share_in_unit",
        "pooled_reference_isolate_share_in_unit"
    },
    localSummaryRows
        .OrderBy(row => row.RepresentationFamily, StringComparer.Ordinal)
        .ThenBy(row => UnitDefinition.GetSortIndex(row.UnitType))
        .ThenBy(row => row.UnitId, StringComparer.Ordinal)
        .Select(row => new[]
        {
            row.RepresentationFamily,
            row.SourceRepresentation,
            row.UnitType,
            row.UnitId,
            FormatDouble(row.LocalThreshold),
            FormatDouble(row.PooledReferenceThreshold),
            row.NodeCount.ToString(CultureInfo.InvariantCulture),
            row.LocalRetainedEdgeCount.ToString(CultureInfo.InvariantCulture),
            FormatDouble(row.LocalRetainedEdgeShare),
            FormatDouble(row.LocalDensity),
            row.LocalConnectedComponents.ToString(CultureInfo.InvariantCulture),
            row.LocalLargestComponentSize.ToString(CultureInfo.InvariantCulture),
            FormatDouble(row.LocalLargestComponentShare),
            row.LocalIsolatedNodeCount.ToString(CultureInfo.InvariantCulture),
            FormatDouble(row.LocalIsolateShare),
            FormatDouble(row.LocalConnectedNodeShare),
            row.PooledReferenceEdgeCountInUnit.ToString(CultureInfo.InvariantCulture),
            FormatDouble(row.PooledReferenceDensityInUnit),
            row.PooledReferenceConnectedComponentsInUnit.ToString(CultureInfo.InvariantCulture),
            FormatDouble(row.PooledReferenceLargestComponentShareInUnit),
            FormatDouble(row.PooledReferenceIsolateShareInUnit)
        }));

WriteCsv(
    decisionLogPath,
    new[] { "decision_group", "decision_key", "decision_value", "rationale" },
    decisionLogRows.Select(row => new[]
    {
        row.DecisionGroup,
        row.DecisionKey,
        row.DecisionValue,
        row.Rationale
    }));

Console.WriteLine($"Representations processed: {pooledReferenceGraphCount}");
Console.WriteLine($"Local diagnostic graphs processed: {localDiagnosticGraphCount}");
Console.WriteLine($"Pooled susceptibility curve rows: {pooledCurveRowCount}");
Console.WriteLine($"Local susceptibility curve rows: {localCurveRowCount}");
Console.WriteLine($"Outputs written to: {graphsSparseDirectory}");

static List<GraphData> LoadPooledGraphs(string pooledWeightedEdgesPath)
{
    using var enumerator = File.ReadLines(pooledWeightedEdgesPath).GetEnumerator();
    if (!enumerator.MoveNext())
    {
        throw new InvalidOperationException("The pooled weighted edge file is empty.");
    }

    var headerIndex = BuildIndex(ParseCsvLine(enumerator.Current));
    var builders = new Dictionary<string, GraphBuilder>(StringComparer.Ordinal);

    while (enumerator.MoveNext())
    {
        if (string.IsNullOrWhiteSpace(enumerator.Current))
        {
            continue;
        }

        var fields = ParseCsvLine(enumerator.Current);
        var sourceRepresentation = GetField(fields, headerIndex, "representation");
        if (!builders.TryGetValue(sourceRepresentation, out var builder))
        {
            builder = new GraphBuilder(sourceRepresentation, MapRepresentationFamily(sourceRepresentation));
            builders[sourceRepresentation] = builder;
        }

        builder.AddEdge(
            GetField(fields, headerIndex, "harmonized_skill_id_1"),
            GetField(fields, headerIndex, "harmonized_name_1"),
            GetField(fields, headerIndex, "harmonized_skill_id_2"),
            GetField(fields, headerIndex, "harmonized_name_2"),
            double.Parse(GetField(fields, headerIndex, "edge_weight"), CultureInfo.InvariantCulture));
    }

    return builders.Values
        .Select(builder => builder.Build())
        .OrderBy(graph => graph.RepresentationFamily, StringComparer.Ordinal)
        .ToList();
}

static Dictionary<string, List<UnitDefinition>> BuildUnitDefinitions(string harmonizedDatasetPath)
{
    var buildersByType = new Dictionary<string, Dictionary<string, UnitBuilder>>(StringComparer.Ordinal)
    {
        ["section"] = new(StringComparer.Ordinal),
        ["track"] = new(StringComparer.Ordinal),
        ["programme"] = new(StringComparer.Ordinal),
        ["programme_year"] = new(StringComparer.Ordinal)
    };

    using var enumerator = File.ReadLines(harmonizedDatasetPath).GetEnumerator();
    if (!enumerator.MoveNext())
    {
        throw new InvalidOperationException("The harmonized dataset is empty.");
    }

    var headerIndex = BuildIndex(ParseCsvLine(enumerator.Current));

    while (enumerator.MoveNext())
    {
        if (string.IsNullOrWhiteSpace(enumerator.Current))
        {
            continue;
        }

        var fields = ParseCsvLine(enumerator.Current);
        var harmonizedSkillId = GetField(fields, headerIndex, "harmonized_skill_id");
        var section = GetField(fields, headerIndex, "section");
        var track = GetField(fields, headerIndex, "edu_type");
        var programme = GetField(fields, headerIndex, "programme");
        var year = GetField(fields, headerIndex, "year");

        AddNodeToUnit(
            buildersByType["section"],
            section,
            section,
            "section",
            $"All harmonized skill records with section == {section} across all years and programmes.",
            harmonizedSkillId);
        AddNodeToUnit(
            buildersByType["track"],
            track,
            track,
            "track",
            $"All harmonized skill records with edu_type == {track} across all sections, programmes, and years.",
            harmonizedSkillId);
        AddNodeToUnit(
            buildersByType["programme"],
            programme,
            programme,
            "programme",
            $"All harmonized skill records with programme == {programme} across all sections and years.",
            harmonizedSkillId);
        AddNodeToUnit(
            buildersByType["programme_year"],
            $"{programme}__{year}",
            $"{programme} year {year}",
            "programme_year",
            $"All harmonized skill records with programme == {programme} and year == {year}.",
            harmonizedSkillId);
    }

    return buildersByType.ToDictionary(
        entry => entry.Key,
        entry => entry.Value.Values
            .Select(builder => builder.Build())
            .OrderBy(unit => unit.UnitId, StringComparer.Ordinal)
            .ToList(),
        StringComparer.Ordinal);
}

static void AddNodeToUnit(
    Dictionary<string, UnitBuilder> builders,
    string unitId,
    string unitLabel,
    string unitType,
    string definitionRule,
    string harmonizedSkillId)
{
    if (!builders.TryGetValue(unitId, out var builder))
    {
        builder = new UnitBuilder(unitType, unitId, unitLabel, definitionRule);
        builders[unitId] = builder;
    }

    builder.NodeIdSet.Add(harmonizedSkillId);
}

static string MapRepresentationFamily(string sourceRepresentation) =>
    sourceRepresentation switch
    {
        "name_description" => "concat",
        _ => sourceRepresentation
    };

static ThresholdSelectionResult EvaluateGraph(GraphData graph, double lambdaMin, double iotaMax)
{
    if (graph.EdgeCount == 0)
    {
        var componentSizes = graph.NodeCount == 0 ? Array.Empty<int>() : Enumerable.Repeat(1, graph.NodeCount).ToArray();
        var metrics = ComputeSummaryMetrics(graph.NodeCount, 0, 0, componentSizes);
        return new ThresholdSelectionResult(
            new List<ThresholdCurvePoint>(),
            double.NaN,
            "no_edges_available",
            0d,
            0,
            0,
            false,
            Array.Empty<int>(),
            metrics);
    }

    var state = new DynamicConnectivityState(graph.NodeCount);
    var curvePoints = new List<ThresholdCurvePoint>();
    var retainedEdgeCount = 0;
    var edgeIndex = 0;

    while (edgeIndex < graph.EdgeCount)
    {
        var threshold = graph.Edges[edgeIndex].Weight;
        while (edgeIndex < graph.EdgeCount && graph.Edges[edgeIndex].Weight == threshold)
        {
            state.Union(graph.Edges[edgeIndex].NodeIndex1, graph.Edges[edgeIndex].NodeIndex2);
            retainedEdgeCount += 1;
            edgeIndex += 1;
        }

        var metrics = ComputeSummaryMetrics(
            graph.NodeCount,
            graph.EdgeCount,
            retainedEdgeCount,
            state.GetComponentSizes());

        curvePoints.Add(new ThresholdCurvePoint(
            threshold,
            metrics.Susceptibility,
            retainedEdgeCount,
            metrics.RetainedEdgeShare,
            metrics.ConnectedComponents,
            metrics.LargestComponentSize,
            metrics.LargestComponentShare,
            metrics.IsolatedNodeCount,
            metrics.IsolateShare,
            metrics.ConnectedNodeShare));
    }

    var maxSusceptibility = curvePoints.Max(point => point.Susceptibility);
    var maximizingPoints = curvePoints
        .Where(point => Math.Abs(point.Susceptibility - maxSusceptibility) <= SusceptibilityTolerance)
        .ToList();

    foreach (var point in maximizingPoints)
    {
        point.IsSusceptibilityMaximizer = true;
        if (point.LargestComponentShare >= lambdaMin && point.IsolateShare <= iotaMax)
        {
            point.IsAdmissibleMaximizer = true;
        }
    }

    var admissibleMaximizers = maximizingPoints
        .Where(point => point.IsAdmissibleMaximizer)
        .ToList();

    ThresholdCurvePoint selectedPoint;
    string selectionRule;
    bool selectedFromAdmissibleMaximizers;

    if (admissibleMaximizers.Count > 0)
    {
        selectedPoint = admissibleMaximizers.MaxBy(point => point.Threshold)!;
        selectionRule = "largest_admissible_susceptibility_maximizer";
        selectedFromAdmissibleMaximizers = true;
    }
    else
    {
        selectedPoint = maximizingPoints.MinBy(point => point.Threshold)!;
        selectionRule = "least_aggressive_susceptibility_maximizer";
        selectedFromAdmissibleMaximizers = false;
    }

    selectedPoint.IsSelectedTau = true;

    return new ThresholdSelectionResult(
        curvePoints,
        selectedPoint.Threshold,
        selectionRule,
        maxSusceptibility,
        maximizingPoints.Count,
        admissibleMaximizers.Count,
        selectedFromAdmissibleMaximizers,
        Enumerable.Range(0, selectedPoint.RetainedEdgeCount).ToArray(),
        new SummaryMetrics(
            selectedPoint.RetainedEdgeCount,
            selectedPoint.RetainedEdgeShare,
            graph.NodeCount < 2
                ? 0d
                : selectedPoint.RetainedEdgeCount / (graph.NodeCount * (graph.NodeCount - 1) / 2d),
            selectedPoint.ConnectedComponents,
            selectedPoint.LargestComponentSize,
            selectedPoint.LargestComponentShare,
            selectedPoint.IsolatedNodeCount,
            selectedPoint.IsolateShare,
            selectedPoint.ConnectedNodeShare,
            selectedPoint.Susceptibility));
}

static SummaryMetrics ComputeSummaryMetrics(
    int nodeCount,
    int totalPossibleObservedEdges,
    int retainedEdgeCount,
    IReadOnlyList<int> componentSizes)
{
    var connectedComponents = componentSizes.Count;
    var largestComponentSize = componentSizes.Count == 0 ? 0 : componentSizes.Max();
    var isolatedNodeCount = componentSizes.Count(size => size == 1);
    var largestComponentShare = nodeCount == 0 ? 0d : largestComponentSize / (double)nodeCount;
    var isolateShare = nodeCount == 0 ? 0d : isolatedNodeCount / (double)nodeCount;
    var connectedNodeShare = nodeCount == 0 ? 0d : (nodeCount - isolatedNodeCount) / (double)nodeCount;
    var density = nodeCount < 2 ? 0d : retainedEdgeCount / (nodeCount * (nodeCount - 1) / 2d);
    var retainedEdgeShare = totalPossibleObservedEdges == 0 ? 0d : retainedEdgeCount / (double)totalPossibleObservedEdges;
    var orderedSizes = componentSizes.OrderByDescending(size => size).ToArray();

    double susceptibility = 0d;
    if (orderedSizes.Length > 1)
    {
        long numerator = 0;
        long denominator = 0;
        for (var index = 1; index < orderedSizes.Length; index += 1)
        {
            var size = orderedSizes[index];
            numerator += (long)size * size;
            denominator += size;
        }

        if (denominator > 0)
        {
            susceptibility = numerator / (double)denominator;
        }
    }

    return new SummaryMetrics(
        retainedEdgeCount,
        retainedEdgeShare,
        density,
        connectedComponents,
        largestComponentSize,
        largestComponentShare,
        isolatedNodeCount,
        isolateShare,
        connectedNodeShare,
        susceptibility);
}

static IReadOnlyList<int> BuildComponentSizes(int nodeCount, IReadOnlyList<OrderedEdge> edges)
{
    var state = new DynamicConnectivityState(nodeCount);
    foreach (var edge in edges)
    {
        state.Union(edge.NodeIndex1, edge.NodeIndex2);
    }

    return state.GetComponentSizes();
}

static GraphData BuildInducedSubgraph(
    GraphData sourceGraph,
    HashSet<string> nodeIdSet,
    IReadOnlyList<int>? sourceEdgeIndexes = null)
{
    var nodeIndexMap = Enumerable.Repeat(-1, sourceGraph.NodeCount).ToArray();
    var nodeIds = new List<string>();
    var nodeNames = new List<string>();

    for (var sourceIndex = 0; sourceIndex < sourceGraph.NodeCount; sourceIndex += 1)
    {
        var nodeId = sourceGraph.NodeIds[sourceIndex];
        if (!nodeIdSet.Contains(nodeId))
        {
            continue;
        }

        nodeIndexMap[sourceIndex] = nodeIds.Count;
        nodeIds.Add(nodeId);
        nodeNames.Add(sourceGraph.NodeNames[sourceIndex]);
    }

    var edges = new List<OrderedEdge>();
    if (sourceEdgeIndexes is null)
    {
        for (var edgeIndex = 0; edgeIndex < sourceGraph.EdgeCount; edgeIndex += 1)
        {
            var edge = sourceGraph.Edges[edgeIndex];
            var nodeIndex1 = nodeIndexMap[edge.NodeIndex1];
            var nodeIndex2 = nodeIndexMap[edge.NodeIndex2];
            if (nodeIndex1 >= 0 && nodeIndex2 >= 0)
            {
                edges.Add(new OrderedEdge(nodeIndex1, nodeIndex2, edge.Weight));
            }
        }
    }
    else
    {
        foreach (var edgeIndex in sourceEdgeIndexes)
        {
            var edge = sourceGraph.Edges[edgeIndex];
            var nodeIndex1 = nodeIndexMap[edge.NodeIndex1];
            var nodeIndex2 = nodeIndexMap[edge.NodeIndex2];
            if (nodeIndex1 >= 0 && nodeIndex2 >= 0)
            {
                edges.Add(new OrderedEdge(nodeIndex1, nodeIndex2, edge.Weight));
            }
        }
    }

    return new GraphData(
        sourceGraph.RepresentationFamily,
        sourceGraph.SourceRepresentation,
        nodeIds.ToArray(),
        nodeNames.ToArray(),
        edges.ToArray(),
        BuildIndex(nodeIds));
}

static StreamWriter CreateSparseEdgeWriter(string path)
{
    var writer = CreateWriter(path);
    WriteCsvRow(writer, new[]
    {
        "representation_family",
        "source_representation",
        "unit_type",
        "unit_id",
        "selected_threshold",
        "harmonized_skill_id_1",
        "harmonized_name_1",
        "harmonized_skill_id_2",
        "harmonized_name_2",
        "edge_weight"
    });
    return writer;
}

static void WriteSparseEdges(
    StreamWriter writer,
    string representationFamily,
    string sourceRepresentation,
    string unitType,
    string unitId,
    double selectedThreshold,
    GraphData graph,
    IReadOnlyList<int>? selectedEdgeIndexes = null)
{
    if (selectedEdgeIndexes is null)
    {
        for (var edgeIndex = 0; edgeIndex < graph.EdgeCount; edgeIndex += 1)
        {
            WriteSparseEdgeRow(writer, representationFamily, sourceRepresentation, unitType, unitId, selectedThreshold, graph, graph.Edges[edgeIndex]);
        }

        return;
    }

    foreach (var edgeIndex in selectedEdgeIndexes)
    {
        WriteSparseEdgeRow(writer, representationFamily, sourceRepresentation, unitType, unitId, selectedThreshold, graph, graph.Edges[edgeIndex]);
    }
}

static void WriteSparseEdgeRow(
    StreamWriter writer,
    string representationFamily,
    string sourceRepresentation,
    string unitType,
    string unitId,
    double selectedThreshold,
    GraphData graph,
    OrderedEdge edge)
{
    WriteCsvRow(writer, new[]
    {
        representationFamily,
        sourceRepresentation,
        unitType,
        unitId,
        FormatDouble(selectedThreshold),
        graph.NodeIds[edge.NodeIndex1],
        graph.NodeNames[edge.NodeIndex1],
        graph.NodeIds[edge.NodeIndex2],
        graph.NodeNames[edge.NodeIndex2],
        FormatDouble(edge.Weight)
    });
}

static StreamWriter GetComparisonSafeWriter(
    string unitType,
    StreamWriter sectionsWriter,
    StreamWriter tracksWriter,
    StreamWriter programmesWriter,
    StreamWriter programmeYearsWriter) =>
    unitType switch
    {
        "section" => sectionsWriter,
        "track" => tracksWriter,
        "programme" => programmesWriter,
        "programme_year" => programmeYearsWriter,
        _ => throw new InvalidOperationException($"Unsupported unit type '{unitType}'.")
    };

static StreamWriter GetLocalWriter(
    string unitType,
    StreamWriter sectionsWriter,
    StreamWriter tracksWriter,
    StreamWriter programmesWriter,
    StreamWriter programmeYearsWriter) =>
    unitType switch
    {
        "section" => sectionsWriter,
        "track" => tracksWriter,
        "programme" => programmesWriter,
        "programme_year" => programmeYearsWriter,
        _ => throw new InvalidOperationException($"Unsupported unit type '{unitType}'.")
    };

static string FormatDouble(double value) =>
    double.IsNaN(value) ? string.Empty : value.ToString("0.############", CultureInfo.InvariantCulture);

static string FormatBoolean(bool value) => value ? "TRUE" : "FALSE";

static Dictionary<string, int> BuildIndex(IReadOnlyList<string> headerFields)
{
    var index = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
    for (var position = 0; position < headerFields.Count; position += 1)
    {
        index[headerFields[position]] = position;
    }

    return index;
}

static string GetField(IReadOnlyList<string> fields, IReadOnlyDictionary<string, int> headerIndex, string fieldName)
{
    if (!headerIndex.TryGetValue(fieldName, out var position))
    {
        throw new InvalidOperationException($"Missing required CSV field '{fieldName}'.");
    }

    return position < fields.Count ? fields[position] : string.Empty;
}

static StreamWriter CreateWriter(string path) =>
    new(path, false, new UTF8Encoding(false));

static void WriteCsv(string path, IReadOnlyList<string> header, IEnumerable<IReadOnlyList<string>> rows)
{
    using var writer = CreateWriter(path);
    WriteCsvRow(writer, header);
    foreach (var row in rows)
    {
        WriteCsvRow(writer, row);
    }
}

static void WriteCsvRow(TextWriter writer, IReadOnlyList<string> values)
{
    for (var index = 0; index < values.Count; index += 1)
    {
        if (index > 0)
        {
            writer.Write(',');
        }

        writer.Write(EscapeCsv(values[index]));
    }

    writer.WriteLine();
}

static string EscapeCsv(string value)
{
    if (value.IndexOfAny(new[] { ',', '"', '\r', '\n' }) < 0)
    {
        return value;
    }

    return "\"" + value.Replace("\"", "\"\"") + "\"";
}

static string[] ParseCsvLine(string line)
{
    var fields = new List<string>();
    var builder = new StringBuilder();
    var insideQuotes = false;

    for (var index = 0; index < line.Length; index += 1)
    {
        var character = line[index];
        if (insideQuotes)
        {
            if (character == '"')
            {
                if (index + 1 < line.Length && line[index + 1] == '"')
                {
                    builder.Append('"');
                    index += 1;
                }
                else
                {
                    insideQuotes = false;
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
                insideQuotes = true;
            }
            else
            {
                builder.Append(character);
            }
        }
    }

    fields.Add(builder.ToString());
    return fields.ToArray();
}

sealed record DecisionLogRow(
    string DecisionGroup,
    string DecisionKey,
    string DecisionValue,
    string Rationale);

sealed record PooledReferenceCutoffRow(
    string RepresentationFamily,
    string SourceRepresentation,
    double SelectedThreshold,
    string SelectionRule,
    double LambdaMin,
    double IotaMax,
    double MaxSusceptibility,
    int MaximizingThresholdCount,
    int AdmissibleMaximizingThresholdCount,
    bool SelectedFromAdmissibleMaximizers,
    int NodeCount,
    int RetainedEdgeCount,
    double RetainedEdgeShare,
    int ConnectedComponents,
    int LargestComponentSize,
    double LargestComponentShare,
    int IsolatedNodeCount,
    double IsolateShare,
    double ConnectedNodeShare);

sealed record ComparisonSafeSummaryRow(
    string RepresentationFamily,
    string SourceRepresentation,
    string UnitType,
    string UnitId,
    double ReferenceThreshold,
    int NodeCount,
    int RetainedEdgeCount,
    double RetainedEdgeShare,
    double Density,
    int ConnectedComponents,
    int LargestComponentSize,
    double LargestComponentShare,
    int IsolatedNodeCount,
    double IsolateShare,
    double ConnectedNodeShare);

sealed record LocalDiagnosticCutoffRow(
    string RepresentationFamily,
    string SourceRepresentation,
    string UnitType,
    string UnitId,
    double SelectedThreshold,
    double PooledReferenceThreshold,
    string SelectionRule,
    double MaxSusceptibility,
    int MaximizingThresholdCount,
    int AdmissibleMaximizingThresholdCount,
    bool SelectedFromAdmissibleMaximizers,
    int NodeCount,
    int RetainedEdgeCount,
    double RetainedEdgeShare,
    int ConnectedComponents,
    int LargestComponentSize,
    double LargestComponentShare,
    int IsolatedNodeCount,
    double IsolateShare,
    double ConnectedNodeShare);

sealed record LocalDiagnosticSummaryRow(
    string RepresentationFamily,
    string SourceRepresentation,
    string UnitType,
    string UnitId,
    double LocalThreshold,
    double PooledReferenceThreshold,
    int NodeCount,
    int LocalRetainedEdgeCount,
    double LocalRetainedEdgeShare,
    double LocalDensity,
    int LocalConnectedComponents,
    int LocalLargestComponentSize,
    double LocalLargestComponentShare,
    int LocalIsolatedNodeCount,
    double LocalIsolateShare,
    double LocalConnectedNodeShare,
    int PooledReferenceEdgeCountInUnit,
    double PooledReferenceDensityInUnit,
    int PooledReferenceConnectedComponentsInUnit,
    double PooledReferenceLargestComponentShareInUnit,
    double PooledReferenceIsolateShareInUnit);

sealed class ThresholdCurvePoint
{
    public ThresholdCurvePoint(
        double threshold,
        double susceptibility,
        int retainedEdgeCount,
        double retainedEdgeShare,
        int connectedComponents,
        int largestComponentSize,
        double largestComponentShare,
        int isolatedNodeCount,
        double isolateShare,
        double connectedNodeShare)
    {
        Threshold = threshold;
        Susceptibility = susceptibility;
        RetainedEdgeCount = retainedEdgeCount;
        RetainedEdgeShare = retainedEdgeShare;
        ConnectedComponents = connectedComponents;
        LargestComponentSize = largestComponentSize;
        LargestComponentShare = largestComponentShare;
        IsolatedNodeCount = isolatedNodeCount;
        IsolateShare = isolateShare;
        ConnectedNodeShare = connectedNodeShare;
    }

    public double Threshold { get; }
    public double Susceptibility { get; }
    public int RetainedEdgeCount { get; }
    public double RetainedEdgeShare { get; }
    public int ConnectedComponents { get; }
    public int LargestComponentSize { get; }
    public double LargestComponentShare { get; }
    public int IsolatedNodeCount { get; }
    public double IsolateShare { get; }
    public double ConnectedNodeShare { get; }
    public bool IsSusceptibilityMaximizer { get; set; }
    public bool IsAdmissibleMaximizer { get; set; }
    public bool IsSelectedTau { get; set; }
}

sealed record ThresholdSelectionResult(
    IReadOnlyList<ThresholdCurvePoint> CurvePoints,
    double SelectedThreshold,
    string SelectionRule,
    double MaxSusceptibility,
    int MaximizingThresholdCount,
    int AdmissibleMaximizingThresholdCount,
    bool SelectedFromAdmissibleMaximizers,
    IReadOnlyList<int> SelectedRetainedEdgeIndexes,
    SummaryMetrics SelectedMetrics);

sealed record SummaryMetrics(
    int RetainedEdgeCount,
    double RetainedEdgeShare,
    double Density,
    int ConnectedComponents,
    int LargestComponentSize,
    double LargestComponentShare,
    int IsolatedNodeCount,
    double IsolateShare,
    double ConnectedNodeShare,
    double Susceptibility);

sealed record OrderedEdge(int NodeIndex1, int NodeIndex2, double Weight);

sealed record GraphData(
    string RepresentationFamily,
    string SourceRepresentation,
    string[] NodeIds,
    string[] NodeNames,
    OrderedEdge[] Edges,
    Dictionary<string, int> NodeIndexById)
{
    public int NodeCount => NodeIds.Length;
    public int EdgeCount => Edges.Length;
}

sealed record UnitDefinition(
    string UnitType,
    string UnitId,
    string UnitLabel,
    string DefinitionRule,
    string[] NodeIds)
{
    public static string[] UnitTypeOrder { get; } =
    [
        "section",
        "track",
        "programme",
        "programme_year"
    ];

    public HashSet<string> NodeIdSet { get; } = new(NodeIds, StringComparer.Ordinal);

    public static int GetSortIndex(string unitType)
    {
        var index = Array.IndexOf(UnitTypeOrder, unitType);
        return index < 0 ? int.MaxValue : index;
    }
}

sealed class GraphBuilder
{
    private readonly Dictionary<string, string> _nodeNamesById = new(StringComparer.Ordinal);
    private readonly List<RawEdge> _rawEdges = new();

    public GraphBuilder(string sourceRepresentation, string representationFamily)
    {
        SourceRepresentation = sourceRepresentation;
        RepresentationFamily = representationFamily;
    }

    public string SourceRepresentation { get; }
    public string RepresentationFamily { get; }

    public void AddEdge(
        string nodeId1,
        string nodeName1,
        string nodeId2,
        string nodeName2,
        double weight)
    {
        _nodeNamesById[nodeId1] = nodeName1;
        _nodeNamesById[nodeId2] = nodeName2;
        _rawEdges.Add(new RawEdge(nodeId1, nodeId2, weight));
    }

    public GraphData Build()
    {
        var nodeIds = _nodeNamesById.Keys.OrderBy(nodeId => nodeId, StringComparer.Ordinal).ToArray();
        var nodeNames = nodeIds.Select(nodeId => _nodeNamesById[nodeId]).ToArray();
        var nodeIndexById = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var index = 0; index < nodeIds.Length; index += 1)
        {
            nodeIndexById[nodeIds[index]] = index;
        }

        var edges = _rawEdges
            .Select(edge => new OrderedEdge(
                nodeIndexById[edge.NodeId1],
                nodeIndexById[edge.NodeId2],
                edge.Weight))
            .OrderByDescending(edge => edge.Weight)
            .ThenBy(edge => nodeIds[edge.NodeIndex1], StringComparer.Ordinal)
            .ThenBy(edge => nodeIds[edge.NodeIndex2], StringComparer.Ordinal)
            .ToArray();

        return new GraphData(
            RepresentationFamily,
            SourceRepresentation,
            nodeIds,
            nodeNames,
            edges,
            nodeIndexById);
    }

    private sealed record RawEdge(string NodeId1, string NodeId2, double Weight);
}

sealed class UnitBuilder
{
    public UnitBuilder(string unitType, string unitId, string unitLabel, string definitionRule)
    {
        UnitType = unitType;
        UnitId = unitId;
        UnitLabel = unitLabel;
        DefinitionRule = definitionRule;
    }

    public string UnitType { get; }
    public string UnitId { get; }
    public string UnitLabel { get; }
    public string DefinitionRule { get; }
    public HashSet<string> NodeIdSet { get; } = new(StringComparer.Ordinal);

    public UnitDefinition Build() =>
        new(
            UnitType,
            UnitId,
            UnitLabel,
            DefinitionRule,
            NodeIdSet.OrderBy(nodeId => nodeId, StringComparer.Ordinal).ToArray());
}

sealed class DynamicConnectivityState
{
    private readonly int[] _parent;
    private readonly int[] _size;

    public DynamicConnectivityState(int nodeCount)
    {
        _parent = new int[nodeCount];
        _size = new int[nodeCount];
        for (var index = 0; index < nodeCount; index += 1)
        {
            _parent[index] = index;
            _size[index] = 1;
        }
    }

    public void Union(int nodeIndex1, int nodeIndex2)
    {
        var root1 = Find(nodeIndex1);
        var root2 = Find(nodeIndex2);
        if (root1 == root2)
        {
            return;
        }

        if (_size[root1] < _size[root2])
        {
            (root1, root2) = (root2, root1);
        }

        _parent[root2] = root1;
        _size[root1] += _size[root2];
    }

    public IReadOnlyList<int> GetComponentSizes()
    {
        var sizesByRoot = new Dictionary<int, int>();
        for (var index = 0; index < _parent.Length; index += 1)
        {
            var root = Find(index);
            if (sizesByRoot.TryGetValue(root, out var currentSize))
            {
                sizesByRoot[root] = currentSize + 1;
            }
            else
            {
                sizesByRoot[root] = 1;
            }
        }

        return sizesByRoot.Values.ToArray();
    }

    private int Find(int nodeIndex)
    {
        if (_parent[nodeIndex] != nodeIndex)
        {
            _parent[nodeIndex] = Find(_parent[nodeIndex]);
        }

        return _parent[nodeIndex];
    }
}
