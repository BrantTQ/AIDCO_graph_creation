from __future__ import annotations

import argparse
from collections import defaultdict

from directed_graph_common import (
    bool_string,
    branch_pair_context,
    branch_resolution_note,
    branch_year_state,
    class_relation_detail,
    join_class_set,
    read_csv_rows,
    resolve_default_path,
    script_root_for_file,
    split_class_ids,
    true_string,
    write_csv_rows,
    year_int,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Step D3: classify admissible temporal and same-time node pairs.")
    parser.add_argument("--directed-nodes-path", default="")
    parser.add_argument("--trajectory-audit-path", default="")
    parser.add_argument("--within-year-audit-path", default="")
    parser.add_argument("--temporal-pair-registry-output-path", default="")
    parser.add_argument("--prerequisite-candidates-output-path", default="")
    parser.add_argument("--corequisite-candidates-output-path", default="")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    script_root = script_root_for_file(__file__)

    directed_nodes_path = resolve_default_path(args.directed_nodes_path, "../outputs/directed_graph/11_directed_nodes.csv", script_root)
    trajectory_audit_path = resolve_default_path(args.trajectory_audit_path, "../outputs/directed_graph/10_directed_trajectory_audit.csv", script_root)
    within_year_audit_path = resolve_default_path(args.within_year_audit_path, "../outputs/directed_graph/10_within_year_order_audit.csv", script_root)
    temporal_pair_registry_output_path = resolve_default_path(
        args.temporal_pair_registry_output_path,
        "../outputs/directed_graph/12_temporal_pair_registry.csv",
        script_root,
    )
    prerequisite_candidates_output_path = resolve_default_path(
        args.prerequisite_candidates_output_path,
        "../outputs/directed_graph/12_prerequisite_candidates.csv",
        script_root,
    )
    corequisite_candidates_output_path = resolve_default_path(
        args.corequisite_candidates_output_path,
        "../outputs/directed_graph/12_corequisite_candidates.csv",
        script_root,
    )

    directed_nodes = read_csv_rows(directed_nodes_path)
    if not directed_nodes:
        raise RuntimeError(f"The directed nodes input is empty: {directed_nodes_path}")

    trajectory_audit_rows = read_csv_rows(trajectory_audit_path)
    within_year_audit_rows = read_csv_rows(within_year_audit_path)

    trajectory_audit_by_unit = {
        f"{row['edu_type']}__{row['programme']}": row
        for row in trajectory_audit_rows
        if row.get("audit_level") == "programme_summary"
    }
    within_year_audit_by_key = {
        f"{row['trajectory_unit']}||{year_int(row['year']):02d}": row
        for row in within_year_audit_rows
    }

    trajectory_groups: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in directed_nodes:
        trajectory_groups[row["trajectory_unit"]].append(row)

    pair_registry_rows: list[dict[str, object]] = []
    prerequisite_candidate_rows: list[dict[str, object]] = []
    corequisite_candidate_rows: list[dict[str, object]] = []

    pair_index = 1
    prerequisite_index = 1
    corequisite_index = 1

    for trajectory_unit in sorted(trajectory_groups):
        nodes = sorted(
            trajectory_groups[trajectory_unit],
            key=lambda row: (year_int(row["year"]), row["harmonized_skill_id"], row["node_id"]),
        )

        trajectory_audit_row = trajectory_audit_by_unit.get(trajectory_unit)
        if trajectory_audit_row is not None:
            branch_resolution_required = true_string(trajectory_audit_row.get("requires_branch_resolution"))
            branch_resolution_reason = trajectory_audit_row.get("branch_resolution_reason", "")
        else:
            branch_resolution_required = any(true_string(row["requires_branch_resolution"]) for row in nodes)
            branch_resolution_reason = ""

        for source_index, source_node in enumerate(nodes):
            source_year = year_int(source_node["year"])
            source_year_audit = within_year_audit_by_key.get(f"{trajectory_unit}||{source_year:02d}")
            source_branch_year_state = branch_year_state(
                None if source_year_audit is None else source_year_audit.get("same_year_structure"),
                int(source_node["n_class_ids"]),
            )
            source_class_set = split_class_ids(source_node["observed_class_ids"])

            for target_index, target_node in enumerate(nodes):
                if source_index == target_index:
                    continue

                target_year = year_int(target_node["year"])
                target_year_audit = within_year_audit_by_key.get(f"{trajectory_unit}||{target_year:02d}")
                target_branch_year_state = branch_year_state(
                    None if target_year_audit is None else target_year_audit.get("same_year_structure"),
                    int(target_node["n_class_ids"]),
                )
                target_class_set = split_class_ids(target_node["observed_class_ids"])
                class_intersection = source_class_set.intersection(target_class_set)

                temporal_relation = ""
                relation_bucket = ""
                class_relation = "not_applicable_cross_year"
                prerequisite_candidate_status = ""
                global_precedence_ready = False
                corequisite_status = ""

                if source_year < target_year:
                    temporal_relation = "earlier_to_later"
                    relation_bucket = "prerequisite_candidate"
                elif source_year > target_year:
                    temporal_relation = "reverse_time_impossible"
                    relation_bucket = "excluded_reverse_time"
                else:
                    class_relation = class_relation_detail(source_class_set, target_class_set, class_intersection)
                    temporal_relation = "same_year_same_class" if class_intersection else "same_year_different_class"
                    relation_bucket = "corequisite_candidate"

                branch_pair = branch_pair_context(branch_resolution_required, source_branch_year_state, target_branch_year_state)
                branch_note = branch_resolution_note(
                    branch_resolution_required,
                    temporal_relation,
                    branch_pair,
                    branch_resolution_reason,
                )

                if temporal_relation == "earlier_to_later":
                    if not branch_resolution_required:
                        prerequisite_candidate_status = "eligible"
                        global_precedence_ready = True
                    elif branch_pair == "single_to_single":
                        prerequisite_candidate_status = "eligible_pre_split"
                        global_precedence_ready = True
                    else:
                        prerequisite_candidate_status = "provisional_pending_branch_resolution"
                elif relation_bucket == "corequisite_candidate":
                    if branch_resolution_required and branch_pair != "single_to_single":
                        corequisite_status = "branch_sensitive_same_time"
                    else:
                        corequisite_status = "same_time_preserved"

                pair_id = f"DTP_{pair_index:07d}"
                pair_registry_rows.append(
                    {
                        "pair_id": pair_id,
                        "trajectory_unit": trajectory_unit,
                        "programme": source_node["programme"],
                        "edu_type": source_node["edu_type"],
                        "source_node_id": source_node["node_id"],
                        "target_node_id": target_node["node_id"],
                        "source_year": source_year,
                        "target_year": target_year,
                        "source_harmonized_skill_id": source_node["harmonized_skill_id"],
                        "target_harmonized_skill_id": target_node["harmonized_skill_id"],
                        "source_harmonized_name": source_node["harmonized_name"],
                        "target_harmonized_name": target_node["harmonized_name"],
                        "source_class_ids": source_node["observed_class_ids"],
                        "target_class_ids": target_node["observed_class_ids"],
                        "class_intersection_ids": join_class_set(class_intersection),
                        "class_intersection_size": len(class_intersection),
                        "source_class_context_type": source_node["class_context_type"],
                        "target_class_context_type": target_node["class_context_type"],
                        "source_year_branch_state": source_branch_year_state,
                        "target_year_branch_state": target_branch_year_state,
                        "temporal_relation": temporal_relation,
                        "relation_bucket": relation_bucket,
                        "class_relation_detail": class_relation,
                        "prerequisite_candidate_status": prerequisite_candidate_status,
                        "global_precedence_ready": bool_string(global_precedence_ready),
                        "corequisite_status": corequisite_status,
                        "branch_resolution_required": bool_string(branch_resolution_required),
                        "branch_pair_context": branch_pair,
                        "branch_resolution_note": branch_note,
                        "within_year_order_available": source_node["within_year_position_available"],
                    }
                )

                if temporal_relation == "earlier_to_later":
                    prerequisite_candidate_rows.append(
                        {
                            "prerequisite_candidate_id": f"PRC_{prerequisite_index:07d}",
                            "pair_id": pair_id,
                            "trajectory_unit": trajectory_unit,
                            "programme": source_node["programme"],
                            "edu_type": source_node["edu_type"],
                            "source_node_id": source_node["node_id"],
                            "target_node_id": target_node["node_id"],
                            "source_year": source_year,
                            "target_year": target_year,
                            "source_harmonized_skill_id": source_node["harmonized_skill_id"],
                            "target_harmonized_skill_id": target_node["harmonized_skill_id"],
                            "source_harmonized_name": source_node["harmonized_name"],
                            "target_harmonized_name": target_node["harmonized_name"],
                            "source_class_ids": source_node["observed_class_ids"],
                            "target_class_ids": target_node["observed_class_ids"],
                            "source_year_branch_state": source_branch_year_state,
                            "target_year_branch_state": target_branch_year_state,
                            "branch_resolution_required": bool_string(branch_resolution_required),
                            "branch_pair_context": branch_pair,
                            "prerequisite_candidate_status": prerequisite_candidate_status,
                            "global_precedence_ready": bool_string(global_precedence_ready),
                            "branch_resolution_note": branch_note,
                        }
                    )
                    prerequisite_index += 1
                elif relation_bucket == "corequisite_candidate" and source_node["node_id"] < target_node["node_id"]:
                    corequisite_candidate_rows.append(
                        {
                            "corequisite_candidate_id": f"CRC_{corequisite_index:07d}",
                            "trajectory_unit": trajectory_unit,
                            "programme": source_node["programme"],
                            "edu_type": source_node["edu_type"],
                            "year": source_year,
                            "node_a_id": source_node["node_id"],
                            "node_b_id": target_node["node_id"],
                            "node_a_harmonized_skill_id": source_node["harmonized_skill_id"],
                            "node_b_harmonized_skill_id": target_node["harmonized_skill_id"],
                            "node_a_harmonized_name": source_node["harmonized_name"],
                            "node_b_harmonized_name": target_node["harmonized_name"],
                            "node_a_class_ids": source_node["observed_class_ids"],
                            "node_b_class_ids": target_node["observed_class_ids"],
                            "class_intersection_ids": join_class_set(class_intersection),
                            "class_intersection_size": len(class_intersection),
                            "same_year_relation": temporal_relation,
                            "class_relation_detail": class_relation,
                            "year_branch_state": source_branch_year_state,
                            "branch_resolution_required": bool_string(branch_resolution_required),
                            "branch_pair_context": branch_pair,
                            "corequisite_status": corequisite_status,
                            "branch_resolution_note": branch_note,
                            "within_year_order_available": source_node["within_year_position_available"],
                        }
                    )
                    corequisite_index += 1

                pair_index += 1

    pair_registry_fieldnames = [
        "pair_id",
        "trajectory_unit",
        "programme",
        "edu_type",
        "source_node_id",
        "target_node_id",
        "source_year",
        "target_year",
        "source_harmonized_skill_id",
        "target_harmonized_skill_id",
        "source_harmonized_name",
        "target_harmonized_name",
        "source_class_ids",
        "target_class_ids",
        "class_intersection_ids",
        "class_intersection_size",
        "source_class_context_type",
        "target_class_context_type",
        "source_year_branch_state",
        "target_year_branch_state",
        "temporal_relation",
        "relation_bucket",
        "class_relation_detail",
        "prerequisite_candidate_status",
        "global_precedence_ready",
        "corequisite_status",
        "branch_resolution_required",
        "branch_pair_context",
        "branch_resolution_note",
        "within_year_order_available",
    ]
    prerequisite_fieldnames = [
        "prerequisite_candidate_id",
        "pair_id",
        "trajectory_unit",
        "programme",
        "edu_type",
        "source_node_id",
        "target_node_id",
        "source_year",
        "target_year",
        "source_harmonized_skill_id",
        "target_harmonized_skill_id",
        "source_harmonized_name",
        "target_harmonized_name",
        "source_class_ids",
        "target_class_ids",
        "source_year_branch_state",
        "target_year_branch_state",
        "branch_resolution_required",
        "branch_pair_context",
        "prerequisite_candidate_status",
        "global_precedence_ready",
        "branch_resolution_note",
    ]
    corequisite_fieldnames = [
        "corequisite_candidate_id",
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
        "node_a_class_ids",
        "node_b_class_ids",
        "class_intersection_ids",
        "class_intersection_size",
        "same_year_relation",
        "class_relation_detail",
        "year_branch_state",
        "branch_resolution_required",
        "branch_pair_context",
        "corequisite_status",
        "branch_resolution_note",
        "within_year_order_available",
    ]

    write_csv_rows(temporal_pair_registry_output_path, pair_registry_fieldnames, pair_registry_rows)
    write_csv_rows(prerequisite_candidates_output_path, prerequisite_fieldnames, prerequisite_candidate_rows)
    write_csv_rows(corequisite_candidates_output_path, corequisite_fieldnames, corequisite_candidate_rows)

    print("Step D3 complete.")
    print(f"Temporal registry rows: {len(pair_registry_rows)}")
    print(f"Prerequisite candidate rows: {len(prerequisite_candidate_rows)}")
    print(f"Corequisite candidate rows: {len(corequisite_candidate_rows)}")
    print("Outputs written:")
    print(f" - {temporal_pair_registry_output_path}")
    print(f" - {prerequisite_candidates_output_path}")
    print(f" - {corequisite_candidates_output_path}")


if __name__ == "__main__":
    main()
