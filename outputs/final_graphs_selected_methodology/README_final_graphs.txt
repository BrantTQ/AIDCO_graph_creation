Final undirected graph export package

This folder contains the corrected final graph package exported from the current pipeline state.
Selections are level-specific and come from outputs/representation_selection/08_primary_representation_selection.csv.

Files:
- final_edges_pooled.csv
- final_edges_tracks.csv
- final_edges_sections.csv
- final_edges_programmes.csv
- final_edges_programme_years.csv
- final_nodes_master.csv
- final_graph_export_manifest.csv

Notes:
- Edge files are undirected edge lists with retained edge weights.
- The current selected graph family is mixed: pooled is thresholded and sparse, while tracks, sections, programmes, and programme-years currently retain their full weighted graphs because Step 7 did not support sparsification at those levels.
- final_nodes_master.csv contains the pooled node universe plus provenance, memberships, and node vectors.
- The current corrected harmonization state is a no-merge baseline unless reviewed equivalent decisions are later added and Steps 4 to 9 are rerun.
