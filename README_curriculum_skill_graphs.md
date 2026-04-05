# Curriculum Skill Graphs for ICT Sections in Luxembourg Secondary Education

## Overview

This project builds comparable undirected skill graphs from Luxembourg ICT curriculum documents. The pipeline starts from the raw extracted JSON with two embedding fields:

- `name_vector`
- `description_vector`

The corrected workflow currently covers:

1. Step 1: audit and preprocess the raw JSON into a validated occurrence-level dataset, with explicit provenance flags for ambiguous expansions.
2. Step 2: compute global candidate-pair screening on a unique textual-instance base.
3. Step 3: build a true manual-review table with blank review fields.
4. Step 4: build harmonization only from reviewed `equivalent` decisions, or keep a no-merge baseline if no decisions have been entered.
5. Step 5: build graph-ready node tables for pooled, track, section, programme, and programme-year units.
6. Step 6: build full weighted graph families for both semantic representations at all aggregation levels.
7. Step 7: jointly select representation and cutoff separately for each aggregation level using data-driven cross-validated log-loss skill.
8. Step 8: freeze and report the Step 7 level-wise selected models.
9. Step 9: build the descriptive atlas on the corrected level-wise selected graph family, which may mix sparse and full weighted graphs across levels.

Supporting project notes:

- curated file inventory: `DATA_INVENTORY_steps_1_to_9.md`
- validation and double-check note: `STEP1_TO_9_DOUBLE_CHECK.md`
- correction brief applied in this pass: `correction.md`

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

The corrected Step 2 workflow uses:

- `data_processed/01_unique_textual_instances_vectors.csv`

This file contains one row per unique textual instance and currently has:

- `895` rows
- `0` exact-name duplicate strata in the present corpus

## Current corrected outputs on disk

### Step 1

- `data_processed/01_skills_occurrence_clean.json`
- `data_processed/01_skills_occurrence_clean.csv`
- `data_processed/01_skills_occurrence_clean_sensitivity_excluding_ambiguous.json`
- `data_processed/01_skills_occurrence_clean_sensitivity_excluding_ambiguous.csv`
- `data_processed/01_unique_textual_instances_vectors.csv`
- `outputs/diagnostics/01_*`

### Step 2

- `outputs/similarity_tables/02_candidate_pairwise_similarity.csv`
- `outputs/similarity_tables/02_candidate_screening_summary.csv`
- `outputs/similarity_tables/02_screening_cutoff_selection.csv`
- `outputs/similarity_tables/02_exact_name_candidate_stratum.csv`
- `outputs/similarity_tables/02_screening_calibration_template.csv`

### Step 3

- `outputs/review/03_review_pairs_textual_instances.csv`
- `outputs/review/03_review_summary.csv`
- `outputs/review/03_review_template_textual_instances.csv`

### Step 4

- `data_processed/04_textual_instances_harmonization_mapping.csv`
- `data_processed/04_textual_instances_harmonized.csv`
- `data_processed/04_skills_harmonized.json`
- `data_processed/04_skills_harmonized.csv`
- `data_processed/04_unique_skills_harmonization_mapping.csv`
- `data_processed/04_unique_skills_harmonized.csv`
- `outputs/harmonization/04_component_merge_audit.csv`
- `outputs/harmonization/04_harmonization_summary.csv`
- `outputs/harmonization/04_harmonized_groups_summary.csv`
- `outputs/harmonization/04_harmonized_name_selection.csv`

### Step 5

- `outputs/unit_definitions/05_analysis_units_definition.csv`
- `outputs/unit_definitions/05_unit_and_aggregation_decisions.csv`
- `outputs/node_tables/05_graph_ready_nodes_pooled.csv`
- `outputs/node_tables/05_graph_ready_nodes_tracks.csv`
- `outputs/node_tables/05_graph_ready_nodes_sections.csv`
- `outputs/node_tables/05_graph_ready_nodes_programmes.csv`
- `outputs/node_tables/05_graph_ready_nodes_programme_years.csv`
- `outputs/node_tables/05_harmonized_node_provenance.csv`
- `outputs/node_tables/05_node_aggregation_summary.csv`

### Step 6

- `outputs/similarity_matrices/06_similarity_matrices_pooled.csv`
- `outputs/similarity_matrices/06_similarity_matrices_tracks.csv`
- `outputs/similarity_matrices/06_similarity_matrices_sections.csv`
- `outputs/similarity_matrices/06_similarity_matrices_programmes.csv`
- `outputs/similarity_matrices/06_similarity_matrices_programme_years.csv`
- `outputs/graphs_full/06_weighted_edges_pooled.csv`
- `outputs/graphs_full/06_weighted_edges_tracks.csv`
- `outputs/graphs_full/06_weighted_edges_sections.csv`
- `outputs/graphs_full/06_weighted_edges_programmes.csv`
- `outputs/graphs_full/06_weighted_edges_programme_years.csv`
- `outputs/graphs_full/06_weighted_graph_summary.csv`
- `outputs/graphs_full/06_weighted_graph_metadata.csv`
- `outputs/graphs_full/06_graph_storage_decisions.csv`

### Step 7

- `outputs/graphs_sparse/07_levelwise_model_selection_surface.csv`
- `outputs/graphs_sparse/07_levelwise_selected_models.csv`
- `outputs/graphs_sparse/07_selected_graphs_pooled.csv`
- `outputs/graphs_sparse/07_selected_graphs_tracks.csv`
- `outputs/graphs_sparse/07_selected_graphs_sections.csv`
- `outputs/graphs_sparse/07_selected_graphs_programmes.csv`
- `outputs/graphs_sparse/07_selected_graphs_programme_years.csv`
- `outputs/graphs_sparse/07_edge_selection_probabilities_pooled.csv`
- `outputs/graphs_sparse/07_edge_selection_probabilities_tracks.csv`
- `outputs/graphs_sparse/07_edge_selection_probabilities_sections.csv`
- `outputs/graphs_sparse/07_edge_selection_probabilities_programmes.csv`
- `outputs/graphs_sparse/07_edge_selection_probabilities_programme_years.csv`
- `outputs/graphs_sparse/07_selected_graph_summary.csv`
- `outputs/graphs_sparse/07_selection_decision_log.csv`

