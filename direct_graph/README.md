# Directed Graph Branch

This folder holds the directed-dependency branch specification and its implementation notes.

Current source specifications:

- `manisfest.tex`
- `steps.tex`

Current implementation status:

- Step D1 implemented in `scripts/step10_directed_trajectory_panel.py`
- Step D2 implemented in `scripts/step11_directed_time_layered_nodes.py`
- Step D3 implemented in `scripts/step12_temporal_pair_classification.py`
- Step D4 implemented in `scripts/step13_precedence_statistics.py`
- Step D5 implemented in `scripts/step14_dependency_learning_sample.py`
- Step D6 implemented in `scripts/step15_direct_parent_scores.py`
- Step D7 implemented in `scripts/step16_directed_selection_rule.py`
- Step D8 implemented in `scripts/step17_local_directed_graphs.py`
- Step D9 implemented in `scripts/step18_directed_aggregation.py`

The directed branch is now Python-only.

Validation status for the Python rewrite:

- Steps D1 to D5 match the previous implementation row-for-row when parsed as CSV
- Step D6 matches the previous implementation on all deterministic fields
- The bootstrap-only columns can differ from the retired implementation because the old version used .NET's seeded RNG while the Python rewrite uses Python's seeded RNG

## Output location

The directed-branch CSV outputs are written to:

- `outputs/directed_graph/10_directed_trajectory_panel.csv`
- `outputs/directed_graph/10_directed_trajectory_audit.csv`
- `outputs/directed_graph/10_within_year_order_audit.csv`
- `outputs/directed_graph/11_directed_nodes.csv`
- `outputs/directed_graph/11_directed_node_provenance.csv`
- `outputs/directed_graph/12_temporal_pair_registry.csv`
- `outputs/directed_graph/12_prerequisite_candidates.csv`
- `outputs/directed_graph/12_corequisite_candidates.csv`
- `outputs/directed_graph/13_precedence_statistics.csv`
- `outputs/directed_graph/14_candidate_parent_sets.csv`
- `outputs/directed_graph/14_dependency_learning_sample.csv`
- `outputs/directed_graph/15_direct_parent_scores.csv`
- `outputs/directed_graph/15_bootstrap_selection_summary.csv`
- `outputs/directed_graph/16_directed_selection_surface.csv`
- `outputs/directed_graph/16_directed_selected_model.csv`
- `outputs/directed_graph/16_directed_model_selection_surface.csv`
- `outputs/directed_graph/16_directed_cutoff_selection.csv`
- `outputs/directed_graph/17_directed_edges_trajectories.csv`
- `outputs/directed_graph/17_corequisite_edges_trajectories.csv`
- `outputs/directed_graph/17_directed_graph_summary.csv`
- `outputs/directed_graph/18_directed_edges_sections.csv`
- `outputs/directed_graph/18_directed_edges_tracks.csv`
- `outputs/directed_graph/18_directed_edges_programmes.csv`
- `outputs/directed_graph/18_directed_edges_pooled.csv`
- `outputs/directed_graph/18_directed_aggregation_summary.csv`

## How to run

From the repository root:

```powershell
py .\scripts\step10_directed_trajectory_panel.py
py .\scripts\step11_directed_time_layered_nodes.py
py .\scripts\step12_temporal_pair_classification.py
py .\scripts\step13_precedence_statistics.py
py .\scripts\step14_dependency_learning_sample.py
py .\scripts\step15_direct_parent_scores.py
py .\scripts\step16_directed_selection_rule.py
py .\scripts\step17_local_directed_graphs.py
py .\scripts\step18_directed_aggregation.py
```

## D1 implementation notes

The current D1 implementation uses `edu_type x programme` as the concrete `trajectory_unit` for the first pass and retains `section` as `class_id`.

That extra `edu_type` scope is necessary because some programme codes appear in both tracks in the harmonized dataset. A directed path therefore lives inside a track-scoped programme, not inside the raw programme code alone.

That is intentional. In the current harmonized dataset, most programmes with multiple section labels do not show parallel paths. Instead, the section label changes by year along one progression. The main exception is `INFOR`, where multiple sections appear in the same year. Those rows are still assigned to the programme-level trajectory for now, but they are flagged as `requires_branch_resolution = true` so later steps can replace the provisional assignment with a branch-aware rule.

This keeps Step D1 reproducible while making the unresolved branching explicit instead of silently hard-coding a weak assumption.

## Within-year ordering

