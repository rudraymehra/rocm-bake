#!/usr/bin/env python3
"""Report what is inside each published wheel image, without pulling it.

A "wheelhouse" here is a directory of .whl files that pip consumes with
--no-index --find-links. We ship those directories as scratch images in
Zot, so this reads each image's manifest straight from the registry and
reports the layer sizes and tags rather than downloading hundreds of MB.
"""
import json
import sys
import urllib.request

ACCEPT = (
    "application/vnd.oci.image.index.v1+json,"
    "application/vnd.docker.distribution.manifest.list.v2+json,"
    "application/vnd.oci.image.manifest.v1+json,"
    "application/vnd.docker.distribution.manifest.v2+json"
)


def fetch(url):
    # Relies on no_proxy covering the tailnet; the Makefile exports it.
    req = urllib.request.Request(url, headers={"Accept": ACCEPT})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def main():
    registry, namespace, *repos = sys.argv[1:]
    for repo in repos:
        base = f"http://{registry}/v2/{namespace}/{repo}"
        try:
            tags = fetch(f"{base}/tags/list")["tags"]
        except Exception:
            print(f"  {repo:<14} (not published)")
            continue
        try:
            manifest = fetch(f"{base}/manifests/latest")
            # An index points at per-platform manifests; follow the first.
            if "manifests" in manifest:
                digest = manifest["manifests"][0]["digest"]
                manifest = fetch(f"{base}/manifests/{digest}")
            size = sum(layer.get("size", 0) for layer in manifest.get("layers", []))
            print(f"  {repo:<14} {size / 1048576:8.1f} MB  {len(tags)} tag(s)")
            for tag in sorted(tags):
                print(f"      {tag}")
        except Exception as exc:
            print(f"  {repo:<14} (manifest unreadable: {exc})")


if __name__ == "__main__":
    main()
