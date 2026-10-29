#!/usr/bin/env python3
"""Pipeline SLI and DORA metrics exporter for GitHub Actions.

Polls the GitHub Actions API for a repository's workflow runs and serves
Prometheus metrics on /metrics. Standard library only, so the image needs
nothing but a pinned Python base and the supply chain stays small.

SLIs, per workflow and window (1d, 7d, 28d):
  success ratio     successful / (successful + failed) runs on the default branch
  duration          share of successful runs that finish within DURATION_SLO_SECONDS
  queue time        time from run creation to start

DORA, from runs of DEPLOY_WORKFLOW pushed or dispatched on the default branch:
  deployment frequency   successful deploy runs per day
  lead time for changes  commit author time -> deploy finished, for every commit a deploy shipped
  change failure rate    failed deploy runs / all deploy runs
  time to restore        first failed deploy run -> next successful deploy run

Run `pipeline_exporter.py --once --format markdown` for a one-off report.
"""

import argparse
import json
import math
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WINDOWS = {"1d": 1, "7d": 7, "28d": 28}
QUANTILES = (0.5, 0.9, 0.99)
FAILED = {"failure", "timed_out", "startup_failure"}
DEPLOY_EVENTS = {"push", "workflow_dispatch"}
MAX_PAGES = 10


@dataclass(frozen=True)
class Run:
    id: int
    workflow: str
    event: str
    branch: str
    conclusion: str
    created: datetime
    started: datetime
    finished: datetime
    head_sha: str
    head_commit_time: datetime | None

    @property
    def duration(self) -> float:
        return max(0.0, (self.finished - self.started).total_seconds())

    @property
    def queued(self) -> float:
        return max(0.0, (self.started - self.created).total_seconds())


def parse_ts(value):
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def run_from_api(raw):
    """Converts a GitHub workflow run object; returns None for runs still in progress."""
    if raw.get("status") != "completed":
        return None
    created = parse_ts(raw["created_at"])
    head_commit = raw.get("head_commit") or {}
    return Run(
        id=raw["id"],
        workflow=os.path.basename((raw.get("path") or raw.get("name") or "unknown").split("@")[0]),
        event=raw.get("event", ""),
        branch=raw.get("head_branch") or "",
        conclusion=raw.get("conclusion") or "unknown",
        created=created,
        started=parse_ts(raw.get("run_started_at")) or created,
        finished=parse_ts(raw["updated_at"]),
        head_sha=raw.get("head_sha", ""),
        head_commit_time=parse_ts(head_commit.get("timestamp")),
    )


def quantile(values, q):
    """Linear-interpolated quantile; None for an empty list."""
    if not values:
        return None
    ordered = sorted(values)
    pos = (len(ordered) - 1) * q
    lo, hi = math.floor(pos), math.ceil(pos)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (pos - lo)


def ratio(numerator, denominator):
    return numerator / denominator if denominator else None


def result_class(conclusion):
    if conclusion == "success":
        return "success"
    if conclusion in FAILED:
        return "failure"
    if conclusion == "cancelled":
        return "cancelled"
    return "other"


def in_window(run, now, days):
    return run.finished >= now - timedelta(days=days)


def compute_pipeline_slis(runs, now, default_branch, duration_slo_seconds):
    slis = []
    for workflow in sorted({r.workflow for r in runs}):
        wf_runs = [r for r in runs if r.workflow == workflow]
        for window, days in WINDOWS.items():
            window_runs = [r for r in wf_runs if in_window(r, now, days)]
            counts = {}  # branch class -> result -> runs
            for r in window_runs:
                by_result = counts.setdefault("main" if r.branch == default_branch else "other", {})
                by_result[result_class(r.conclusion)] = by_result.get(result_class(r.conclusion), 0) + 1

            main = [r for r in window_runs if r.branch == default_branch]
            main_ok = sum(1 for r in main if r.conclusion == "success")
            main_failed = sum(1 for r in main if r.conclusion in FAILED)
            succeeded = [r for r in window_runs if r.conclusion == "success"]
            durations = [r.duration for r in succeeded]

            slis.append({
                "workflow": workflow,
                "window": window,
                "counts": counts,
                "success_ratio": ratio(main_ok, main_ok + main_failed),
                "duration_within_slo_ratio": ratio(sum(1 for d in durations if d <= duration_slo_seconds), len(durations)),
                "duration_quantiles": {q: quantile(durations, q) for q in QUANTILES},
                "queue_quantiles": {q: quantile([r.queued for r in window_runs], q) for q in QUANTILES},
            })
    return slis


