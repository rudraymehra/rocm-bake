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


def wheel_bytes(base, tag):
    """Compressed size of a wheel image's payload layers."""
    manifest = fetch(f"{base}/manifests/{tag}")
    # An index points at per-platform manifests; follow the first.
    if "manifests" in manifest:
        digest = manifest["manifests"][0]["digest"]
        manifest = fetch(f"{base}/manifests/{digest}")
    return sum(layer.get("size", 0) for layer in manifest.get("layers", []))


def main():
    args = sys.argv[1:]
    # --brief is the one-line-per-repo form behind `make zot-wheels`;
    # without it we expand every tag, which is `make zot-wheelhouse`.
    brief = "--brief" in args
    args = [a for a in args if a != "--brief"]
    registry, namespace, *repos = args

    for repo in repos:
        base = f"http://{registry}/v2/{namespace}/{repo}"
        try:
            tags = sorted(fetch(f"{base}/tags/list")["tags"])
        except Exception:
            print(f"  {repo:<14} (not published)")
            continue
        try:
            size = wheel_bytes(base, "latest")
        except Exception as exc:
            print(f"  {repo:<14} (manifest unreadable: {exc})")
            continue

        if brief:
            print(f"  {repo:<14} {size / 1048576:8.1f} MB  {' '.join(tags)}")
            continue

        print(f"  {repo:<14} {size / 1048576:8.1f} MB  {len(tags)} tag(s)")
        for tag in tags:
            # Tags usually alias one manifest, but a stale tag left behind
            # by an earlier build does not — so size each one.
            try:
                print(f"      {tag:<42} {wheel_bytes(base, tag) / 1048576:8.1f} MB")
            except Exception:
                print(f"      {tag:<42}        ? MB")


if __name__ == "__main__":
    main()
