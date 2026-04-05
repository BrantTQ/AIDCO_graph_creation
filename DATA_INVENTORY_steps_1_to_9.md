# Data Inventory for Steps 1 to 9

This is the curated inventory for the corrected Step 1 to Step 9 workflow.

Included here:

- substantive inputs
- workflow specifications
- pipeline scripts
- corrected processed data and outputs
- final export package

Excluded on purpose:

- local build artifacts such as `scripts/*/bin` and `scripts/*/obj`
- LaTeX aux/log/cache files
- stale provisional outputs from superseded pre-correction runs

## Core inputs

- `all_tracks_embeddings_enriched.json`
- `correction.md`

## Workflow specifications

- `Step1_Data_ Audit_Preprocessing.tex`
- `step2_global_similarity.tex`
- `step3_review_table.tex`
- `step4_harmonization_dataset.tex`
- `step5_graph_ready_nodes.tex`
- `step6_weighted_graphs.tex`
- `step7_sparsification.tex`
- `step8_representation_comparison_selection.tex`
- `step9_Descriptive_profiling_overlapanalysis.tex`

## Project notes

- `README_curriculum_skill_graphs.md`
- `STEP1_TO_9_DOUBLE_CHECK.md`
- `steps_1_to_9_master.tex`
- `steps_1_to_9_master.pdf`

## Pipeline scripts

### Step 1

- `scripts/step1_data_audit_preprocessing.ps1`

### Step 2

- `scripts/Step2GlobalSimilarity/Program.cs`
- `scripts/Step2GlobalSimilarity/Step2GlobalSimilarity.csproj`

### Step 3

- `scripts/step3_review_table.ps1`

### Step 4

- `scripts/step4_harmonization_dataset.ps1`

### Step 5

- `scripts/Step5GraphReadyNodes/Program.cs`
- `scripts/Step5GraphReadyNodes/Step5GraphReadyNodes.csproj`

### Step 6

- `scripts/Step6WeightedGraphs/Program.cs`
- `scripts/Step6WeightedGraphs/Step6WeightedGraphs.csproj`

### Step 7

- `scripts/Step7Sparsification/Program.cs`
- `scripts/Step7Sparsification/Step7Sparsification.csproj`

### Step 8

- `scripts/step8_representation_comparison_selection.ps1`

### Step 9

- `scripts/step9_descriptive_profiling_overlapanalysis.ps1`

### Export

- `scripts/export_final_selected_graphs.ps1`

## Corrected processed data and outputs

### Step 1

- `data_processed/01_skills_occurrence_clean.json`
- `data_processed/01_skills_occurrence_clean.csv`
- `data_processed/01_skills_occurrence_clean_sensitivity_excluding_ambiguous.json`
- `data_processed/01_skills_occurrence_clean_sensitivity_excluding_ambiguous.csv`
- `data_processed/01_unique_textual_instances_vectors.csv`
- `outputs/diagnostics/01_coverage_by_curricular_origin.csv`
- `outputs/diagnostics/01_data_audit_summary.csv`
- `outputs/diagnostics/01_duplicate_report.csv`
- `outputs/diagnostics/01_metadata_standardization_log.csv`
- `outputs/diagnostics/01_preprocessing_decision_log.csv`
- `outputs/diagnostics/01_provenance_resolution_audit.csv`
- `outputs/diagnostics/01_schema_validation_summary.csv`
- `outputs/diagnostics/01_step1_deviations_notes.txt`
- `outputs/diagnostics/01_vector_integrity_report.csv`
- `outputs/diagnostics/01_vector_integrity_summary.csv`

### Step 2

- `outputs/similarity_tables/02_candidate_pairwise_similarity.csv`
- `outputs/similarity_tables/02_candidate_screening_summary.csv`
- `outputs/similarity_tables/02_exact_name_candidate_stratum.csv`
- `outputs/similarity_tables/02_screening_calibration_template.csv`
- `outputs/similarity_tables/02_screening_cutoff_selection.csv`

### Step 3

- `outputs/review/03_review_pairs_textual_instances.csv`
- `outputs/review/03_review_summary.csv`
- `outputs/review/03_review_template_textual_instances.csv`

### Step 4

- `data_processed/04_skills_harmonized.csv`
- `data_processed/04_skills_harmonized.json`
- `data_processed/04_textual_instances_harmonization_mapping.csv`
- `data_processed/04_textual_instances_harmonized.csv`
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
- `outputs/graphs_full/06_graph_storage_decisions.csv`
- `outputs/graphs_full/06_weighted_edges_pooled.csv`
- `outputs/graphs_full/06_weighted_edges_tracks.csv`
- `outputs/graphs_full/06_weighted_edges_sections.csv`
- `outputs/graphs_full/06_weighted_edges_programmes.csv`
- `outputs/graphs_full/06_weighted_edges_programme_years.csv`
- `outputs/graphs_full/06_weighted_graph_metadata.csv`
- `outputs/graphs_full/06_weighted_graph_summary.csv`

### Step 7

- `outputs/graphs_sparse/07_levelwise_model_selection_surface.csv`
- `outputs/graphs_sparse/07_levelwise_selected_models.csv`
- `outputs/graphs_sparse/07_selected_graph_summary.csv`
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
- `outputs/graphs_sparse/07_selection_decision_log.csv`

### Step 8

- `outputs/representation_selection/08_levelwise_alternatives.csv`
- `outputs/representation_selection/08_levelwise_selection_report.csv`
- `outputs/representation_selection/08_primary_representation_selection.csv`
- `outputs/representation_selection/08_selection_freeze_log.csv`

### Step 9

- `outputs/descriptive_atlas/09_descriptive_atlas_summary.csv`
- `outputs/descriptive_atlas/09_graph_profile_table.csv`
- `outputs/descriptive_atlas/09_overlap_matrix_programmes.csv`
- `outputs/descriptive_atlas/09_overlap_matrix_programme_years.csv`
- `outputs/descriptive_atlas/09_overlap_matrix_sections.csv`
- `outputs/descriptive_atlas/09_overlap_matrix_tracks.csv`
- `outputs/descriptive_atlas/09_overlap_to_pooled.csv`
- `outputs/descriptive_atlas/09_programme_skill_recurrence_detail.csv`
- `outputs/descriptive_atlas/09_programme_skill_recurrence_summary.csv`
- `outputs/descriptive_atlas/09_programme_year_adjacent_progression_overlap.csv`
- `outputs/descriptive_atlas/09_programme_year_progression_overlap_all_pairs.csv`

### Final export package

- `outputs/final_graphs_selected_methodology/final_edges_pooled.csv`
- `outputs/final_graphs_selected_methodology/final_edges_tracks.csv`
- `outputs/final_graphs_selected_methodology/final_edges_sections.csv`
- `outputs/final_graphs_selected_methodology/final_edges_programmes.csv`
- `outputs/final_graphs_selected_methodology/final_edges_programme_years.csv`
- `outputs/final_graphs_selected_methodology/final_nodes_master.csv`
- `outputs/final_graphs_selected_methodology/final_graph_export_manifest.csv`
- `outputs/final_graphs_selected_methodology/README_final_graphs.txt`
