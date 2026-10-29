#!/usr/bin/env python3
"""End-to-end checks for the observability platform on the kind cluster.

Checks that Argo CD synced the pipeline-observability app, Prometheus scrapes the
exporter and Argo CD and loaded the SLO rules, and Grafana serves both dashboards.
Needs kubectl on PATH, pointed at the cluster. Override URLs with GRAFANA_URL,
PROMETHEUS_URL and KUBE_CONTEXT.
"""

import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

GRAFANA = os.environ.get("GRAFANA_URL", "http://localhost:3000")
PROMETHEUS = os.environ.get("PROMETHEUS_URL", "http://localhost:9090")
CONTEXT = os.environ.get("KUBE_CONTEXT", "kind-meridian")
DASHBOARDS = ["meridian-pipeline-slo", "meridian-dora"]
RULE_GROUPS = ["meridian-pipeline-slo.rules", "meridian-pipeline-slo.alerts"]


def kubectl(*args):
    return subprocess.run(["kubectl", "--context", CONTEXT, *args], check=True, capture_output=True, text=True).stdout


def http_json(url, auth=None):
    request = urllib.request.Request(url)
    if auth:
        request.add_header("Authorization", "Basic " + base64.b64encode(f"{auth[0]}:{auth[1]}".encode()).decode())
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.load(response)


def prom_query(expr):
    return http_json(f"{PROMETHEUS}/api/v1/query?" + urllib.parse.urlencode({"query": expr}))["data"]["result"]


def wait_for(description, check, timeout, interval=10):
    """Polls check() until it returns a truthy value; returns (ok, last detail)."""
    deadline = time.monotonic() + timeout
    detail = None
    while True:
        try:
            result = check()
            if result:
                print(f"  ok    {description}")
                return True, result
            detail = "condition not met yet"
        except (urllib.error.URLError, subprocess.CalledProcessError, KeyError, ValueError, OSError) as exc:
            detail = getattr(exc, "stderr", None) or str(exc)
        if time.monotonic() >= deadline:
            print(f"  FAIL  {description}: {detail}")
            return False, detail
        time.sleep(interval)


def app_synced():
    app = json.loads(kubectl("-n", "argocd", "get", "application", "pipeline-observability", "-o", "json"))
    sync, health = app["status"]["sync"]["status"], app["status"]["health"]["status"]
    if sync == "Synced" and health == "Healthy":
        return f"{sync}/{health} at {app['status']['sync'].get('revision', '?')[:12]}"
    raise ValueError(f"sync={sync} health={health}")


def target_up(job_fragment):
    def check():
        targets = http_json(f"{PROMETHEUS}/api/v1/targets?state=active")["data"]["activeTargets"]
        matching = [t for t in targets if job_fragment in t["labels"].get("job", "")]
        if not matching:
            raise ValueError(f"no active target with job containing {job_fragment!r}")
        return all(t["health"] == "up" for t in matching)
    return check


def rules_loaded():
    groups = {g["name"] for g in http_json(f"{PROMETHEUS}/api/v1/rules")["data"]["groups"]}
    missing = [g for g in RULE_GROUPS if g not in groups]
    if missing:
        raise ValueError(f"missing rule groups {missing}")
    return True


def grafana_password():
    encoded = kubectl("-n", "monitoring", "get", "secret", "grafana-admin", "-o", "jsonpath={.data.admin-password}")
    return base64.b64decode(encoded).decode()


def dashboards_loaded(auth):
    def check():
        for uid in DASHBOARDS:
            http_json(f"{GRAFANA}/api/dashboards/uid/{uid}", auth)
        return True
    return check


def main():
    results = []
    print("Workloads")
    for ns in ("monitoring", "argocd"):
        results.append(wait_for(f"deployments in {ns} available", lambda ns=ns: kubectl(
            "-n", ns, "wait", "--for=condition=Available", "deployment", "--all", "--timeout=30s") or True, timeout=600)[0])

    print("GitOps")
    has_app = subprocess.run(["kubectl", "--context", CONTEXT, "-n", "argocd", "get", "application", "pipeline-observability"],
                             capture_output=True).returncode == 0
    if has_app:
        results.append(wait_for("Argo CD synced pipeline-observability", app_synced, timeout=600)[0])
    else:
        print("  skip  no Argo CD Application (pipeline_observability_source = helm)")
        results.append(wait_for("pipeline-exporter deployment available", lambda: kubectl(
            "-n", "monitoring", "wait", "--for=condition=Available", "deployment/pipeline-exporter", "--timeout=30s"), timeout=300)[0])

    print("Prometheus")
    results.append(wait_for("pipeline-exporter target is up", target_up("pipeline-exporter"), timeout=300)[0])
    results.append(wait_for("Argo CD metrics targets are up", target_up("argocd"), timeout=300)[0])
    results.append(wait_for("SLO recording and alerting rules loaded", rules_loaded, timeout=180)[0])
    ok, series = wait_for("exporter reports meridian_pipeline_exporter_up",
                          lambda: prom_query("meridian_pipeline_exporter_up"), timeout=300)
    results.append(ok)
    if ok and series[0]["value"][1] != "1":
        print("  warn  exporter is up but its last GitHub refresh failed (rate limit or network); see its logs")

    print("Grafana")
    results.append(wait_for("Grafana is healthy", lambda: http_json(f"{GRAFANA}/api/health")["database"] == "ok", timeout=120)[0])
    auth = ("admin", grafana_password())
    results.append(wait_for("Pipeline SLO and DORA dashboards provisioned", dashboards_loaded(auth), timeout=180)[0])

    passed = sum(results)
    print(f"\n{passed}/{len(results)} checks passed")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
