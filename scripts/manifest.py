#!/usr/bin/env python3
"""Generate and validate the release manifest (manifest.json).

  scripts/manifest.py generate --release v0.3.0 [--dist dist] [--output dist/manifest.json]
  scripts/manifest.py validate [dist/manifest.json] [--dist dist] [--check-source]

Every release carries a manifest.json asset next to the bundles; clickhousectl
reads it from <release URL>/manifest.json to pick a bundle without the GitHub
API. `file` is relative to the manifest's own URL. Format (schema 1):

  {
    "schema": 1,
    "release": "v0.3.0",
    "built_at": "2026-11-16T00:00:00Z",
    "source": { "repo": "sdairs/pg-bundles", "commit": "<sha>" },
    "bundles": [
      {
        "postgres_version": "18.7",
        "postgres_major": "18",
        "extensions": { "pg_clickhouse": "0.11.1" },
        "target": "aarch64-apple-darwin",
        "file": "pg-18.7-pgch-0.11.1-aarch64-apple-darwin.tar.gz",
        "sha256": "<64 hex>",
        "size": 11370169
      }
    ]
  }

`generate` describes every pg-*.tar.gz in --dist: versions and target come
from the BUNDLE.json inside each tarball, sha256 and size from the file.
`validate` checks a manifest against --dist and scripts/versions.env: one
bundle for every PostgreSQL major x target, the pinned versions, and sha256
and size equal to the file (and to its .sha256 sidecar).

Python 3 standard library only.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import tarfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA = 1
# The targets every release must carry (Rust-style triples, as used by chctl).
TARGETS = [
    "aarch64-apple-darwin",
    "x86_64-apple-darwin",
    "aarch64-unknown-linux-musl",
    "x86_64-unknown-linux-musl",
]


def die(msg):
    sys.exit(f"error: {msg}")


def read_versions(path):
    """Plain NAME=value assignments of versions.env (no shell expansion)."""
    out = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r'^([A-Z][A-Z0-9_]*)=("?)([^"$\s]*)\2\s*$', line)
            if m:
                out[m.group(1)] = m.group(3)
    majors = re.search(r'^PG_MAJORS="([^"]*)"', open(path, encoding="utf-8").read(), re.M)
    out["PG_MAJORS"] = majors.group(1) if majors else ""
    return out


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def bundle_json(path):
    """BUNDLE.json from inside a bundle tarball."""
    name = os.path.basename(path)[: -len(".tar.gz")]
    with tarfile.open(path, "r:gz") as tar:
        member = tar.extractfile(f"{name}/BUNDLE.json")
        if member is None:
            die(f"{path}: {name}/BUNDLE.json is not a file")
        return json.load(member)


def git_head():
    try:
        return subprocess.run(
            ["git", "-C", ROOT, "rev-parse", "HEAD"], check=True, capture_output=True, text=True
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def expected_file(pg_version, pgch_version, target):
    return f"pg-{pg_version}-pgch-{pgch_version}-{target}.tar.gz"


def target_order(target):
    return TARGETS.index(target) if target in TARGETS else len(TARGETS)


def generate(args):
    if not re.fullmatch(r"v[0-9A-Za-z][0-9A-Za-z.+-]*", args.release):
        die(f"--release must look like v1.2.3, got {args.release!r}")
    files = sorted(f for f in os.listdir(args.dist) if f.startswith("pg-") and f.endswith(".tar.gz"))
    if not files:
        die(f"no pg-*.tar.gz bundles in {args.dist}")
    bundles = []
    for name in files:
        path = os.path.join(args.dist, name)
        info = bundle_json(path)
        pg_version = info["postgres_version"]
        bundles.append(
            {
                "postgres_version": pg_version,
                "postgres_major": pg_version.split(".")[0],
                "extensions": info["extensions"],
                "target": info["target"],
                "file": name,
                "sha256": sha256_file(path),
                "size": os.path.getsize(path),
            }
        )
    # Newest PostgreSQL major first, then a fixed target order.
    bundles.sort(key=lambda b: (-int(b["postgres_major"]), target_order(b["target"]), b["file"]))
    commit = args.commit or git_head() or os.environ.get("GITHUB_SHA")
    if not commit:
        die("no source commit: pass --commit")
    manifest = {
        "schema": SCHEMA,
        "release": args.release,
        "built_at": args.built_at
        or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": {
            "repo": args.repo or os.environ.get("GITHUB_REPOSITORY") or "sdairs/pg-bundles",
            "commit": commit,
        },
        "bundles": bundles,
    }
    output = args.output or os.path.join(args.dist, "manifest.json")
    with open(output, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print(f"wrote {output}: {args.release}, {len(bundles)} bundles", file=sys.stderr)


def validate(args):
    path = args.manifest or os.path.join(args.dist, "manifest.json")
    with open(path, encoding="utf-8") as f:
        m = json.load(f)
    errors = []

    def check(ok, msg):
        if not ok:
            errors.append(msg)

    versions = read_versions(args.versions)
    majors = versions["PG_MAJORS"].split()
    pgch = versions.get("PGCH_VERSION", "")
    check(bool(majors) and bool(pgch), f"{args.versions}: PG_MAJORS or PGCH_VERSION not found")

    check(m.get("schema") == SCHEMA, f"schema is {m.get('schema')!r}, want {SCHEMA}")
    check(isinstance(m.get("release"), str) and m["release"].startswith("v"), "release must be a v* tag")
    if args.release:
        check(m.get("release") == args.release, f"release is {m.get('release')!r}, want {args.release!r}")
    check(
        isinstance(m.get("built_at"), str)
        and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", m["built_at"]) is not None,
        "built_at must be UTC, YYYY-MM-DDTHH:MM:SSZ",
    )
    source = m.get("source") or {}
    check(re.fullmatch(r"[^/\s]+/[^/\s]+", str(source.get("repo", ""))) is not None, "source.repo must be owner/name")
    check(re.fullmatch(r"[0-9a-f]{40}", str(source.get("commit", ""))) is not None, "source.commit must be a 40-hex sha")
    check(set(m) == {"schema", "release", "built_at", "source", "bundles"}, f"unexpected top-level keys: {sorted(m)}")

    bundles = m.get("bundles") or []
    seen = {}
    for b in bundles:
        label = b.get("file", "?")
        want_keys = {"postgres_version", "postgres_major", "extensions", "target", "file", "sha256", "size"}
        check(set(b) == want_keys, f"{label}: keys are {sorted(b)}, want {sorted(want_keys)}")
        if set(b) != want_keys:
            continue
        major, target, name = b["postgres_major"], b["target"], b["file"]
        check((major, target) not in seen, f"{label}: duplicate of {seen.get((major, target))}")
        seen[(major, target)] = name
        check(major in majors, f"{label}: PostgreSQL major {major} is not in PG_MAJORS ({' '.join(majors)})")
        check(target in TARGETS, f"{label}: unexpected target {target}")
        check(b["postgres_version"].split(".")[0] == major, f"{label}: postgres_major {major} does not match {b['postgres_version']}")
        want_version = versions.get(f"PG{major}_VERSION")
        check(b["postgres_version"] == want_version, f"{label}: postgres_version {b['postgres_version']}, versions.env pins {want_version}")
        check(b["extensions"] == {"pg_clickhouse": pgch}, f"{label}: extensions {b['extensions']}, versions.env pins pg_clickhouse {pgch}")
        check("/" not in name and name == expected_file(b["postgres_version"], pgch, target), f"{label}: file name does not follow pg-<pg>-pgch-<pgch>-<target>.tar.gz")
        check(re.fullmatch(r"[0-9a-f]{64}", str(b["sha256"])) is not None, f"{label}: sha256 is not 64 hex digits")
        check(isinstance(b["size"], int) and b["size"] > 0, f"{label}: size must be a positive integer")
        fpath = os.path.join(args.dist, name)
        if not os.path.isfile(fpath):
            errors.append(f"{label}: not found in {args.dist}")
            continue
        got = sha256_file(fpath)
        check(got == b["sha256"], f"{label}: sha256 of the file is {got}, manifest says {b['sha256']}")
        check(os.path.getsize(fpath) == b["size"], f"{label}: size of the file is {os.path.getsize(fpath)}, manifest says {b['size']}")
        sidecar = fpath + ".sha256"
        if os.path.isfile(sidecar):
            with open(sidecar, encoding="utf-8") as f:
                check(f.read().split()[:1] == [got], f"{label}: .sha256 sidecar does not match the file")
        else:
            errors.append(f"{label}: no .sha256 sidecar in {args.dist}")
        info = bundle_json(fpath)
        check(
            (info.get("postgres_version"), info.get("target"), info.get("extensions"))
            == (b["postgres_version"], target, b["extensions"]),
            f"{label}: BUNDLE.json inside the tarball disagrees with the manifest entry",
        )
        if args.check_source:
            src = info.get("source") or {}
            check(src.get("commit") == source.get("commit"), f"{label}: built from {src.get('commit')}, manifest source.commit is {source.get('commit')}")
            check(not src.get("dirty"), f"{label}: built from a tree with local changes")

    for major in majors:
        for target in TARGETS:
            check((major, target) in seen, f"missing bundle: PostgreSQL {major} for {target}")
    stray = sorted(
        f for f in os.listdir(args.dist)
        if f.startswith("pg-") and f.endswith(".tar.gz") and f not in {b.get("file") for b in bundles}
    )
    check(not stray, f"bundles in {args.dist} that the manifest does not list: {' '.join(stray)}")

    if errors:
        for e in errors:
            print(f"manifest: {e}", file=sys.stderr)
        die(f"{path} is not valid ({len(errors)} problem(s))")
    print(f"ok: {path}: {m['release']}, {len(bundles)} bundles ({len(majors)} PostgreSQL majors x {len(TARGETS)} targets), sha256 and size match")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = parser.add_subparsers(dest="command", required=True)

    g = sub.add_parser("generate", help="write manifest.json for the bundles in --dist")
    g.add_argument("--release", required=True, help="release tag, e.g. v0.3.0")
    g.add_argument("--dist", default=os.path.join(ROOT, "dist"))
    g.add_argument("--output", help="default: <dist>/manifest.json")
    g.add_argument("--repo", help="default: $GITHUB_REPOSITORY, else sdairs/pg-bundles")
    g.add_argument("--commit", help="default: git rev-parse HEAD, else $GITHUB_SHA")
    g.add_argument("--built-at", help="default: now (UTC)")
    g.set_defaults(func=generate)

    v = sub.add_parser("validate", help="check a manifest against --dist and versions.env")
    v.add_argument("manifest", nargs="?", help="default: <dist>/manifest.json")
    v.add_argument("--dist", default=os.path.join(ROOT, "dist"))
    v.add_argument("--versions", default=os.path.join(ROOT, "scripts", "versions.env"))
    v.add_argument("--release", help="also require this release tag")
    v.add_argument("--check-source", action="store_true",
                   help="also require every bundle to be built from source.commit, with no local changes")
    v.set_defaults(func=validate)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
