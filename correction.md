Step 1 - minor correction
Validate the 26 occurrence expansions explicitly.
Step 1 says that sections and programmes are structurally important because later analytical units depend on them. In the current run, 26 records could not be resolved by simple list broadcasting, so the implementation used chunk_id plus a section-programme-to-year lookup. That is acceptable as a temporary repair, but those 26 records should be explicitly flagged and manually checked, because every later graph assignment depends on them. I would add a field like provenance_resolution_confidence or a boolean requires_manual_validation, and run a sensitivity version of the pipeline excluding those cases.
Otherwise Step 1 is conceptually fine.
The non-destructive principle, occurrence-level cleaning, conservative normalization, and vector integrity checks are all aligned with your goal. The main issue is not the logic of Step 1 itself, but that the ambiguous provenance repair needs a stronger audit trail before it feeds the graph pipeline.
Step 2 - major correction
Do not deduplicate to one row per unique name if you want description information to matter.
The current Step 2 creates 01_unique_skills_vectors.csv with one row per unique skill name and excludes exact-name matches from pairwise screening. That hard-codes the assumption that “same name = same skill,” which is not compatible with your goal of letting the data decide whether the description adds useful signal. If two occurrences share a name but differ meaningfully in description, the current design never gives concat a chance to distinguish them. The safer correction is to build Step 2 on one row per unique textual instance, or at least one row per unique (name, description) pair, and treat exact-name cases as a separate review stratum rather than automatic matches.
Separate “review-screening cutoff” from “graph-construction cutoff.”
In the document, the Step 2 cutoffs are chosen to decide which candidate pairs go to Step 3 for review. They are not the final graph cutoffs. Right now the wording makes “cutoff selection” sound like a single problem, but for your project there are really two different selection problems: one for harmonization candidate screening, and another for graph sparsification. Step 2 should therefore be renamed or reframed as candidate-pair screening, not graph construction.
chosen_representation = both is not a real representation choice.
The current run keeps a pair if it passes either the name_only or the name_description cutoff. That is acceptable as a screening union, but it is not a data-driven selection between representations. For your actual graph analysis, the two representations must be compared as separate graph families built on the same frozen node universe.
Make the Step 2 screening threshold data-driven.
Instead of choosing the Step 2 thresholds by inspection alone, use a small labeled pilot sample of candidate pairs and calibrate the screening threshold on held-out performance. The objective here is not “best graph,” but “high recall at a manageable review load.”
Step 3 - critical correction
Remove automatic_equivalence_by_cutoff.
Step 3 is clearly defined as a filtering stage for human judgment: no pair should be labeled equivalent yet, and the workflow should pause for manual review. But in the current run all 160 retained pairs were automatically labeled equivalent with the note automatic_equivalence_by_cutoff. This is the biggest methodological break in the pipeline.
Restore Step 3 as a true review stage.
The correct output here is a candidate table with empty review_decision and review_notes, or, if you want automation, a probabilistic prediction that is still validated separately. A raw cosine cutoff is too weak to serve as an equivalence decision rule.
Keep the uncertain state active.
The PDF explicitly allows equivalent, not_equivalent, and uncertain. That third state matters because it prevents forced merges when the evidence is ambiguous. The current implementation erased that safeguard by converting all retained pairs directly into positive merges.
Step 4 - critical correction
Rebuild harmonization only from validated equivalence decisions.
Step 4 is supposed to use reviewed equivalent pairs and keep not_equivalent and uncertain pairs separate. In the current run, Step 4 was executed before manual review was filled, so it inherited the automatic labels from Step 3 and created an active harmonization state with 746 groups from 895 unique skills. That entire harmonization layer should be treated as provisional and rebuilt.
Add a component-level audit for chain merges.
Step 4 uses connected components: if A is equivalent to B and B to C, then A, B, and C become one group. That is mathematically fine only if the pair decisions are already trustworthy. With noisy or cutoff-driven positives, one false edge can over-merge an entire chain. I would therefore add a second validation pass for multi-name connected components before freezing the harmonization map.
Freeze harmonization independently from representation comparison.
Your later comparison between name_only and concat should not be allowed to change the node universe. Harmonization needs to be fixed first, using either reviewed merges or a no-merge baseline, and then both graph families must be built on that same node set.
Use a transparent naming rule for multi-skill groups.
The PDF allows a representative harmonized name to be chosen when a group has multiple labels. That choice should follow a declared rule, such as group medoid label or most frequent label, and the rationale should be recorded in 04_harmonized_name_selection.csv.
Step 5 - critical correction
Explicitly define every aggregation level that is actually analyzed later.
Step 5 formally defines only section, track, and pooled. But later steps analyze programmes and programme-years, and Step 9 even states that programme-year graphs are the primary observational layer. If your goal is one graph per aggregation level, Step 5 must explicitly define at least: pooled, track, section, programme, and programme_year.
Create graph-ready node tables for programme and programme-year units.
Those node universes should not first appear implicitly in Step 7 or Step 9. They belong in Step 5, because Step 5 is where the unit definition and node rule are frozen. I would add files like 05_graph_ready_nodes_programmes.csv and 05_graph_ready_nodes_programme_years.csv.
Fix the internal inconsistency in the current-run notes.
Step 5 says there are 746 pooled node rows, but it also says the pooled unit collapses 1,038 source records into 895 graph nodes and that Step 4 contains no reviewed merges. That cannot all be true at once, because Step 4 itself reports 746 harmonized groups after automatic merging. This section needs to be rewritten after Step 4 is corrected and rerun.
Freeze the node-embedding aggregation rule before representation comparison.
Step 5 correctly notes that averaging across contributing records is a substantive choice. You should log that choice explicitly and keep it fixed across both name_only and concat, so the representation comparison is not contaminated by a changing node-construction rule.
Step 6 - moderate correction
Rerun Step 6 after correcting Steps 3 to 5.
Step 6 itself is mechanically fine, but the document explicitly states that the current weighted graphs were built on node tables from the active Step 4 harmonization layer where cutoff-retained pairs were merged automatically. That means the current weighted graph family inherits the Step 3/4 error.
Make the programme and programme-year path explicit.
Step 6 exports weighted graphs only for sections, tracks, and pooled units, while later steps use programmes and programme-years. Either Step 6 needs to export those weighted graphs too, or the document needs to state clearly that they are derived from pooled weighted graphs or from Step 5 node tables on the fly. Right now that part is under-specified.
Step 7 - critical correction
Replace the fixed usability screen and fallback rule.
The current Step 7 uses fixed ex ante parameters λmin = 0.90 and ιmax = 0.10, and when no susceptibility-maximizing threshold passes that screen it falls back to the least aggressive maximizer. That is a heuristic selector, and it is exactly what you said you do not want. In the current run both families fail the screen, so both cutoffs are fallback cutoffs.
Choose graph cutoff with an empirical objective.
For your goal, the selector should be data-driven. The cleanest options are:
bootstrap stability of retained edges and connected components;
out-of-sample predictive validity, if you have an external signal;
a joint objective based on reproducibility across resampled curricula.
Susceptibility can still be reported, but it should be a diagnostic, not the final decision rule.
Select at the aggregation level that matches your scientific objective.
The current Step 7 chooses a pooled all-tracks cutoff and then induces lower-level graphs from it. That is a defensible comparability design, but it is not the same as selecting the best graph for each aggregation level. If your real aim is one best graph per level, then the selection problem should be indexed by level. In practice: select (representation, cutoff) separately for pooled, track, section, programme, and programme_year, using the same empirical criterion in each case.
Do not treat fragmented fallback graphs as final.
The selected pooled graphs are still fragmented: name_only has largest-component share 0.0791 and isolate share 0.4812; concat has largest-component share 0.2681 and isolate share 0.2534. Those are not strong final graphs for substantive interpretation.
Step 8 - critical correction
Remove the weighted composite score as the decision rule.
Step 8 uses fixed ex ante weights for structural adequacy and parsimony, then adds scenario totals with alternative fixed weights. That is another heuristic layer. If you want a data-driven representation choice, Step 8 should not rank families by hand-set weights.
Do not freeze concat from a fallback comparison.
In the current run neither name_only nor concat passes the usability screen, yet Step 8 still freezes concat as the primary family with fallback_decision = TRUE. That should not be the final mainline decision. If no candidate is empirically adequate, the pipeline should go back and revise the selector rather than freeze a fallback winner.
Compare representations only on the same corrected node universe.
After Step 4 is fixed, both representations must be evaluated on exactly the same harmonization layer and the same Step 5 unit definitions. Otherwise the representation comparison is confounded with a changing node set.
Re-scope Step 8 as a reporting step, not a second heuristic selection stage.
Once Step 7 becomes a true joint data-driven selector over (representation, cutoff), Step 8 should mostly summarize the result and freeze the selection record. If you keep your goal as “one graph per aggregation level,” then Step 8 should freeze one selection record per level, not one universal pooled decision.
Step 9 - downstream correction
Treat the current descriptive atlas as provisional only.
Step 9 currently uses the concat family selected in Step 8 at threshold 0.519089, but that choice came from the fallback process above. So the current atlas is exploratory, not final. The pooled graph also remains quite fragmented, with 746 nodes, 739 retained edges, and largest-component share 0.2681.
Rerun Step 9 after the corrected selection pipeline is frozen.
Once Steps 3 to 8 are fixed, Step 9 should be regenerated from the corrected graph families. Each output table should carry the graph-construction metadata: harmonization version, representation, cutoff, aggregation level, and selection score.
If progression is a key substantive question, make adjacent-year comparisons primary.
The current implementation includes all unordered year pairs within programme progression. That is useful as a supplementary atlas, but if the main question is curriculum progression, adjacent years should be the primary comparison and all-pair comparisons should be secondary.
The shortest practical rerun order
Fix Step 1 logging for the 26 ambiguous provenance cases.
Redesign Step 2 so exact-name cases are not auto-collapsed and so review screening is separate from graph cutoff selection.
Restore Step 3 as a true review or validated classification stage.
Rebuild Step 4 harmonization from reviewed decisions only.
Rewrite Step 5 so all aggregation levels are formally defined and counted consistently.
Rerun Step 6 on the corrected node universe.
Replace Step 7 and Step 8 with a joint data-driven selection of representation and cutoff.
Rerun Step 9 only after those selections are frozen.