def is_deploy(run, deploy_workflow, default_branch):
    return run.workflow == deploy_workflow and run.branch == default_branch and run.event in DEPLOY_EVENTS


def compute_dora(runs, now, deploy_workflow, default_branch, commit_times):
    """commit_times(base_sha, head_sha) returns author datetimes of the commits a deploy shipped."""
    attempts = sorted(
        (r for r in runs if is_deploy(r, deploy_workflow, default_branch) and result_class(r.conclusion) in ("success", "failure")),
        key=lambda r: r.finished,
    )

    lead_times = []  # (deploy finished, seconds) for every shipped commit
    previous_success = None
    for r in attempts:
        if r.conclusion != "success":
            continue
        times = commit_times(previous_success.head_sha, r.head_sha) if previous_success else None
        if not times and r.head_commit_time:
            times = [r.head_commit_time]
        lead_times.extend((r.finished, (r.finished - t).total_seconds()) for t in times or [])
        previous_success = r

    # An incident opens at the first failed deploy after a success (or at the start) and closes at the next success.
    incidents = []  # (opened, closed or None)
    opened = None
    for r in attempts:
        if r.conclusion == "success":
            if opened:
                incidents.append((opened, r.finished))
                opened = None
        elif opened is None:
            opened = r.finished
    if opened:
        incidents.append((opened, None))

    dora = {"windows": {}}
    for window, days in WINDOWS.items():
        window_attempts = [r for r in attempts if in_window(r, now, days)]
        deploys = sum(1 for r in window_attempts if r.conclusion == "success")
        failed = len(window_attempts) - deploys
        since = now - timedelta(days=days)
        restores = [(closed - start).total_seconds() for start, closed in incidents if closed and start >= since]
        leads = [secs for finished, secs in lead_times if finished >= since]
        dora["windows"][window] = {
            "deployments": deploys,
            "failed_deployments": failed,
            "deployment_frequency_per_day": deploys / days,
            "change_failure_rate": ratio(failed, deploys + failed),
            "lead_time_quantiles": {q: quantile(leads, q) for q in QUANTILES},
            "time_to_restore_quantiles": {q: quantile(restores, q) for q in QUANTILES},
            "incidents": sum(1 for start, _ in incidents if start >= since),
        }

    successes = [r for r in attempts if r.conclusion == "success"]
    dora["last_deployment_timestamp"] = successes[-1].finished.timestamp() if successes else None
    dora["open_incident_seconds"] = next(((now - start).total_seconds() for start, closed in incidents if closed is None), 0.0)
    return dora


def classify(metric, value):
    """DORA performance band, using the State of DevOps thresholds."""
    if value is None:
        return "n/a"
    bands = {
        # (elite, high, medium) upper/lower bounds
        "deployment_frequency_per_day": lambda v: "elite" if v >= 1 else "high" if v >= 1 / 7 else "medium" if v >= 1 / 30 else "low",
        "lead_time_seconds": lambda v: "elite" if v < 86400 else "high" if v < 7 * 86400 else "medium" if v < 30 * 86400 else "low",
        "change_failure_rate": lambda v: "elite" if v <= 0.05 else "high" if v <= 0.10 else "medium" if v <= 0.15 else "low",
        "time_to_restore_seconds": lambda v: "elite" if v < 3600 else "high" if v < 86400 else "medium" if v < 7 * 86400 else "low",
    }
    return bands[metric](value)


class GitHubClient:
    def __init__(self, repository, token=None, api_url="https://api.github.com", timeout=20):
        self.repository = repository
        self.token = token
        self.api_url = api_url.rstrip("/")
        self.timeout = timeout
        self.rate_limit_remaining = None
        self._compare_cache = {}

    def _get(self, path, params=None):
        url = f"{self.api_url}/repos/{self.repository}/{path}"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        request = urllib.request.Request(url, headers={
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "meridian-pipeline-exporter",
        })
        if self.token:
            request.add_header("Authorization", f"Bearer {self.token}")
        with urllib.request.urlopen(request, timeout=self.timeout) as response:
            remaining = response.headers.get("X-RateLimit-Remaining")
            if remaining is not None:
                self.rate_limit_remaining = int(remaining)
            return json.load(response)

    def workflow_runs(self, since):
        runs = []
        for page in range(1, MAX_PAGES + 1):
            body = self._get("actions/runs", {
                "per_page": 100,
                "page": page,
                "created": f">={since:%Y-%m-%d}",
                "exclude_pull_requests": "true",
            })
            batch = body.get("workflow_runs", [])
            runs.extend(r for r in map(run_from_api, batch) if r)
            if len(batch) < 100:
                break
        return runs

    def commit_times(self, base, head):
        """Author times of commits in base..head; cached because both SHAs are immutable."""
        key = (base, head)
        if key not in self._compare_cache:
            try:
                body = self._get(f"compare/{base}...{head}")
                self._compare_cache[key] = [parse_ts(c["commit"]["author"]["date"]) for c in body.get("commits", [])]
            except (urllib.error.URLError, KeyError, ValueError):
                return []
        return self._compare_cache[key]


