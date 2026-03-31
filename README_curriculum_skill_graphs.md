# Curriculum Skill Graphs for ICT Sections in Luxembourg Secondary Education

## Overview

This project builds comparable **undirected skill graphs** from Luxembourg ICT curriculum documents. The pipeline starts from LLM-extracted skills with two embedding fields:

- `name_vector`
- `description_vector`

The implemented workflow currently covers:

1. Step 1: audit and preprocess the raw JSON into an occurrence-level dataset.
2. Step 2: compute global pairwise similarity on a deduplicated unique-skill base.
3. Step 3: build a manual review table for potential harmonization pairs.
4. Step 4: propagate reviewed harmonization decisions back to the full dataset.
5. Step 5: build graph-ready node tables for sections, tracks, and a pooled unit.
6. Step 6: build full weighted similarity matrices and dense edge lists.
7. Step 7: select pooled-reference susceptibility cutoffs and export both comparison-safe and local-diagnostic sparse graph families.
8. Step 8: compare available representation families and freeze the primary graph family for downstream analysis.
9. Step 9: build the descriptive atlas on the selected graph family, including graph profiles, recurrence summaries, progression overlap, and cross-unit overlap tables.

## Current inputs

Raw input fields:

- `skill_id`
- `name`
- `description`
- `sections`
- `programmes`
- `year`
- `edu_type`
- `chunk_id`
- `name_vector`
- `description_vector`

Step 1 produces the cleaned occurrence-level base:

- `data_processed/01_skills_occurrence_clean.json`
- `data_processed/01_skills_occurrence_clean.csv`

The current Step 2 workflow uses:

- `data_processed/01_unique_skills_vectors.csv`

That file contains exactly:

- `name`
- `name_vector`
- `description_vector`

and currently has `895` unique skill names.

## Current outputs on disk

Step 1:

- `data_processed/01_skills_occurrence_clean.json`
- `data_processed/01_skills_occurrence_clean.csv`
- `outputs/diagnostics/01_*`

Step 2:

- `outputs/similarity_tables/02_exact_name_groups.csv`
- `outputs/similarity_tables/02_global_pairwise_similarity.csv`
- `outputs/similarity_tables/02_similarity_summary.csv`
- `outputs/similarity_tables/02_cutoff_selection.csv`

Step 3:

- `outputs/review/03_review_pairs_unique_skills.csv`
- `outputs/review/03_review_summary.csv`
- `outputs/review/03_review_template_unique_skills.csv`

Step 4:

- `data_processed/04_unique_skills_harmonization_mapping.csv`
- `data_processed/04_unique_skills_harmonized.csv`
- `data_processed/04_skills_harmonized.json`
- `data_processed/04_skills_harmonized.csv`
- `outputs/harmonization/04_harmonization_summary.csv`
- `outputs/harmonization/04_harmonized_groups_summary.csv`

Step 5:

- `outputs/unit_definitions/05_analysis_units_definition.csv`
- `outputs/unit_definitions/05_unit_and_aggregation_decisions.csv`
- `outputs/node_tables/05_graph_ready_nodes_sections.csv`
- `outputs/node_tables/05_graph_ready_nodes_tracks.csv`
- `outputs/node_tables/05_graph_ready_nodes_pooled.csv`
- `outputs/node_tables/05_node_aggregation_summary.csv`
- `outputs/node_tables/05_harmonized_node_provenance.csv`

Step 6:

- `outputs/similarity_matrices/06_similarity_matrices_sections.csv`
- `outputs/similarity_matrices/06_similarity_matrices_tracks.csv`
- `outputs/similarity_matrices/06_similarity_matrices_pooled.csv`
- `outputs/graphs_full/06_weighted_edges_sections.csv`
- `outputs/graphs_full/06_weighted_edges_tracks.csv`
- `outputs/graphs_full/06_weighted_edges_pooled.csv`
- `outputs/graphs_full/06_weighted_graph_summary.csv`
- `outputs/graphs_full/06_weighted_graph_metadata.csv`
- `outputs/graphs_full/06_graph_storage_decisions.csv`