No validated within-year ordering field exists in `04_skills_harmonized.csv` at the moment.

Because of that:

- the trajectory panel records `within_year_position_available = false`
- the node construction in Step D2 uses the year-only time model from the manifest
- same-year ordering remains an audit problem, not an inferred rule

## D2 implementation notes

Step D2 follows the manifest's core node identity:

- `node = (trajectory_unit, year, harmonized_skill_id)`

The implementation also keeps class support metadata on each node:

- `observed_class_ids`
- `n_class_ids`
- `class_context_type`

Those fields are not part of the node identifier. They exist so Step D3 can later separate same-class from different-class same-year pairs without rebuilding D1.

## D3 implementation notes

Step D3 produces both a full ordered pair registry and the two operational outputs that follow from it:

- `12_temporal_pair_registry.csv` keeps the complete ordered classification
- `12_prerequisite_candidates.csv` keeps only `earlier_to_later` pairs
- `12_corequisite_candidates.csv` keeps unique same-year unordered pairs

The registry uses the D1 and D2 audits directly to keep the unresolved `INFOR` cases visible.

Pairs from standard trajectories behave as expected:

- earlier year to later year -> prerequisite candidate
- same year with overlapping class support -> same-year same-class
- same year with disjoint class support -> same-year different-class
- later year to earlier year -> reverse-time impossible

For branch-flagged trajectories such as `CLS__INFOR` and `GEN__INFOR`, D3 does not silently treat every forward-time pair as equally clean. Instead it adds:

- `branch_resolution_required`
- `source_year_branch_state`
- `target_year_branch_state`
- `branch_pair_context`
- `prerequisite_candidate_status`
- `branch_resolution_note`

That means:

- pre-split single-class forward pairs remain usable as `eligible_pre_split`
- forward pairs that enter, leave, or stay inside the unresolved parallel-year blocks are kept as `provisional_pending_branch_resolution`
- same-time pairs in parallel blocks are retained, but marked `branch_sensitive_same_time`

## D4 implementation notes

Step D4 computes the manifest's first-appearance precedence counts:

- `n_plus = number of trajectories where source first appears before target`
- `n_minus = number of trajectories where source first appears after target`
- `n_zero = number of trajectories where source and target first appear in the same year`

The output file is:

- `13_precedence_statistics.csv`

To preserve the branch audit, the script does not publish only one precedence score. It records:

- `precedence_score_all` using every current trajectory unit
- `precedence_score_ready` using only observations whose first appearances stay outside unresolved parallel-year blocks
- provisional support counts when the evidence comes from branch-sensitive first appearances

This matters for `INFOR`. Some skill pairs have valid early-year support before the split years, while other observations depend on unresolved branch structure in years 3 and 4. D4 therefore makes the distinction explicit through:

- `n_observed_ready`
- `n_observed_provisional`
- `ready_coverage_share`
- `recommended_precedence_basis`

## D5 implementation notes

Step D5 converts the precedence table into a conservative admissible parent screen and then builds the long-format risk sample used for D6.

The candidate-parent rule is:

- use the D4 `recommended_precedence_basis`
- keep a parent candidate only when `n_plus_basis > 0`

This is deliberately conservative. If D4 says `prefer_ready`, D5 does not rescue the edge using provisional-only evidence. That keeps the first learning sample aligned with the same branch-sensitive discipline used in D4.

The learning sample is stored in long format rather than wide matrix format. Each row corresponds to one:

- trajectory
- risk year `y`
- child skill `j`
- candidate parent `i`

with:

- `child_event_in_next_year = 1` when the child first appears in the next observed year
- `parent_observed_by_risk_year = 1` when the parent has already appeared by year `y`

Children first observed in the first available year of a trajectory are marked `left_censored_first_year`, because their prior exposure history is not observable inside the current curriculum slice.

## D6 implementation notes

The current D6 implementation is a transparent baseline estimator, not yet a full penalized logistic or hazard solver.

It works in three stages:

1. Collapse the D5 long sample into edge-by-trajectory contingency counts.
2. Score each admissible edge by how much a single parent indicator improves conditional event prediction for the child.
3. Bootstrap trajectory units and, within each child, keep only the top-scoring parents up to a fixed sparse limit.

This yields:

- `15_direct_parent_scores.csv`
- `15_bootstrap_selection_summary.csv`

For runtime reasons, the default Python Step 15 configuration currently uses:

