"""Unit tests for the pipeline exporter. Run: python -m unittest discover -s tests"""

import json
import pathlib
import sys
import unittest
from datetime import datetime, timedelta, timezone

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "charts" / "pipeline-observability" / "files"))

import pipeline_exporter as pe  # noqa: E402

NOW = datetime(2026, 10, 28, 12, 0, tzinfo=timezone.utc)


def run(id, *, hours_ago, conclusion="success", workflow="opentofu.yml", branch="main", event="push",
        minutes=5, queued=1, sha=None, commit_hours_before=1):
    finished = NOW - timedelta(hours=hours_ago)
    started = finished - timedelta(minutes=minutes)
    return pe.Run(
        id=id, workflow=workflow, event=event, branch=branch, conclusion=conclusion,
        created=started - timedelta(minutes=queued), started=started, finished=finished,
        head_sha=sha or f"sha{id}", head_commit_time=finished - timedelta(hours=commit_hours_before),
    )


def no_compare(_base, _head):
    return []


class RunParsingTest(unittest.TestCase):
    def test_skips_runs_in_progress(self):
        self.assertIsNone(pe.run_from_api({"status": "in_progress"}))

    def test_parses_completed_run(self):
        r = pe.run_from_api({
            "id": 7, "status": "completed", "conclusion": "failure", "path": ".github/workflows/opentofu.yml@refs/heads/main",
            "event": "push", "head_branch": "main", "head_sha": "abc",
            "created_at": "2026-10-28T10:00:00Z", "run_started_at": "2026-10-28T10:01:00Z", "updated_at": "2026-10-28T10:11:00Z",
            "head_commit": {"timestamp": "2026-10-28T09:00:00Z"},
        })
        self.assertEqual(r.workflow, "opentofu.yml")
        self.assertEqual(r.duration, 600)
        self.assertEqual(r.queued, 60)


class PipelineSliTest(unittest.TestCase):
    def slis(self, runs, threshold=900):
        return {(s["workflow"], s["window"]): s for s in pe.compute_pipeline_slis(runs, NOW, "main", threshold)}

    def test_success_ratio_counts_only_default_branch_and_ignores_cancelled(self):
        runs = [
            run(1, hours_ago=1), run(2, hours_ago=2), run(3, hours_ago=3, conclusion="failure"),
            run(4, hours_ago=4, conclusion="cancelled"),
            run(5, hours_ago=5, conclusion="failure", branch="feature", event="pull_request"),
        ]
        s = self.slis(runs)[("opentofu.yml", "1d")]
        self.assertAlmostEqual(s["success_ratio"], 2 / 3)
        self.assertEqual(s["counts"]["other"]["failure"], 1)
        self.assertEqual(s["counts"]["main"]["cancelled"], 1)

    def test_windows_filter_by_completion_time(self):
        s = self.slis([run(1, hours_ago=1), run(2, hours_ago=48, conclusion="failure")])
        self.assertEqual(s[("opentofu.yml", "1d")]["success_ratio"], 1.0)
        self.assertEqual(s[("opentofu.yml", "7d")]["success_ratio"], 0.5)

    def test_duration_sli_uses_threshold(self):
        s = self.slis([run(1, hours_ago=1, minutes=5), run(2, hours_ago=2, minutes=20)], threshold=600)
        self.assertEqual(s[("opentofu.yml", "1d")]["duration_within_slo_ratio"], 0.5)

    def test_no_default_branch_runs_means_no_sli(self):
        s = self.slis([run(1, hours_ago=1, branch="feature")])
        self.assertIsNone(s[("opentofu.yml", "1d")]["success_ratio"])