Step 7:

- `outputs/graphs_sparse/07_pooled_reference_cutoffs.csv`
- `outputs/graphs_sparse/07_pooled_reference_susceptibility_curves.csv`
- `outputs/graphs_sparse/07_pooled_reference_sparse_graphs_all_tracks.csv`
- `outputs/graphs_sparse/07_pooled_reference_sparse_graphs_sections.csv`
- `outputs/graphs_sparse/07_pooled_reference_sparse_graphs_tracks.csv`
- `outputs/graphs_sparse/07_pooled_reference_sparse_graphs_programmes.csv`
- `outputs/graphs_sparse/07_pooled_reference_sparse_graphs_programme_years.csv`
- `outputs/graphs_sparse/07_pooled_reference_sparse_graph_summary.csv`
- `outputs/graphs_sparse/07_local_diagnostic_cutoffs.csv`
- `outputs/graphs_sparse/07_local_diagnostic_susceptibility_curves.csv`
- `outputs/graphs_sparse/07_local_diagnostic_sparse_graphs_sections.csv`
- `outputs/graphs_sparse/07_local_diagnostic_sparse_graphs_tracks.csv`
- `outputs/graphs_sparse/07_local_diagnostic_sparse_graphs_programmes.csv`
- `outputs/graphs_sparse/07_local_diagnostic_sparse_graphs_programme_years.csv`
- `outputs/graphs_sparse/07_local_diagnostic_summary.csv`
- `outputs/graphs_sparse/07_step7_decision_log.csv`

Step 8:

- `outputs/representation_selection/08_representation_decision_matrix.csv`
- `outputs/representation_selection/08_representation_scenarios.csv`
- `outputs/representation_selection/08_unit_level_consistency_audit.csv`
- `outputs/representation_selection/08_primary_representation_selection.csv`
- `outputs/representation_selection/08_representation_selection_decision_log.csv`

Step 9:

- `outputs/descriptive_atlas/09_graph_profile_table.csv`
- `outputs/descriptive_atlas/09_programme_skill_recurrence_summary.csv`
- `outputs/descriptive_atlas/09_programme_skill_recurrence_detail.csv`
- `outputs/descriptive_atlas/09_programme_year_progression_overlap.csv`
- `outputs/descriptive_atlas/09_overlap_matrix_tracks.csv`
- `outputs/descriptive_atlas/09_overlap_matrix_sections.csv`
- `outputs/descriptive_atlas/09_overlap_matrix_programmes.csv`
- `outputs/descriptive_atlas/09_overlap_matrix_programme_years.csv`
- `outputs/descriptive_atlas/09_overlap_to_pooled.csv`
- `outputs/descriptive_atlas/09_descriptive_atlas_summary.csv`

## Implemented workflow notes

### Step 1

Current run:

- `895` raw records
- `1,038` cleaned occurrence rows
- `3072` dimensions for both vector fields
- `0` invalid vectors

Main documented deviations:

- occurrence expansion uses `chunk_id` section-programme pairs plus a stable year lookup for unresolved cases;
- duplicate detection is exact-only;
- standardization is conservative;
- arrays are serialized as JSON strings in CSV files.

### Step 2

Current run:

- `400,065` unordered different-name pairs
- temporary IDs of the form `SK_0001` are assigned inside Step 2
- `02_exact_name_groups.csv` is header-only because the input was already deduplicated by exact name

Recorded cutoffs:

- `name_only = 0.70622`
- `name_description = 0.701394`
- keep a pair if it passes at least one cutoff

### Step 3

Current run:

- `144` pairs pass the name-only cutoff
- `57` pairs pass the combined cutoff
- `41` pairs pass both
- `160` total review pairs

Current-state note:

- all `160` retained pairs are automatically marked `equivalent` in `03_review_template_unique_skills.csv`
- the current run uses the cutoff itself as the review rule

### Step 4

Current run:

- `160` reviewed `equivalent` pairs
- `0` review pairs without decision
- `746` harmonized groups
- `149` renamed unique skills
- `188` renamed full records