def collect(client, config, now=None):
    now = now or datetime.now(timezone.utc)
    runs = client.workflow_runs(now - timedelta(days=max(WINDOWS.values())))
    return {
        "generated_at": now.isoformat(),
        "repository": config.repository,
        "runs_observed": len(runs),
        "duration_slo_seconds": config.duration_slo_seconds,
        "pipeline": compute_pipeline_slis(runs, now, config.default_branch, config.duration_slo_seconds),
        "dora": compute_dora(runs, now, config.deploy_workflow, config.default_branch, client.commit_times),
    }


def _labels(**labels):
    return "{" + ",".join(f'{k}="{v}"' for k, v in labels.items()) + "}"


def render_prometheus(snapshot, exporter_state):
    out = []

    def metric(name, help_text, kind, samples):
        out.append(f"# HELP {name} {help_text}")
        out.append(f"# TYPE {name} {kind}")
        for labels, value in samples:
            if value is not None:
                out.append(f"{name}{_labels(**labels) if labels else ''} {value:.6g}")

    pipeline = snapshot.get("pipeline", []) if snapshot else []
    dora = snapshot.get("dora", {"windows": {}}) if snapshot else {"windows": {}}
    repo = snapshot.get("repository", "") if snapshot else ""

    metric("meridian_pipeline_runs", "Completed workflow runs in the window.", "gauge", [
        ({"repository": repo, "workflow": s["workflow"], "window": s["window"], "branch": branch, "result": result}, n)
        for s in pipeline for branch, by_result in sorted(s["counts"].items()) for result, n in sorted(by_result.items())
    ])
    metric("meridian_pipeline_success_ratio", "SLI: successful / (successful + failed) default-branch runs.", "gauge", [
        ({"repository": repo, "workflow": s["workflow"], "window": s["window"]}, s["success_ratio"]) for s in pipeline
    ])
    metric("meridian_pipeline_duration_within_slo_ratio", "SLI: share of successful runs finishing within the duration threshold.", "gauge", [
        ({"repository": repo, "workflow": s["workflow"], "window": s["window"]}, s["duration_within_slo_ratio"]) for s in pipeline
    ])
    metric("meridian_pipeline_duration_seconds", "Duration of successful runs.", "gauge", [
        ({"repository": repo, "workflow": s["workflow"], "window": s["window"], "quantile": str(q)}, v)
        for s in pipeline for q, v in s["duration_quantiles"].items()
    ])
    metric("meridian_pipeline_queue_seconds", "Time from run creation to start.", "gauge", [
        ({"repository": repo, "workflow": s["workflow"], "window": s["window"], "quantile": str(q)}, v)
        for s in pipeline for q, v in s["queue_quantiles"].items()
    ])
    metric("meridian_pipeline_duration_slo_threshold_seconds", "Duration a successful run must stay within to count as good.", "gauge", [
        ({"repository": repo}, snapshot.get("duration_slo_seconds") if snapshot else None)
    ])

    windows = dora["windows"].items()
    metric("meridian_dora_deployments", "Successful deployments in the window.", "gauge", [
        ({"repository": repo, "window": w}, d["deployments"]) for w, d in windows
    ])
    metric("meridian_dora_failed_deployments", "Failed deployments in the window.", "gauge", [
        ({"repository": repo, "window": w}, d["failed_deployments"]) for w, d in windows
    ])
    metric("meridian_dora_deployment_frequency_per_day", "DORA deployment frequency.", "gauge", [
        ({"repository": repo, "window": w}, d["deployment_frequency_per_day"]) for w, d in windows
    ])
    metric("meridian_dora_change_failure_rate", "DORA change failure rate.", "gauge", [
        ({"repository": repo, "window": w}, d["change_failure_rate"]) for w, d in windows
    ])
    metric("meridian_dora_lead_time_seconds", "DORA lead time for changes, commit to deployed.", "gauge", [
        ({"repository": repo, "window": w, "quantile": str(q)}, v) for w, d in windows for q, v in d["lead_time_quantiles"].items()
    ])
    metric("meridian_dora_time_to_restore_seconds", "DORA time to restore a failed deployment.", "gauge", [
        ({"repository": repo, "window": w, "quantile": str(q)}, v) for w, d in windows for q, v in d["time_to_restore_quantiles"].items()
    ])
    metric("meridian_dora_last_deployment_timestamp_seconds", "Unix time of the last successful deployment.", "gauge", [
        ({"repository": repo}, dora.get("last_deployment_timestamp"))
    ])
    metric("meridian_dora_open_incident_seconds", "Age of the current failed-deployment incident, 0 when healthy.", "gauge", [
        ({"repository": repo}, dora.get("open_incident_seconds"))
    ])

    metric("meridian_pipeline_exporter_up", "1 if the last GitHub refresh succeeded.", "gauge", [({}, exporter_state["up"])])
    metric("meridian_pipeline_exporter_last_refresh_timestamp_seconds", "Unix time of the last successful refresh.", "gauge",
           [({}, exporter_state["last_success"])])
    metric("meridian_pipeline_exporter_refresh_errors_total", "Failed GitHub refreshes.", "counter", [({}, exporter_state["errors"])])
    metric("meridian_pipeline_exporter_github_rate_limit_remaining", "GitHub API requests left in the current window.", "gauge",
           [({}, exporter_state["rate_limit_remaining"])])
    metric("meridian_pipeline_exporter_runs_observed", "Workflow runs fetched in the last refresh.", "gauge",
           [({}, snapshot.get("runs_observed") if snapshot else None)])
    return "\n".join(out) + "\n"


