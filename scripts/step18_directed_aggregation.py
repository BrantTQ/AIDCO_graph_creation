from __future__ import annotations

import argparse
from collections import defaultdict

from directed_graph_common import (
    bool_string,
    format_decimal,
    join_unique_values,
    parse_float,
    read_csv_rows,
    resolve_default_path,
    script_root_for_file,
    write_csv_rows,
    year_int,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Step D9: aggregate local directed DAGs upward for comparison.")
    parser.add_argument("--directed-edges-trajectories-path", default="")
    parser.add_argument("--directed-graph-summary-path", default="")
    parser.add_argument("--trajectory-panel-path", default="")
    parser.add_argument("--directed-nodes-path", default="")
    parser.add_argument("--directed-edges-sections-output-path", default="")
    parser.add_argument("--directed-edges-tracks-output-path", default="")
    parser.add_argument("--directed-edges-programmes-output-path", default="")
    parser.add_argument("--directed-edges-pooled-output-path", default="")
    parser.add_argument("--directed-aggregation-summary-output-path", default="")
    return parser.parse_args()


def share_string(numerator: int, denominator: int) -> str:
    if denominator == 0:
        return ""
    return format_decimal(numerator / denominator)


def build_edge_rows(
    aggregation_level: str,
    aggregate_units: dict[str, dict[str, object]],
    edge_payloads_by_unit: dict[str, dict[tuple[str, str], dict[str, object]]],
    skills_by_trajectory: dict[str, set[str]],
    first_year_by_trajectory_skill: dict[tuple[str, str], int],
) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    edge_index = 1

    for aggregation_unit_id in sorted(aggregate_units):
        unit_info = aggregate_units[aggregation_unit_id]
        unit_trajectories = sorted(unit_info["trajectory_units"])
        unit_edge_payloads = edge_payloads_by_unit.get(aggregation_unit_id, {})

        for source_skill_id, target_skill_id in sorted(unit_edge_payloads):
            payload = unit_edge_payloads[(source_skill_id, target_skill_id)]
            n_local_trajectories_in_aggregate = len(unit_trajectories)
            n_local_trajectories_with_edge = len(payload["trajectory_units_with_edge"])

            n_local_trajectories_with_both_skills = 0
            n_local_trajectories_temporally_admissible = 0
            for trajectory_unit in unit_trajectories:
                skill_set = skills_by_trajectory.get(trajectory_unit, set())
                if source_skill_id not in skill_set or target_skill_id not in skill_set:
                    continue
                n_local_trajectories_with_both_skills += 1
                if first_year_by_trajectory_skill[(trajectory_unit, source_skill_id)] < first_year_by_trajectory_skill[(trajectory_unit, target_skill_id)]:
                    n_local_trajectories_temporally_admissible += 1

            rows.append(
                {
                    "aggregated_directed_edge_id": f"ADE_{aggregation_level[:3].upper()}_{edge_index:07d}",
                    "aggregation_level": aggregation_level,
                    "aggregation_unit_id": aggregation_unit_id,
                    "aggregation_unit_label": unit_info["aggregation_unit_label"],
                    "selection_mode": unit_info["selection_mode"],
                    "threshold_tau": unit_info["threshold_tau"],
                    "global_edge_rule": unit_info["global_edge_rule"],
                    "aggregation_membership_rule": unit_info["membership_rule"],
                    "source_harmonized_skill_id": source_skill_id,
                    "target_harmonized_skill_id": target_skill_id,
                    "source_harmonized_name": payload["source_harmonized_name"],
                    "target_harmonized_name": payload["target_harmonized_name"],
                    "n_local_trajectories_in_aggregate": n_local_trajectories_in_aggregate,
                    "n_local_trajectories_with_edge": n_local_trajectories_with_edge,
                    "frequency_across_local_trajectories": n_local_trajectories_with_edge,
                    "n_local_trajectories_with_both_skills": n_local_trajectories_with_both_skills,
                    "n_local_trajectories_temporally_admissible": n_local_trajectories_temporally_admissible,
                    "mean_support_probability_q": format_decimal(
                        payload["sum_edge_support_q"] / n_local_trajectories_with_edge
                    ),
                    "mean_bootstrap_selected_count": format_decimal(
                        payload["sum_bootstrap_selected_count"] / n_local_trajectories_with_edge
                    ),
                    "inclusion_rate_across_local_units": share_string(
                        n_local_trajectories_with_edge, n_local_trajectories_in_aggregate
                    ),
                    "inclusion_rate_given_both_skills": share_string(
                        n_local_trajectories_with_edge, n_local_trajectories_with_both_skills
                    ),
                    "inclusion_rate_given_temporal_admissibility": share_string(
                        n_local_trajectories_with_edge, n_local_trajectories_temporally_admissible
                    ),
                    "contributing_trajectory_units": join_unique_values(payload["trajectory_units_with_edge"]),
                    "note": "Aggregated from reduced local trajectory DAGs produced in Step D8.",
                }
            )
            edge_index += 1

    return rows


def build_summary_rows(
    aggregate_units_by_level: dict[str, dict[str, dict[str, object]]],
    aggregated_rows_by_level: dict[str, list[dict[str, object]]],
) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []

    rows.append(
        {
            "summary_level": "global",
            "aggregation_level": "",
            "aggregation_unit_id": "",
            "aggregation_unit_label": "",
            "selection_mode": "",
            "threshold_tau": "",
            "global_edge_rule": "",
            "aggregation_membership_rule": "",
            "n_aggregation_units": sum(len(units) for units in aggregate_units_by_level.values()),
            "n_local_trajectories_in_aggregate": sum(
                len(unit_info["trajectory_units"])
                for units in aggregate_units_by_level.values()
                for unit_info in units.values()
            ),
            "n_aggregated_edge_rows": sum(len(rows_for_level) for rows_for_level in aggregated_rows_by_level.values()),
            "n_unique_source_skills": "",
            "n_unique_target_skills": "",
            "mean_inclusion_rate_across_edges": "",
            "max_inclusion_rate_across_edges": "",
            "note": "Global summary across all aggregation levels derived from local directed DAGs.",
        }
    )

    for aggregation_level in ("section", "track", "programme", "pooled"):
        units = aggregate_units_by_level[aggregation_level]
        edge_rows = aggregated_rows_by_level[aggregation_level]
        inclusion_rates = [
            parse_float(row["inclusion_rate_across_local_units"])
            for row in edge_rows
            if str(row["inclusion_rate_across_local_units"]).strip()
        ]
        rows.append(
            {
                "summary_level": "level",
                "aggregation_level": aggregation_level,
                "aggregation_unit_id": "",
                "aggregation_unit_label": "",
                "selection_mode": next(iter(units.values()))["selection_mode"] if units else "",
                "threshold_tau": next(iter(units.values()))["threshold_tau"] if units else "",
                "global_edge_rule": next(iter(units.values()))["global_edge_rule"] if units else "",
                "aggregation_membership_rule": join_unique_values(
                    unit_info["membership_rule"] for unit_info in units.values()
                ),
                "n_aggregation_units": len(units),
                "n_local_trajectories_in_aggregate": sum(len(unit_info["trajectory_units"]) for unit_info in units.values()),
                "n_aggregated_edge_rows": len(edge_rows),
                "n_unique_source_skills": len({row["source_harmonized_skill_id"] for row in edge_rows}),
                "n_unique_target_skills": len({row["target_harmonized_skill_id"] for row in edge_rows}),
                "mean_inclusion_rate_across_edges": (
                    "" if not inclusion_rates else format_decimal(sum(inclusion_rates) / len(inclusion_rates))
                ),
                "max_inclusion_rate_across_edges": (
                    "" if not inclusion_rates else format_decimal(max(inclusion_rates))
                ),
                "note": "Level summary across all aggregation units.",
            }
        )

        for aggregation_unit_id in sorted(units):
            unit_info = units[aggregation_unit_id]
            unit_edge_rows = [
                row
                for row in edge_rows
                if row["aggregation_unit_id"] == aggregation_unit_id
            ]
            unit_inclusion_rates = [
                parse_float(row["inclusion_rate_across_local_units"])
                for row in unit_edge_rows
                if str(row["inclusion_rate_across_local_units"]).strip()
            ]
            rows.append(
                {
                    "summary_level": "unit",
                    "aggregation_level": aggregation_level,
                    "aggregation_unit_id": aggregation_unit_id,
                    "aggregation_unit_label": unit_info["aggregation_unit_label"],
                    "selection_mode": unit_info["selection_mode"],
                    "threshold_tau": unit_info["threshold_tau"],
                    "global_edge_rule": unit_info["global_edge_rule"],
                    "aggregation_membership_rule": unit_info["membership_rule"],
                    "n_aggregation_units": "",
                    "n_local_trajectories_in_aggregate": len(unit_info["trajectory_units"]),
                    "n_aggregated_edge_rows": len(unit_edge_rows),
                    "n_unique_source_skills": len({row["source_harmonized_skill_id"] for row in unit_edge_rows}),
                    "n_unique_target_skills": len({row["target_harmonized_skill_id"] for row in unit_edge_rows}),
                    "mean_inclusion_rate_across_edges": (
                        "" if not unit_inclusion_rates else format_decimal(sum(unit_inclusion_rates) / len(unit_inclusion_rates))
                    ),
                    "max_inclusion_rate_across_edges": (
                        "" if not unit_inclusion_rates else format_decimal(max(unit_inclusion_rates))
                    ),
                    "note": "Aggregation-unit summary derived from reduced local trajectory DAGs.",
                }
            )

    return rows


def main() -> None:
    args = parse_args()
    script_root = script_root_for_file(__file__)

    directed_edges_trajectories_path = resolve_default_path(
        args.directed_edges_trajectories_path,
        "../outputs/directed_graph/17_directed_edges_trajectories.csv",
        script_root,
    )
    directed_graph_summary_path = resolve_default_path(
        args.directed_graph_summary_path,
        "../outputs/directed_graph/17_directed_graph_summary.csv",
        script_root,
    )
    trajectory_panel_path = resolve_default_path(
        args.trajectory_panel_path,
        "../outputs/directed_graph/10_directed_trajectory_panel.csv",
        script_root,
    )
    directed_nodes_path = resolve_default_path(
        args.directed_nodes_path,
        "../outputs/directed_graph/11_directed_nodes.csv",
        script_root,
    )
    directed_edges_sections_output_path = resolve_default_path(
        args.directed_edges_sections_output_path,
        "../outputs/directed_graph/18_directed_edges_sections.csv",
        script_root,
    )
    directed_edges_tracks_output_path = resolve_default_path(
        args.directed_edges_tracks_output_path,
        "../outputs/directed_graph/18_directed_edges_tracks.csv",
        script_root,
    )
    directed_edges_programmes_output_path = resolve_default_path(
        args.directed_edges_programmes_output_path,
        "../outputs/directed_graph/18_directed_edges_programmes.csv",
        script_root,
    )
    directed_edges_pooled_output_path = resolve_default_path(
        args.directed_edges_pooled_output_path,
        "../outputs/directed_graph/18_directed_edges_pooled.csv",
        script_root,
    )
    directed_aggregation_summary_output_path = resolve_default_path(
        args.directed_aggregation_summary_output_path,
        "../outputs/directed_graph/18_directed_aggregation_summary.csv",
        script_root,
    )

    local_edge_rows = read_csv_rows(directed_edges_trajectories_path)
    trajectory_summary_rows = [
        row
        for row in read_csv_rows(directed_graph_summary_path)
        if row["summary_level"] == "trajectory"
    ]
    trajectory_panel_rows = read_csv_rows(trajectory_panel_path)
    directed_node_rows = read_csv_rows(directed_nodes_path)

    if not trajectory_summary_rows:
        raise RuntimeError(f"No trajectory-level Step D8 summaries were found in: {directed_graph_summary_path}")

    trajectory_info: dict[str, dict[str, object]] = {}
    for row in trajectory_summary_rows:
        trajectory_info[row["trajectory_unit"]] = {
            "programme": row["programme"],
            "edu_type": row["edu_type"],
            "selection_mode": row["selection_mode"],
            "threshold_tau": row["threshold_tau"],
            "global_edge_rule": row["global_edge_rule"],
        }

    trajectory_sections: dict[str, set[str]] = defaultdict(set)
    for row in trajectory_panel_rows:
        if row["section"].strip():
            trajectory_sections[row["trajectory_unit"]].add(row["section"])

    skills_by_trajectory: dict[str, set[str]] = defaultdict(set)
    first_year_by_trajectory_skill: dict[tuple[str, str], int] = {}
    for row in directed_node_rows:
        trajectory_unit = row["trajectory_unit"]
        skill_id = row["harmonized_skill_id"]
        year_value = year_int(row["year"])
        skills_by_trajectory[trajectory_unit].add(skill_id)
        key = (trajectory_unit, skill_id)
        if key not in first_year_by_trajectory_skill or year_value < first_year_by_trajectory_skill[key]:
            first_year_by_trajectory_skill[key] = year_value

    section_units: dict[str, dict[str, object]] = {}
    track_units: dict[str, dict[str, object]] = {}
    programme_units: dict[str, dict[str, object]] = {}
    pooled_units: dict[str, dict[str, object]] = {}

    all_trajectory_units = set(trajectory_info)

    for trajectory_unit, info in trajectory_info.items():
        for section in sorted(trajectory_sections.get(trajectory_unit, set())):
            section_unit = section_units.setdefault(
                section,
                {
                    "aggregation_unit_label": section,
                    "trajectory_units": set(),
                    "selection_mode": info["selection_mode"],
                    "threshold_tau": info["threshold_tau"],
                    "global_edge_rule": info["global_edge_rule"],
                    # Section membership is inferred from the trajectory panel: a trajectory
                    # contributes to a section aggregate if it passes through that section at any year.
                    "membership_rule": "trajectory_contains_section_anywhere",
                },
            )
            section_unit["trajectory_units"].add(trajectory_unit)

        track_unit = track_units.setdefault(
            str(info["edu_type"]),
            {
                "aggregation_unit_label": str(info["edu_type"]),
                "trajectory_units": set(),
                "selection_mode": info["selection_mode"],
                "threshold_tau": info["threshold_tau"],
                "global_edge_rule": info["global_edge_rule"],
                "membership_rule": "trajectory_edu_type_exact_match",
            },
        )
        track_unit["trajectory_units"].add(trajectory_unit)

        programme_unit = programme_units.setdefault(
            str(info["programme"]),
            {
                "aggregation_unit_label": str(info["programme"]),
                "trajectory_units": set(),
                "selection_mode": info["selection_mode"],
                "threshold_tau": info["threshold_tau"],
                "global_edge_rule": info["global_edge_rule"],
                "membership_rule": "trajectory_programme_exact_match",
            },
        )
        programme_unit["trajectory_units"].add(trajectory_unit)

    first_trajectory_info = next(iter(trajectory_info.values()))
    pooled_units["POOLED_ALL"] = {
        "aggregation_unit_label": "Pooled all local trajectory DAGs",
        "trajectory_units": all_trajectory_units,
        "selection_mode": first_trajectory_info["selection_mode"],
        "threshold_tau": first_trajectory_info["threshold_tau"],
        "global_edge_rule": first_trajectory_info["global_edge_rule"],
        "membership_rule": "all_trajectory_units",
    }

    membership_units_by_trajectory: dict[str, dict[str, set[str]]] = defaultdict(lambda: defaultdict(set))
    for section_id, unit_info in section_units.items():
        for trajectory_unit in unit_info["trajectory_units"]:
            membership_units_by_trajectory[trajectory_unit]["section"].add(section_id)
    for track_id, unit_info in track_units.items():
        for trajectory_unit in unit_info["trajectory_units"]:
            membership_units_by_trajectory[trajectory_unit]["track"].add(track_id)
    for programme_id, unit_info in programme_units.items():
        for trajectory_unit in unit_info["trajectory_units"]:
            membership_units_by_trajectory[trajectory_unit]["programme"].add(programme_id)
    for pooled_id, unit_info in pooled_units.items():
        for trajectory_unit in unit_info["trajectory_units"]:
            membership_units_by_trajectory[trajectory_unit]["pooled"].add(pooled_id)

    edge_payloads_by_level_and_unit: dict[str, dict[str, dict[tuple[str, str], dict[str, object]]]] = {
        "section": defaultdict(dict),
        "track": defaultdict(dict),
        "programme": defaultdict(dict),
        "pooled": defaultdict(dict),
    }

    for row in local_edge_rows:
        trajectory_unit = row["trajectory_unit"]
        edge_key = (row["source_harmonized_skill_id"], row["target_harmonized_skill_id"])
        edge_support_q = parse_float(row["edge_support_q"])
        bootstrap_selected_count = parse_float(row["bootstrap_selected_count"])

        for aggregation_level, unit_ids in membership_units_by_trajectory[trajectory_unit].items():
            for aggregation_unit_id in unit_ids:
                level_unit_payloads = edge_payloads_by_level_and_unit[aggregation_level][aggregation_unit_id]
                payload = level_unit_payloads.setdefault(
                    edge_key,
                    {
                        "source_harmonized_name": row["source_harmonized_name"],
                        "target_harmonized_name": row["target_harmonized_name"],
                        "sum_edge_support_q": 0.0,
                        "sum_bootstrap_selected_count": 0.0,
                        "trajectory_units_with_edge": set(),
                    },
                )
                payload["sum_edge_support_q"] += edge_support_q
                payload["sum_bootstrap_selected_count"] += bootstrap_selected_count
                payload["trajectory_units_with_edge"].add(trajectory_unit)

    aggregate_units_by_level = {
        "section": section_units,
        "track": track_units,
        "programme": programme_units,
        "pooled": pooled_units,
    }

    section_rows = build_edge_rows(
        "section",
        section_units,
        edge_payloads_by_level_and_unit["section"],
        skills_by_trajectory,
        first_year_by_trajectory_skill,
    )
    track_rows = build_edge_rows(
        "track",
        track_units,
        edge_payloads_by_level_and_unit["track"],
        skills_by_trajectory,
        first_year_by_trajectory_skill,
    )
    programme_rows = build_edge_rows(
        "programme",
        programme_units,
        edge_payloads_by_level_and_unit["programme"],
        skills_by_trajectory,
        first_year_by_trajectory_skill,
    )
    pooled_rows = build_edge_rows(
        "pooled",
        pooled_units,
        edge_payloads_by_level_and_unit["pooled"],
        skills_by_trajectory,
        first_year_by_trajectory_skill,
    )

    aggregated_rows_by_level = {
        "section": section_rows,
        "track": track_rows,
        "programme": programme_rows,
        "pooled": pooled_rows,
    }
    summary_rows = build_summary_rows(aggregate_units_by_level, aggregated_rows_by_level)

    edge_fieldnames = [
        "aggregated_directed_edge_id",
        "aggregation_level",
        "aggregation_unit_id",
        "aggregation_unit_label",
        "selection_mode",
        "threshold_tau",
        "global_edge_rule",
        "aggregation_membership_rule",
        "source_harmonized_skill_id",
        "target_harmonized_skill_id",
        "source_harmonized_name",
        "target_harmonized_name",
        "n_local_trajectories_in_aggregate",
        "n_local_trajectories_with_edge",
        "frequency_across_local_trajectories",
        "n_local_trajectories_with_both_skills",
        "n_local_trajectories_temporally_admissible",
        "mean_support_probability_q",
        "mean_bootstrap_selected_count",
        "inclusion_rate_across_local_units",
        "inclusion_rate_given_both_skills",
        "inclusion_rate_given_temporal_admissibility",
        "contributing_trajectory_units",
        "note",
    ]
    summary_fieldnames = [
        "summary_level",
        "aggregation_level",
        "aggregation_unit_id",
        "aggregation_unit_label",
        "selection_mode",
        "threshold_tau",
        "global_edge_rule",
        "aggregation_membership_rule",
        "n_aggregation_units",
        "n_local_trajectories_in_aggregate",
        "n_aggregated_edge_rows",
        "n_unique_source_skills",
        "n_unique_target_skills",
        "mean_inclusion_rate_across_edges",
        "max_inclusion_rate_across_edges",
        "note",
    ]

    write_csv_rows(directed_edges_sections_output_path, edge_fieldnames, section_rows)
    write_csv_rows(directed_edges_tracks_output_path, edge_fieldnames, track_rows)
    write_csv_rows(directed_edges_programmes_output_path, edge_fieldnames, programme_rows)
    write_csv_rows(directed_edges_pooled_output_path, edge_fieldnames, pooled_rows)
    write_csv_rows(directed_aggregation_summary_output_path, summary_fieldnames, summary_rows)

    print("Step D9 complete.")
    print(f"Section aggregated edge rows: {len(section_rows)}")
    print(f"Track aggregated edge rows: {len(track_rows)}")
    print(f"Programme aggregated edge rows: {len(programme_rows)}")
    print(f"Pooled aggregated edge rows: {len(pooled_rows)}")
    print("Outputs written:")
    print(f" - {directed_edges_sections_output_path}")
    print(f" - {directed_edges_tracks_output_path}")
    print(f" - {directed_edges_programmes_output_path}")
    print(f" - {directed_edges_pooled_output_path}")
    print(f" - {directed_aggregation_summary_output_path}")


if __name__ == "__main__":
    main()