### Step 8

- `outputs/representation_selection/08_levelwise_alternatives.csv`
- `outputs/representation_selection/08_primary_representation_selection.csv`
- `outputs/representation_selection/08_levelwise_selection_report.csv`
- `outputs/representation_selection/08_selection_freeze_log.csv`

### Step 9

- `outputs/descriptive_atlas/09_graph_profile_table.csv`
- `outputs/descriptive_atlas/09_programme_skill_recurrence_summary.csv`
- `outputs/descriptive_atlas/09_programme_skill_recurrence_detail.csv`
- `outputs/descriptive_atlas/09_programme_year_adjacent_progression_overlap.csv`
- `outputs/descriptive_atlas/09_programme_year_progression_overlap_all_pairs.csv`
- `outputs/descriptive_atlas/09_overlap_matrix_tracks.csv`
- `outputs/descriptive_atlas/09_overlap_matrix_sections.csv`
- `outputs/descriptive_atlas/09_overlap_matrix_programmes.csv`
- `outputs/descriptive_atlas/09_overlap_matrix_programme_years.csv`
- `outputs/descriptive_atlas/09_overlap_to_pooled.csv`
- `outputs/descriptive_atlas/09_descriptive_atlas_summary.csv`

### Final export package

- `outputs/final_graphs_selected_methodology/final_edges_pooled.csv`
- `outputs/final_graphs_selected_methodology/final_edges_tracks.csv`
- `outputs/final_graphs_selected_methodology/final_edges_sections.csv`
- `outputs/final_graphs_selected_methodology/final_edges_programmes.csv`
- `outputs/final_graphs_selected_methodology/final_edges_programme_years.csv`
- `outputs/final_graphs_selected_methodology/final_nodes_master.csv`
- `outputs/final_graphs_selected_methodology/final_graph_export_manifest.csv`
- `outputs/final_graphs_selected_methodology/README_final_graphs.txt`

## Current implementation notes

### Step 1

Current run:

- `895` raw records
- `1,038` occurrence rows after preprocessing
- `26` raw records required fallback provenance repair
- `88` occurrence rows are flagged `requires_manual_validation = true`
- `950` rows remain in the sensitivity dataset that excludes ambiguous provenance cases
- both vector fields are `3072`-dimensional and fully valid

### Step 2

Current run:

- `895` unique textual instances in the candidate-screening base
- `400,065` unordered candidate pairs
- `0` exact-name stratum pairs in the present corpus
- provisional screening cutoffs:
  - `name_only = 0.70622`
  - `name_description = 0.701394`

These are screening cutoffs only. Final graph sparsification is selected later in Steps 7 and 8.

### Step 3

Current run:

- `160` total review pairs
- `144` pairs pass the `name_only` screening cutoff
- `57` pairs pass the `name_description` screening cutoff
- `41` pairs pass both
- `16` review pairs contain at least one text instance flagged for manual provenance validation
- `review_decision` and `review_notes` remain blank

### Step 4

Current run:

- `0` reviewed `equivalent` pairs
- `160` review pairs still without decision
- `895` harmonized groups from `895` textual instances
- harmonization mode: `no_merge_baseline`

This means the current downstream graph family is built on a corrected no-merge baseline, not on automatic cutoff merges.

### Step 5

Current run:

- `1` pooled unit
- `2` track units
- `13` section units
- `14` programme units
- `33` programme-year units

Node totals:

- pooled: `895`
- tracks: `895`
- sections: `1,036`
- programmes: `969`
- programme-years: `1,037`

### Step 6

Current run:

- `63` analytical units
- `126` weighted graphs across the two semantic representations

### Step 7

Current run selects the following level-wise models:

- pooled: `name_only` at `0.814399`, `sparsification_supported = TRUE`
- track: `name_only` at `0.819634`, `sparsification_supported = FALSE`
- section: `name_only` at `0.831524`, `sparsification_supported = FALSE`
- programme: `concat` (`name_description`) at `0.879671`, `sparsification_supported = FALSE`
- programme-year: `concat` (`name_description`) at `0.790938`, `sparsification_supported = FALSE`

Selection is based on cross-validated log-loss skill at each level. In the present run, only the pooled graph supports thresholded sparsification; all other levels revert to their full weighted graphs.

### Step 8

Current run freezes the five Step 7 selections directly from `07_levelwise_selected_models.csv`. Step 8 no longer applies a second selector and retains only the frozen winning row per level because the full candidate surface already remains in Step 7.

### Step 9

Current run:

- `63` graph-profile rows
- `14` programme recurrence summaries
- `969` programme recurrence detail rows
- `19` adjacent-year progression rows
- `29` all-pairs progression rows
- overlap rows:
  - tracks: `1`
  - sections: `78`
  - programmes: `91`
  - programme-years: `528`

Step 9 now reads the final selected graph files from Step 7. Because four levels retained full weighted graphs in the current run, edge-overlap diagnostics are intentionally left blank for those full-graph comparisons and the atlas emphasizes node overlap plus graph-profile summaries there.

## Current status

The main pipeline is corrected and rerun through Step 9. The biggest remaining substantive checkpoint is still the Step 3 manual review. Until review decisions are entered, the harmonization layer remains a no-merge baseline and all downstream graphs describe that baseline.
