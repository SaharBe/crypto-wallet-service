#!/usr/bin/env python3
"""Render every ArgoCD Application's Helm chart with its committed values.

Catches the class of break this repo has hit before — see
k8s/apps/kyverno-app.yaml's own header comment about a chart version
pinning a since-removed Bitnami image tag — before ArgoCD tries the same
chart+values combination against the live cluster. Skips git-sourced
Applications (nothing to template) and ApplicationSets (their source is a
Go template, not a literal chart+values pair).

Usage: validate_argocd_helm_apps.py <dir-of-Application-yaml-files>
"""
import glob
import os
import subprocess
import sys
import tempfile

import yaml


def find_helm_applications(root):
    apps = []
    for path in sorted(glob.glob(os.path.join(root, "*.yaml"))):
        with open(path) as f:
            docs = yaml.safe_load_all(f)
            for doc in docs:
                if not doc or doc.get("kind") != "Application":
                    continue
                source = doc.get("spec", {}).get("source", {})
                chart = source.get("chart")
                if not chart:
                    continue
                apps.append(
                    {
                        "name": doc["metadata"]["name"],
                        "file": path,
                        "repo_url": source["repoURL"],
                        "chart": chart,
                        "version": source["targetRevision"],
                        "values": source.get("helm", {}).get("values", "") or "",
                    }
                )
    return apps


def helm_template_cmd(app, values_path):
    # ArgoCD (and this script) address an OCI-hosted chart the same way as
    # a classic index.yaml repo: repoURL is the bare registry host, no
    # `oci://` prefix (see k8s/apps/kafka-app.yaml). Plain `helm template`
    # needs that prefix spelled out explicitly and takes no --repo flag
    # for OCI refs.
    if app["repo_url"].startswith(("http://", "https://")):
        return [
            "helm", "template", app["name"], app["chart"],
            "--repo", app["repo_url"],
            "--version", app["version"],
            "-f", values_path,
        ]
    chart_ref = f"oci://{app['repo_url'].rstrip('/')}/{app['chart']}"
    return [
        "helm", "template", app["name"], chart_ref,
        "--version", app["version"],
        "-f", values_path,
    ]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "k8s/apps"
    apps = find_helm_applications(root)
    if not apps:
        print("No Helm-sourced Applications found — nothing to validate.")
        return 0

    failures = []
    for app in apps:
        print(f"::group::helm template {app['name']} ({app['chart']} @ {app['version']}, from {app['file']})")
        fd, values_path = tempfile.mkstemp(suffix=".yaml")
        try:
            with os.fdopen(fd, "w") as vf:
                vf.write(app["values"])
            result = subprocess.run(
                helm_template_cmd(app, values_path), capture_output=True, text=True
            )
            print(result.stdout)
            if result.returncode != 0:
                print(result.stderr, file=sys.stderr)
                failures.append(app["name"])
        finally:
            os.unlink(values_path)
        print("::endgroup::")

    if failures:
        print(f"helm template failed for: {', '.join(failures)}", file=sys.stderr)
        return 1
    print(f"helm template succeeded for {len(apps)} chart-sourced Application(s): "
          f"{', '.join(a['name'] for a in apps)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