class DoraTest(unittest.TestCase):
    def test_frequency_and_change_failure_rate(self):
        runs = [run(1, hours_ago=30), run(2, hours_ago=20, conclusion="failure"), run(3, hours_ago=10)]
        d = pe.compute_dora(runs, NOW, "opentofu.yml", "main", no_compare)["windows"]["7d"]
        self.assertEqual(d["deployments"], 2)
        self.assertEqual(d["failed_deployments"], 1)
        self.assertAlmostEqual(d["change_failure_rate"], 1 / 3)
        self.assertAlmostEqual(d["deployment_frequency_per_day"], 2 / 7)

    def test_pull_requests_and_other_workflows_are_not_deployments(self):
        runs = [run(1, hours_ago=1, event="pull_request"), run(2, hours_ago=1, workflow="lint.yml"), run(3, hours_ago=1, branch="dev")]
        d = pe.compute_dora(runs, NOW, "opentofu.yml", "main", no_compare)
        self.assertEqual(d["windows"]["28d"]["deployments"], 0)
        self.assertIsNone(d["windows"]["28d"]["change_failure_rate"])
        self.assertIsNone(d["last_deployment_timestamp"])

    def test_time_to_restore_spans_first_failure_to_next_success(self):
        runs = [run(1, hours_ago=10), run(2, hours_ago=8, conclusion="failure"),
                run(3, hours_ago=7, conclusion="timed_out"), run(4, hours_ago=5)]
        d = pe.compute_dora(runs, NOW, "opentofu.yml", "main", no_compare)
        w = d["windows"]["1d"]
        self.assertEqual(w["incidents"], 1)
        self.assertEqual(w["time_to_restore_quantiles"][0.5], 3 * 3600)
        self.assertEqual(d["open_incident_seconds"], 0.0)

    def test_open_incident_is_reported(self):
        runs = [run(1, hours_ago=10), run(2, hours_ago=2, conclusion="failure")]
        d = pe.compute_dora(runs, NOW, "opentofu.yml", "main", no_compare)
        self.assertEqual(d["open_incident_seconds"], 2 * 3600)

    def test_lead_time_uses_every_commit_between_deployments(self):
        calls = []

        def compare(base, head):
            calls.append((base, head))
            return [NOW - timedelta(hours=10), NOW - timedelta(hours=4)]

        runs = [run(1, hours_ago=20, sha="a"), run(2, hours_ago=2, sha="b")]
        d = pe.compute_dora(runs, NOW, "opentofu.yml", "main", compare)
        self.assertEqual(calls, [("a", "b")])
        # First deploy falls back to its head commit (1h); second ships commits 8h and 2h old.
        self.assertEqual(d["windows"]["1d"]["lead_time_quantiles"][0.5], 2 * 3600)

    def test_failed_deploy_does_not_advance_lead_time_base(self):
        calls = []
        runs = [run(1, hours_ago=20, sha="a"), run(2, hours_ago=10, conclusion="failure", sha="b"), run(3, hours_ago=2, sha="c")]
        pe.compute_dora(runs, NOW, "opentofu.yml", "main", lambda b, h: calls.append((b, h)) or [])
        self.assertEqual(calls, [("a", "c")])


class RenderingTest(unittest.TestCase):
    def snapshot(self):
        runs = [run(1, hours_ago=3), run(2, hours_ago=2, conclusion="failure"), run(3, hours_ago=1)]
        return {
            "generated_at": NOW.isoformat(), "repository": "o/r", "runs_observed": len(runs), "duration_slo_seconds": 900,
            "pipeline": pe.compute_pipeline_slis(runs, NOW, "main", 900),
            "dora": pe.compute_dora(runs, NOW, "opentofu.yml", "main", no_compare),
        }

    def test_prometheus_exposition_is_well_formed(self):
        text = pe.render_prometheus(self.snapshot(), {"up": 1, "last_success": 1.0, "errors": 0, "rate_limit_remaining": 50})
        self.assertIn('meridian_pipeline_success_ratio{repository="o/r",workflow="opentofu.yml",window="1d"} 0.666667', text)
        self.assertIn('meridian_dora_deployments{repository="o/r",window="28d"} 2', text)
        for line in text.splitlines():
            if not line.startswith("#"):
                name_and_labels, value = line.rsplit(" ", 1)
                float(value)
                self.assertTrue(name_and_labels.startswith("meridian_"), line)

    def test_empty_exporter_still_renders(self):
        text = pe.render_prometheus(None, {"up": 0, "last_success": None, "errors": 3, "rate_limit_remaining": None})
        self.assertIn("meridian_pipeline_exporter_up 0", text)
        self.assertIn("meridian_pipeline_exporter_refresh_errors_total 3", text)

    def test_snapshot_serializes_to_json(self):
        json.dumps(self.snapshot(), default=pe._json_default)

    def test_markdown_flags_violations(self):
        snapshot = self.snapshot()
        md = pe.render_markdown(snapshot, 0.95, 0.9)
        self.assertIn("**violated**", md)
        self.assertEqual(len(pe.slo_violations(snapshot, 0.95, 0.9)), 1)

    def test_dora_bands(self):
        self.assertEqual(pe.classify("deployment_frequency_per_day", 2), "elite")
        self.assertEqual(pe.classify("lead_time_seconds", 3 * 86400), "high")
        self.assertEqual(pe.classify("change_failure_rate", 0.12), "medium")
        self.assertEqual(pe.classify("time_to_restore_seconds", 30 * 86400), "low")
        self.assertEqual(pe.classify("change_failure_rate", None), "n/a")


if __name__ == "__main__":
    unittest.main()