This means the current Step 4 outputs reflect an active harmonization state rather than a no-merge baseline.

### Step 5

Current run:

- `13` section units
- `2` track units (`CLS`, `GEN`)
- `1` pooled unit
- `949` section-level node rows
- `776` track-level node rows
- `746` pooled node rows

Documented implementation note:

- provenance is preserved across Step 4 and Step 5 outputs, but not every provenance field is duplicated in every Step 5 file.

### Step 6

Current run:

- `32` graph summaries total
- `26` section graphs
- `4` track graphs
- `2` pooled graphs

Documented implementation note:

- the full graph family is stored as long-format similarity matrices, dense unordered edge lists, graph metadata, and storage decisions rather than as a separate serialized graph-object file.

### Step 7

Current run:

- `2` pooled-reference cutoffs selected, one for each available representation family
- `341,141` pooled-reference susceptibility-curve rows written
- `474,034` local-diagnostic susceptibility-curve rows written
- `126` comparison-safe sparse-graph summaries written
- `124` local-diagnostic summaries written

Current-state note:

- the current Step 7 method is no longer the old MST/KNN rule-selection workflow
- Step 7 now selects one pooled-reference cutoff per available representation family and then exports lower-level graphs as induced subgraphs of that pooled sparse universe
- the current code maps Step 6 `name_description` to the Step 7 family label `concat`, and `fusion` is not available in the present run
- the pooled-reference usability rule uses `lambda_min = 0.90` and `iota_max = 0.10`
- both pooled cutoffs fell back to the least-aggressive susceptibility maximizer because no admissible maximizer satisfied the usability rule
- selected pooled cutoffs: `name_only = 0.585136`, `concat = 0.519089`
- the current sparse graphs are based on the harmonized Step 4 layer after automatic cutoff-based merges

### Step 8

Current run:

- `2` available representation families compared
- `0` eligible families under the pooled usability screen, so the current selection is an explicit fallback decision
- `concat` selected as the primary representation family
- pooled composite scores: `concat = 0.75`, `name_only = 0.25`
- scenario wins: `concat = 3`, `name_only = 0`
- overall unit-level consistency scores: `concat = 0.998484848485`, `name_only = 0.054761904762`

Current-state note:

- `fusion` is still unavailable in the current pipeline state
- Step 8 maps the selected family `concat` back to the Step 6 source representation `name_description`
- `name_only` is retained as the sensitivity family

### Step 9

Current run:

- selected family carried into Step 9: `concat`
- selected source representation: `name_description`
- selected pooled-reference threshold: `0.519089`
- `63` graph-profile rows
- `14` programme recurrence-summary rows
- `29` within-programme year-pair progression rows
- overlap rows: `1` track, `78` section, `91` programme, `528` programme-year
- `62` lower-unit versus pooled comparison rows

Current-state note:

- the descriptive atlas is built entirely on the frozen Step 8 primary family
- overlap matrices are stored in long-format pair tables rather than wide square CSV matrices
- the programme-year progression table currently includes all within-programme year pairs, not only adjacent years

## Current methodological decisions

- cosine similarity
- combined representation: normalized `name_vector` + normalized `description_vector`, concatenated and renormalized
- screening level: unique exact-skill-name table
- current review rule: every pair above either fixed cutoff is treated as `equivalent`
- node definition: one `harmonized_skill_id` within one analytical unit
- graph construction order: build dense weighted graphs first, sparsify later
- Step 7 primary sparsification rule: pooled-reference susceptibility maximization with ex-ante usability filters `lambda_min = 0.90` and `iota_max = 0.10`, with fallback to the least-aggressive susceptibility maximizer when no admissible maximizer exists
- Step 8 primary selection rule: pooled composite score `0.75 * structural + 0.25 * parsimony`, with unit-level consistency reported as supporting evidence only
- Step 9 descriptive basis: the frozen `concat` sparse graph family from Step 8, with descriptive overlap computed on retained nodes and edges only

## Immediate next dependency

The next workflow step is Step 10, using the frozen `concat` graph family and the Step 9 descriptive atlas as the basis for higher-order network analysis.
