#!/usr/bin/env python3
"""Verifies pinned Helm charts against platform/charts.lock.json.

Downloads each chart archive, compares its SHA-256 with the lockfile, and
optionally adds the charts as components to a CycloneDX SBOM, which Syft
cannot do because the charts are fetched by the Helm provider at apply time.

  python3 scripts/verify_charts.py                          # verify only
  python3 scripts/verify_charts.py --sbom sbom.cdx.json     # verify, then add to SBOM
"""

import argparse
import hashlib
import json
import pathlib
import sys
import urllib.request

LOCKFILE = pathlib.Path(__file__).resolve().parents[1] / "platform" / "charts.lock.json"


def sha256_of(url):
    digest = hashlib.sha256()
    with urllib.request.urlopen(url, timeout=60) as response:
        for chunk in iter(lambda: response.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def component(chart):
    return {
        "type": "application",
        "bom-ref": f"helm-chart:{chart['name']}@{chart['version']}",
        "name": chart["name"],
        "version": chart["version"],
        "purl": f"pkg:helm/{chart['name']}@{chart['version']}?repository_url={chart['repository']}",
        "hashes": [{"alg": "SHA-256", "content": chart["sha256"]}],
        "externalReferences": [{"type": "distribution", "url": chart["url"]}],
        "properties": [{"name": "meridian:component-kind", "value": "helm-chart"}],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sbom", type=pathlib.Path, help="CycloneDX JSON SBOM to add the verified charts to")
    args = parser.parse_args()

    charts = json.loads(LOCKFILE.read_text())["charts"]
    failed = False
    for chart in charts:
        actual = sha256_of(chart["url"])
        if actual == chart["sha256"]:
            print(f"ok       {chart['name']} {chart['version']}")
        else:
            failed = True
            print(f"MISMATCH {chart['name']} {chart['version']}: expected {chart['sha256']}, got {actual}", file=sys.stderr)
    if failed:
        return 1

    if args.sbom:
        sbom = json.loads(args.sbom.read_text())
        existing = {c.get("bom-ref") for c in sbom.get("components", [])}
        sbom.setdefault("components", []).extend(c for c in map(component, charts) if c["bom-ref"] not in existing)
        args.sbom.write_text(json.dumps(sbom, indent=2) + "\n")
        print(f"added {len(charts)} charts to {args.sbom}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