- `25` bootstrap iterations
- top `5` parents per child in each bootstrap refit

Those defaults are meant for the prototype branch and can be raised later through the Step 15 script parameters.

The core edge support score is:

- `bootstrap_selection_frequency`

which estimates how often an admissible edge survives the bootstrap sparse-selection rule. The implementation also exports:

- `log_loss_improvement`
- `event_lift`
- `smoothed_log_odds_ratio`
- `full_sample_selected`

This is a practical prototype baseline for D6. The main future upgrade path is to replace the screening-based sparse selector with a true penalized discrete-time hazard or sparse logistic estimator while keeping the same output contract.

## D7 implementation notes

Step D7 uses the D6 bootstrap support scores and evaluates candidate thresholds on held-out trajectories.

The current evaluation rule is:

- leave one trajectory unit out at a time
- build child-specific smoothed baseline event rates on the remaining trajectories
- for each threshold `tau`, keep edges with `bootstrap_selection_frequency >= tau`
- score held-out first-introduction events with the strongest active selected parent for that child-year risk set
- choose the threshold that maximizes held-out log-loss improvement over the null child-rate baseline

That produces:

- `16_directed_selection_surface.csv`
- `16_directed_selected_model.csv`

To stay compatible with both `steps.tex` and `manisfest.tex`, the same D7 content is also exported under the alias filenames:

- `16_directed_model_selection_surface.csv`
- `16_directed_cutoff_selection.csv`

In the current run, D7 selected a thresholded binary rule at `tau = 0.64`.

## D8 implementation notes

Step D8 instantiates one local directed graph per trajectory from the D7-selected global rule.

The important implementation choice is that the prerequisite DAG is instantiated on first-introduction nodes. That is an inference from the earlier branch design:

- D2 keeps all time-layered nodes
- D5 to D7 learn on first-introduction events
- therefore the substantive local DAG layer is built on the earliest node for each skill in each trajectory

For each trajectory:

- a directed edge is added when the global skill edge is selected, both skills are present, and the parent's first-introduction year is strictly earlier than the child's
- transitive reduction is applied to remove redundant prerequisite edges
- same-time first-introduction pairs are exported separately as the co-requisite layer

This yields:

- `17_directed_edges_trajectories.csv`
- `17_corequisite_edges_trajectories.csv`
- `17_directed_graph_summary.csv`

## D9 implementation notes

Step D9 aggregates the reduced local D8 prerequisite DAGs into higher-level directional support graphs for:

- sections
- tracks
- programmes
- pooled

That produces:

- `18_directed_edges_sections.csv`
- `18_directed_edges_tracks.csv`
- `18_directed_edges_programmes.csv`
- `18_directed_edges_pooled.csv`
- `18_directed_aggregation_summary.csv`

The aggregation metrics exported for each edge are:

- frequency across local trajectories
- mean support probability `q`
- inclusion rate across local units

The current implementation also adds two opportunity-set diagnostics so the aggregate support can be interpreted more carefully:

- `n_local_trajectories_with_both_skills`
- `n_local_trajectories_temporally_admissible`

This makes it possible to separate:

- low support because the edge rarely appears
- low support because the two skills rarely co-occur
- low support because temporal admissibility itself is rare

The main design inference in D9 concerns section aggregation. Local graphs are trajectory-based, but the raw `section` field can change across years within a trajectory. The current reproducible rule is therefore:

- a trajectory contributes to a section aggregate if the trajectory passes through that section anywhere in the D1 panel

That rule is exported explicitly as:

- `aggregation_membership_rule = trajectory_contains_section_anywhere`

Track, programme, and pooled aggregation use exact trajectory membership:

- `trajectory_edu_type_exact_match`
- `trajectory_programme_exact_match`
- `all_trajectory_units`

Because D9 summarizes local DAG families, the aggregated graphs should be interpreted as directional support graphs. They are not required to remain strict DAGs, even though the underlying local trajectory graphs are acyclic.

## Current directed branch status

The directed branch is now implemented through D9:

- D1 to D4 build temporal admissibility and precedence evidence
- D5 to D7 learn and select the global directed rule
- D8 instantiates local first-introduction prerequisite DAGs
- D9 aggregates those local DAGs upward for comparison

The next practical step is no longer another construction step from `steps.tex`. The best next move is to either:

- review and commit the D7 to D9 outputs
- add exporter/viewer payloads for the directed graphs
- or revisit the section aggregation rule if you want a stricter year-aware section interpretation