def _fmt_duration(seconds):
    if seconds is None:
        return "n/a"
    if seconds < 3600:
        return f"{seconds / 60:.1f} min"
    if seconds < 86400:
        return f"{seconds / 3600:.1f} h"
    return f"{seconds / 86400:.1f} d"


def _fmt_pct(value):
    return "n/a" if value is None else f"{value:.1%}"


def render_markdown(snapshot, success_objective, duration_objective, window="28d"):
    lines = [f"## Pipeline SLOs ({window}) for `{snapshot['repository']}`", ""]
    lines.append(f"Objectives: success ratio >= {success_objective:.0%} on the default branch; "
                 f">= {duration_objective:.0%} of successful runs within {_fmt_duration(snapshot['duration_slo_seconds'])}.")
    lines += ["", "| Workflow | Success ratio | Within duration | p50 | p90 | Status |", "|---|---|---|---|---|---|"]
    for s in (s for s in snapshot["pipeline"] if s["window"] == window):
        ok = (s["success_ratio"] is None or s["success_ratio"] >= success_objective) and \
             (s["duration_within_slo_ratio"] is None or s["duration_within_slo_ratio"] >= duration_objective)
        lines.append(f"| `{s['workflow']}` | {_fmt_pct(s['success_ratio'])} | {_fmt_pct(s['duration_within_slo_ratio'])} | "
                     f"{_fmt_duration(s['duration_quantiles'][0.5])} | {_fmt_duration(s['duration_quantiles'][0.9])} | "
                     f"{'met' if ok else '**violated**'} |")

    d = snapshot["dora"]["windows"][window]
    lead = d["lead_time_quantiles"][0.5]
    restore = d["time_to_restore_quantiles"][0.5]
    lines += ["", f"## DORA metrics ({window})", "", "| Metric | Value | Band |", "|---|---|---|",
              f"| Deployment frequency | {d['deployment_frequency_per_day']:.2f}/day ({d['deployments']} deploys) | "
              f"{classify('deployment_frequency_per_day', d['deployment_frequency_per_day'])} |",
              f"| Lead time for changes (median) | {_fmt_duration(lead)} | {classify('lead_time_seconds', lead)} |",
              f"| Change failure rate | {_fmt_pct(d['change_failure_rate'])} ({d['failed_deployments']} failed) | "
              f"{classify('change_failure_rate', d['change_failure_rate'])} |",
              f"| Time to restore (median) | {_fmt_duration(restore)} | {classify('time_to_restore_seconds', restore)} |"]
    return "\n".join(lines) + "\n"


def slo_violations(snapshot, success_objective, duration_objective, window="28d"):
    violations = []
    for s in (s for s in snapshot["pipeline"] if s["window"] == window):
        if s["success_ratio"] is not None and s["success_ratio"] < success_objective:
            violations.append(f"{s['workflow']}: success ratio {s['success_ratio']:.1%} < {success_objective:.0%}")
        if s["duration_within_slo_ratio"] is not None and s["duration_within_slo_ratio"] < duration_objective:
            violations.append(f"{s['workflow']}: {s['duration_within_slo_ratio']:.1%} of runs within duration < {duration_objective:.0%}")
    return violations


