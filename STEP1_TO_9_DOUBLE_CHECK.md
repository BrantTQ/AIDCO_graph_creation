# Step 1 to 9 Double-Check Review

This note records the main things that should still be double-checked after the correction pass. It is no longer focused on the old automatic-merge and pooled-fallback pipeline. Instead, it reflects the corrected workflow now on disk.

## Highest-priority checks

### Step 1 provenance repairs

- Recheck the 26 raw records that required fallback provenance reconstruction.
- Confirm that the 88 occurrence rows flagged `requires_manual_validation = true` are acceptable to keep in the mainline dataset.
- Compare any sensitive downstream summaries against `01_skills_occurrence_clean_sensitivity_excluding_ambiguous.*` when provenance robustness matters.

### Step 2 screening thresholds

- The current Step 2 cutoffs are still `analyst_fixed_provisional`, not pilot-calibrated.
- Confirm that `0.70622` and `0.701394` are acceptable as temporary review-screening thresholds.
- If review workload changes, recalibrate Step 2 on a labeled pilot before treating the screening policy as frozen.

### Step 3 manual review state

- `03_review_template_textual_instances.csv` is intentionally blank.
- No reviewed `equivalent`, `not_equivalent`, or `uncertain` decisions have been entered yet.
- Confirm that the project is comfortable treating all downstream outputs as a no-merge baseline until that review is completed.

### Step 4 no-merge baseline

- The current harmonization layer has 895 groups from 895 textual instances.
- Confirm that this no-merge baseline is the intended current reference state.
- Once review decisions are entered, rerun Steps 4 to 9 and inspect `04_component_merge_audit.csv` carefully for chain merges.

### Step 7 level-wise selector

- Confirm that the bootstrap selection objective is acceptable as the main selector:
  - maximize mean bootstrap edge Jaccard;
  - then maximize connected-node share;
  - then minimize largest-component-share variability.
- Inspect the selected pooled, track, and programme graphs carefully, because they remain very sparse and fragmented.
- Confirm that using different selected representations by level is acceptable for the scientific goals of the project.

### Step 8 freeze logic

- Confirm that Step 8 should remain freeze-and-report only.
- Confirm that one selection record per level is preferable to forcing one universal family across all levels.

## Step-specific reminders

### Step 1

- Duplicate detection is exact-only.
- Text normalization is conservative.
- The corrected Step 2 base is `01_unique_textual_instances_vectors.csv`, not `01_unique_skills_vectors.csv`.

### Step 2

- Exact-name cases are handled as a review stratum, not as automatic matches.
- Step 2 cutoffs are review-screening cutoffs only and should not be interpreted as graph-construction cutoffs.

### Step 3

- Keep the `uncertain` state active once review begins.
- Do not reintroduce automatic equivalence-by-cutoff.

### Step 4

- Representative harmonized names are chosen by `most_frequent_label_then_lexicographic_tiebreak_with_optional_manual_override`.
- Multi-member connected components should always be inspected after review-based merges are introduced.

### Step 5

- All five aggregation levels are now explicit: pooled, track, section, programme, and programme-year.
- The node-embedding aggregation rule is fixed across both representations.

### Step 6

- Weighted graphs are stored in long-format edge tables and summary files rather than square adjacency matrices.
- The corrected weighted family spans 63 units and 126 graphs.

### Step 7

- The current selected configurations are:
  - pooled: `name_only`, `0.814399`, sparse graph supported
  - track: `name_only`, `0.819634`, full weighted graph retained
  - section: `name_only`, `0.831524`, full weighted graph retained
  - programme: `name_description`, `0.879671`, full weighted graph retained
  - programme-year: `name_description`, `0.790938`, full weighted graph retained

### Step 9

- Adjacent-year progression is now the primary progression output.
- All-pairs year progression is retained only as a secondary supplementary view.
- The current atlas still reflects the Step 4 no-merge baseline.

## Suggested quick audit before Step 10

1. Manually inspect the 26 provenance-repair raw records and a sample of the 88 flagged occurrence rows.
2. Review the current Step 7 selected graphs for pooled, tracks, and programmes to confirm that the chosen sparsity is still analytically useful.
3. Complete the Step 3 review file if actual harmonization is needed before Step 10.
4. If reviewed harmonization decisions are added, rerun Steps 4 to 9 and regenerate the final graph export package.
