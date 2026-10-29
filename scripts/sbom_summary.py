#!/usr/bin/env python3
"""Prints a Markdown summary of a CycloneDX SBOM: component counts by package type, plus the OpenTofu providers and Helm charts."""

import collections
import json
import sys


def prop(component, name):
    return next((p["value"] for p in component.get("properties", []) if p["name"] == name), None)


def main(path):
    components = json.load(open(path, encoding="utf-8")).get("components", [])
    kinds = collections.Counter(prop(c, "syft:package:type") or prop(c, "meridian:component-kind") or c["type"] for c in components)

    print(f"## SBOM ({len(components)} components)\n")
    print("| Package type | Components |\n|---|---|")
    for kind, count in kinds.most_common():
        print(f"| {kind} | {count} |")

    pinned = [c for c in components if prop(c, "syft:package:type") == "terraform" or prop(c, "meridian:component-kind") == "helm-chart"]
    if pinned:
        print("\n| Pinned dependency | Version |\n|---|---|")
        for c in sorted(pinned, key=lambda c: c["name"]):
            print(f"| `{c['name']}` | {c.get('version', '?')} |")


if __name__ == "__main__":
    main(sys.argv[1])