def _json_default(value):
    return value.isoformat() if isinstance(value, datetime) else str(value)


@dataclass
class Config:
    repository: str
    token: str | None
    api_url: str
    default_branch: str
    deploy_workflow: str
    duration_slo_seconds: float
    success_objective: float
    duration_objective: float
    poll_interval: int
    port: int

    @classmethod
    def from_env(cls):
        env = os.environ
        repository = env.get("GITHUB_REPOSITORY")
        if not repository:
            sys.exit("GITHUB_REPOSITORY (owner/name) is required")
        return cls(
            repository=repository,
            token=env.get("GITHUB_TOKEN") or None,
            api_url=env.get("GITHUB_API_URL", "https://api.github.com"),
            default_branch=env.get("DEFAULT_BRANCH", "main"),
            deploy_workflow=env.get("DEPLOY_WORKFLOW", "opentofu.yml"),
            duration_slo_seconds=float(env.get("DURATION_SLO_SECONDS", "900")),
            success_objective=float(env.get("SUCCESS_OBJECTIVE", "0.95")),
            duration_objective=float(env.get("DURATION_OBJECTIVE", "0.90")),
            poll_interval=int(env.get("POLL_INTERVAL_SECONDS", "300")),
            port=int(env.get("PORT", "9102")),
        )


class Exporter:
    def __init__(self, config):
        self.config = config
        self.client = GitHubClient(config.repository, config.token, config.api_url)
        self.lock = threading.Lock()
        self.snapshot = None
        self.state = {"up": 0, "last_success": None, "errors": 0, "rate_limit_remaining": None}

    def refresh(self):
        try:
            snapshot = collect(self.client, self.config)
        except Exception as exc:  # keep serving the last good snapshot
            print(f"refresh failed: {exc}", file=sys.stderr, flush=True)
            with self.lock:
                self.state["up"] = 0
                self.state["errors"] += 1
                self.state["rate_limit_remaining"] = self.client.rate_limit_remaining
            return
        with self.lock:
            self.snapshot = snapshot
            self.state.update(up=1, last_success=time.time(), rate_limit_remaining=self.client.rate_limit_remaining)
        print(f"refreshed: {snapshot['runs_observed']} runs", flush=True)

    def loop(self):
        while True:
            self.refresh()
            time.sleep(self.config.poll_interval)

    def metrics(self):
        with self.lock:
            return render_prometheus(self.snapshot, dict(self.state))

    def ready(self):
        with self.lock:
            return self.snapshot is not None


def serve(exporter):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/metrics":
                self._reply(200, exporter.metrics(), "text/plain; version=0.0.4")
            elif self.path == "/healthz":
                self._reply(200, "ok\n")
            elif self.path == "/readyz":
                self._reply(200 if exporter.ready() else 503, "ready\n" if exporter.ready() else "waiting for first refresh\n")
            else:
                self._reply(404, "not found\n")

        def _reply(self, code, body, content_type="text/plain"):
            data = body.encode()
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            pass

    threading.Thread(target=exporter.loop, daemon=True).start()
    server = ThreadingHTTPServer(("", exporter.config.port), Handler)
    print(f"serving on :{exporter.config.port} for {exporter.config.repository}", flush=True)
    server.serve_forever()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--once", action="store_true", help="collect once, print a report and exit")
    parser.add_argument("--format", choices=["markdown", "json", "prometheus"], default="markdown")
    parser.add_argument("--fail-on-violation", action="store_true", help="with --once, exit 2 when a 28d SLO is violated")
    args = parser.parse_args(argv)

    config = Config.from_env()
    exporter = Exporter(config)
    if not args.once:
        serve(exporter)
        return 0

    snapshot = collect(exporter.client, config)
    if args.format == "json":
        print(json.dumps(snapshot, default=_json_default, indent=2))
    elif args.format == "prometheus":
        print(render_prometheus(snapshot, {"up": 1, "last_success": time.time(), "errors": 0,
                                           "rate_limit_remaining": exporter.client.rate_limit_remaining}), end="")
    else:
        print(render_markdown(snapshot, config.success_objective, config.duration_objective), end="")

    violations = slo_violations(snapshot, config.success_objective, config.duration_objective)
    for v in violations:
        print(f"SLO violated: {v}", file=sys.stderr)
    return 2 if violations and args.fail_on_violation else 0


if __name__ == "__main__":
    sys.exit(main())
