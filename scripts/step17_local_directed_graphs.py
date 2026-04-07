from __future__ import annotations

import argparse
import csv
from collections import defaultdict

from directed_graph_common import (
    bool_string,
    format_decimal,
    parse_float,
    parse_int,
    read_csv_rows,
    resolve_default_path,
    script_root_for_file,
    true_string,
    write_csv_rows,
    year_int,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Step D8: instantiate local directed graphs per trajectory.")
    parser.add_argument("--selected-model-path", default="")
    parser.add_argument("--direct-parent-scores-path", default="")
    parser.add_argument("--directed-nodes-path", default="")
    parser.add_argument("--corequisite-candidates-path", default="")
    parser.add_argument("--directed-edges-trajectories-output-path", default="")
    parser.add_argument("--corequisite-edges-trajectories-output-path", default="")
    parser.add_argument("--directed-graph-summary-output-path", default="")
    return parser.parse_args()


def build_adjacency(edges: list[tuple[str, str]]) -> dict[str, set[str]]:
    adjacency: dict[str, set[str]] = defaultdict(set)
    for source_node_id, target_node_id in edges:
        adjacency[source_node_id].add(target_node_id)
    return adjacency


def has_alternative_path(
    source_node_id: str,
    target_node_id: str,
    adjacency: dict[str, set[str]],
    edge_to_skip: tuple[str, str],
) -> bool:
    stack = [source_node_id]
    visited = {source_node_id}
    while stack:
        current = stack.pop()
        for next_node_id in adjacency.get(current, set()):
            if (current, next_node_id) == edge_to_skip:
                continue
            if next_node_id == target_node_id:
                return True
            if next_node_id not in visited:
                visited.add(next_node_id)
                stack.append(next_node_id)
    return False


def main() -> None:
    args = parse_args()
    script_root = script_root_for_file(__file__)

    selected_model_path = resolve_default_path(args.selected_model_path, "../outputs/directed_graph/16_directed_selected_model.csv", script_root)
    direct_parent_scores_path = resolve_default_path(args.direct_parent_scores_path, "../outputs/directed_graph/15_direct_parent_scores.csv", script_root)
    directed_nodes_path = resolve_default_path(args.directed_nodes_path, "../outputs/directed_graph/11_directed_nodes.csv", script_root)
    corequisite_candidates_path = resolve_default_path(
        args.corequisite_candidates_path,
        "../outputs/directed_graph/12_corequisite_candidates.csv",
        script_root,
    )
    directed_edges_trajectories_output_path = resolve_default_path(
        args.directed_edges_trajectories_output_path,
        "../outputs/directed_graph/17_directed_edges_trajectories.csv",
        script_root,
    )
    corequisite_edges_trajectories_output_path = resolve_default_path(
        args.corequisite_edges_trajectories_output_path,
        "../outputs/directed_graph/17_corequisite_edges_trajectories.csv",
        script_root,
    )
    directed_graph_summary_output_path = resolve_default_path(
        args.directed_graph_summary_output_path,
        "../outputs/directed_graph/17_directed_graph_summary.csv",
        script_root,
    )

    selected_model_rows = read_csv_rows(selected_model_path)
    if not selected_model_rows:
        raise RuntimeError(f"The selected model input is empty: {selected_model_path}")
    selected_model = selected_model_rows[0]

    selection_mode = selected_model["selection_mode"]
    threshold_tau = parse_float(selected_model.get("threshold_tau"))

    direct_parent_score_rows = read_csv_rows(direct_parent_scores_path)
    if not direct_parent_score_rows:
        raise RuntimeError(f"The direct parent scores input is empty: {direct_parent_scores_path}")
    corequisite_candidate_rows = read_csv_rows(corequisite_candidates_path)

    selected_global_edges: dict[tuple[str, str], dict[str, object]] = {}
    for row in direct_parent_score_rows:
        q_value = parse_float(row["bootstrap_selection_frequency"])
        edge_key = (row["parent_harmonized_skill_id"], row["child_harmonized_skill_id"])
        keep_edge = False
        edge_rule = ""
        if selection_mode == "thresholded_binary":
            keep_edge = q_value >= threshold_tau
            edge_rule = "bootstrap_selection_frequency_ge_tau"
        else:
            keep_edge = q_value > 0.0
            edge_rule = "bootstrap_selection_frequency_gt_zero"

        if keep_edge:
            selected_global_edges[edge_key] = {
                "parent_harmonized_skill_id": row["parent_harmonized_skill_id"],
                "child_harmonized_skill_id": row["child_harmonized_skill_id"],
                "parent_harmonized_name": row["parent_harmonized_name"],
                "child_harmonized_name": row["child_harmonized_name"],
                "edge_support_q": q_value,
                "bootstrap_selected_count": parse_int(row["bootstrap_selected_count"]),
                "bootstrap_iterations": parse_int(row["bootstrap_iterations"]),
                "candidate_parent_status": row["candidate_parent_status"],
                "precedence_basis_used": row["precedence_basis_used"],
                "full_sample_selected": row["full_sample_selected"],
                "global_edge_rule": edge_rule,
            }

    directed_nodes = read_csv_rows(directed_nodes_path)
    if not directed_nodes:
        raise RuntimeError(f"The directed nodes input is empty: {directed_nodes_path}")

    nodes_by_trajectory: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in directed_nodes:
        nodes_by_trajectory[row["trajectory_unit"]].append(row)

    first_introduction_nodes_by_trajectory: dict[str, dict[str, dict[str, object]]] = {}
    trajectory_metadata_by_unit: dict[str, dict[str, object]] = {}

    for trajectory_unit in sorted(nodes_by_trajectory):
        nodes = nodes_by_trajectory[trajectory_unit]
        trajectory_metadata_by_unit[trajectory_unit] = {
            "programme": nodes[0]["programme"],
            "edu_type": nodes[0]["edu_type"],
            "requires_branch_resolution": any(true_string(row["requires_branch_resolution"]) for row in nodes),
            "n_time_layered_nodes_total": len(nodes),
        }

        # D5 to D7 are learned on first-introduction events, so the substantive local prerequisite
        # DAG is instantiated on the earliest node for each skill within the trajectory.
        first_nodes_by_skill: dict[str, dict[str, object]] = {}
        for row in sorted(nodes, key=lambda value: (year_int(value["year"]), value["node_id"])):
            skill_id = row["harmonized_skill_id"]
            if skill_id not in first_nodes_by_skill:
                first_nodes_by_skill[skill_id] = {
                    "node_id": row["node_id"],
                    "trajectory_unit": row["trajectory_unit"],
                    "programme": row["programme"],
                    "edu_type": row["edu_type"],
                    "year": year_int(row["year"]),
                    "harmonized_skill_id": skill_id,
                    "harmonized_name": row["harmonized_name"],
                }
        first_introduction_nodes_by_trajectory[trajectory_unit] = first_nodes_by_skill

    directed_edge_rows: list[dict[str, object]] = []
    corequisite_edge_rows: list[dict[str, object]] = []
    graph_summary_rows: list[dict[str, object]] = []

    local_edge_index = 1
    local_corequisite_index = 1
    total_edges_before_reduction = 0
    total_edges_after_reduction = 0

    for trajectory_unit in sorted(first_introduction_nodes_by_trajectory):
        first_nodes_by_skill = first_introduction_nodes_by_trajectory[trajectory_unit]
        candidate_edges_before_reduction: list[tuple[str, str]] = []
        candidate_edge_payloads: dict[tuple[str, str], dict[str, object]] = {}

        for edge_key, edge_payload in selected_global_edges.items():
            parent_skill_id, child_skill_id = edge_key
            if parent_skill_id not in first_nodes_by_skill or child_skill_id not in first_nodes_by_skill:
                continue

            source_node = first_nodes_by_skill[parent_skill_id]
            target_node = first_nodes_by_skill[child_skill_id]
            if int(source_node["year"]) >= int(target_node["year"]):
                continue

            node_edge_key = (str(source_node["node_id"]), str(target_node["node_id"]))
            candidate_edges_before_reduction.append(node_edge_key)
            candidate_edge_payloads[node_edge_key] = {
                **edge_payload,
                "source_node": source_node,
                "target_node": target_node,
            }

        adjacency = build_adjacency(candidate_edges_before_reduction)
        reduced_edge_keys = [
            edge_key
            for edge_key in candidate_edges_before_reduction
            if not has_alternative_path(edge_key[0], edge_key[1], adjacency, edge_key)
        ]

        total_edges_before_reduction += len(candidate_edges_before_reduction)
        total_edges_after_reduction += len(reduced_edge_keys)

        for edge_key in sorted(reduced_edge_keys):
            payload = candidate_edge_payloads[edge_key]
            source_node = payload["source_node"]
            target_node = payload["target_node"]
            directed_edge_rows.append(
                {
                    "local_directed_edge_id": f"DLE_{local_edge_index:07d}",
                    "trajectory_unit": trajectory_unit,
                    "programme": source_node["programme"],
                    "edu_type": source_node["edu_type"],
                    "source_node_id": source_node["node_id"],
                    "target_node_id": target_node["node_id"],
                    "source_harmonized_skill_id": source_node["harmonized_skill_id"],
                    "target_harmonized_skill_id": target_node["harmonized_skill_id"],
                    "source_harmonized_name": source_node["harmonized_name"],
                    "target_harmonized_name": target_node["harmonized_name"],
                    "source_year": source_node["year"],
                    "target_year": target_node["year"],
                    "edge_support_q": format_decimal(float(payload["edge_support_q"])),
                    "selection_mode": selection_mode,
                    "threshold_tau": format_decimal(threshold_tau) if selection_mode == "thresholded_binary" else "",
                    "global_edge_rule": payload["global_edge_rule"],
                    "candidate_parent_status": payload["candidate_parent_status"],
                    "precedence_basis_used": payload["precedence_basis_used"],
                    "bootstrap_selected_count": payload["bootstrap_selected_count"],
                    "bootstrap_iterations": payload["bootstrap_iterations"],
                    "full_sample_selected": payload["full_sample_selected"],
                    "transitive_reduction_applied": "true",
                }
            )
            local_edge_index += 1

        trajectory_corequisite_count = 0
        for row in corequisite_candidate_rows:
            if row["trajectory_unit"] != trajectory_unit:
                continue
            node_a_id = row["node_a_id"]
            node_b_id = row["node_b_id"]
            node_a_skill_id = row["node_a_harmonized_skill_id"]
            node_b_skill_id = row["node_b_harmonized_skill_id"]
            if node_a_skill_id not in first_nodes_by_skill or node_b_skill_id not in first_nodes_by_skill:
                continue
            if first_nodes_by_skill[node_a_skill_id]["node_id"] != node_a_id:
                continue
            if first_nodes_by_skill[node_b_skill_id]["node_id"] != node_b_id:
                continue

            corequisite_edge_rows.append(
                {
                    "local_corequisite_edge_id": f"DCE_{local_corequisite_index:07d}",
                    "trajectory_unit": trajectory_unit,
                    "programme": row["programme"],
                    "edu_type": row["edu_type"],
                    "year": parse_int(row["year"]),
                    "node_a_id": node_a_id,
                    "node_b_id": node_b_id,
                    "node_a_harmonized_skill_id": node_a_skill_id,
                    "node_b_harmonized_skill_id": node_b_skill_id,
                    "node_a_harmonized_name": row["node_a_harmonized_name"],
                    "node_b_harmonized_name": row["node_b_harmonized_name"],
                    "corequisite_status": row["corequisite_status"],
                    "class_relation_detail": row["class_relation_detail"],
                    "branch_resolution_required": row["branch_resolution_required"],
                    "branch_pair_context": row["branch_pair_context"],
                    "layer_rule": "same_time_first_introduction_pair",
                }
            )
            local_corequisite_index += 1
            trajectory_corequisite_count += 1

        graph_summary_rows.append(
            {
                "summary_level": "trajectory",
                "trajectory_unit": trajectory_unit,
                "programme": trajectory_metadata_by_unit[trajectory_unit]["programme"],
                "edu_type": trajectory_metadata_by_unit[trajectory_unit]["edu_type"],
                "selection_mode": selection_mode,
                "threshold_tau": format_decimal(threshold_tau) if selection_mode == "thresholded_binary" else "",
                "global_edge_rule": (
                    "bootstrap_selection_frequency_ge_tau"
                    if selection_mode == "thresholded_binary"
                    else "bootstrap_selection_frequency_gt_zero"
                ),
                "n_time_layered_nodes_total": trajectory_metadata_by_unit[trajectory_unit]["n_time_layered_nodes_total"],
                "n_first_introduction_nodes": len(first_nodes_by_skill),
                "n_selected_global_edges": len(selected_global_edges),
                "n_local_directed_edges_before_reduction": len(candidate_edges_before_reduction),
                "n_local_directed_edges_after_reduction": len(reduced_edge_keys),
                "n_local_corequisite_edges": trajectory_corequisite_count,
                "requires_branch_resolution": bool_string(bool(trajectory_metadata_by_unit[trajectory_unit]["requires_branch_resolution"])),
                "note": "Local prerequisite DAG instantiated on first-introduction nodes and reduced transitively.",
            }
        )

    graph_summary_rows.insert(
        0,
        {
            "summary_level": "global",
            "trajectory_unit": "",
            "programme": "",
            "edu_type": "",
            "selection_mode": selection_mode,
            "threshold_tau": format_decimal(threshold_tau) if selection_mode == "thresholded_binary" else "",
            "global_edge_rule": (
                "bootstrap_selection_frequency_ge_tau"
                if selection_mode == "thresholded_binary"
                else "bootstrap_selection_frequency_gt_zero"
            ),
            "n_time_layered_nodes_total": sum(item["n_time_layered_nodes_total"] for item in trajectory_metadata_by_unit.values()),
            "n_first_introduction_nodes": sum(len(item) for item in first_introduction_nodes_by_trajectory.values()),
            "n_selected_global_edges": len(selected_global_edges),
            "n_local_directed_edges_before_reduction": total_edges_before_reduction,
            "n_local_directed_edges_after_reduction": total_edges_after_reduction,
            "n_local_corequisite_edges": len(corequisite_edge_rows),
            "requires_branch_resolution": bool_string(
                any(bool(item["requires_branch_resolution"]) for item in trajectory_metadata_by_unit.values())
            ),
            "note": "Global summary across all trajectory-local DAGs.",
        },
    )

    directed_edge_fieldnames = [
        "local_directed_edge_id",
        "trajectory_unit",
        "programme",
        "edu_type",
        "source_node_id",
        "target_node_id",
        "source_harmonized_skill_id",
        "target_harmonized_skill_id",
        "source_harmonized_name",
        "target_harmonized_name",
        "source_year",
        "target_year",
        "edge_support_q",
        "selection_mode",
        "threshold_tau",
        "global_edge_rule",
        "candidate_parent_status",
        "precedence_basis_used",
        "bootstrap_selected_count",
        "bootstrap_iterations",
        "full_sample_selected",
        "transitive_reduction_applied",
    ]
    corequisite_fieldnames = [
        "local_corequisite_edge_id",
        "trajectory_unit",
        "programme",
        "edu_type",
        "year",
        "node_a_id",
        "node_b_id",
        "node_a_harmonized_skill_id",
        "node_b_harmonized_skill_id",
        "node_a_harmonized_name",
        "node_b_harmonized_name",
        "corequisite_status",
        "class_relation_detail",
        "branch_resolution_required",
        "branch_pair_context",
        "layer_rule",
    ]
    summary_fieldnames = [
        "summary_level",
        "trajectory_unit",
        "programme",
        "edu_type",
        "selection_mode",
        "threshold_tau",
        "global_edge_rule",
        "n_time_layered_nodes_total",
        "n_first_introduction_nodes",
        "n_selected_global_edges",
        "n_local_directed_edges_before_reduction",
        "n_local_directed_edges_after_reduction",
        "n_local_corequisite_edges",
        "requires_branch_resolution",
        "note",
    ]

    write_csv_rows(directed_edges_trajectories_output_path, directed_edge_fieldnames, directed_edge_rows)
    write_csv_rows(corequisite_edges_trajectories_output_path, corequisite_fieldnames, corequisite_edge_rows)
    write_csv_rows(directed_graph_summary_output_path, summary_fieldnames, graph_summary_rows)

    print("Step D8 complete.")
    print(f"Local directed edges written: {len(directed_edge_rows)}")
    print(f"Local corequisite edges written: {len(corequisite_edge_rows)}")
    print("Outputs written:")
    print(f" - {directed_edges_trajectories_output_path}")
    print(f" - {corequisite_edges_trajectories_output_path}")
    print(f" - {directed_graph_summary_output_path}")


if __name__ == "__main__":
    main()
