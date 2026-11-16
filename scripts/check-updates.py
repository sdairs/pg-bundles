#!/usr/bin/env python3
"""Find newer upstream releases of the sources pinned in scripts/versions.env.

  scripts/check-updates.py            # dry run: report, change nothing
  scripts/check-updates.py --write    # also update scripts/versions.env

What is tracked, and where the new version and its hash come from:

  PostgreSQL     latest minor of each major in PG_MAJORS: the directory
                 listing of ftp.postgresql.org/pub/source; sha256 from the
                 .sha256 file next to the tarball
  pg_clickhouse  latest stable release on PGXN (api.pgxn.org); sha1 from the
                 distribution's META.json
  OpenSSL        latest patch release of the pinned <major>.<minor> series
                 (GitHub releases of openssl/openssl); sha256 from the
                 .sha256 release asset
  curl, zlib     latest GitHub release with the pinned major version; sha256
                 from the digest GitHub records for the release asset
  lz4, zstd      latest GitHub release with the pinned major version; sha256
                 from the .sha256 release asset
  util-linux     latest patch release of the pinned <major>.<minor> series
                 (kernel.org directory listing); sha256 from sha256sums.asc

Every new tarball is downloaded from the URL the build will use and its
sha256 is computed here; the update is refused unless that agrees with the
upstream-published hash. A release with a different major version (or, for
OpenSSL and util-linux, a different series) is reported but never applied.

Not tracked (bump by hand): libedit and ncurses (no machine-readable release
list or published hash), musl and the build/test container images (pinned by
digest in build-linux.sh and the workflows; musl comes from the Alpine image).

Set GH_TOKEN or GITHUB_TOKEN to raise the GitHub API rate limit. Python 3
standard library only.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERSIONS_ENV = os.path.join(ROOT, "scripts", "versions.env")


def log(msg):
    print(msg, file=sys.stderr)


def vtuple(version):
    return tuple(int(x) for x in version.split("."))


def http(url, binary=False):
    headers = {"User-Agent": "pg-bundles-check-updates"}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token and url.startswith("https://api.github.com/"):
        headers["Authorization"] = f"Bearer {token}"
    last = None
    for attempt in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120) as r:
                data = r.read()
                return data if binary else data.decode("utf-8", "replace")
        except (urllib.error.URLError, OSError) as e:
            last = e
            if isinstance(e, urllib.error.HTTPError) and e.code in (403, 404):
                break
            time.sleep(3 * (attempt + 1))
    raise RuntimeError(f"GET {url}: {last}")


def download_hashes(url):
    """Download url (in memory, nothing is kept); return its (sha256, sha1)."""
    data = http(url, binary=True)
    return hashlib.sha256(data).hexdigest(), hashlib.sha1(data).hexdigest()


# ------------------------------------------------------------ versions.env ----
class Versions:
    def __init__(self, path):
        self.path = path
        with open(path, encoding="utf-8") as f:
            self.text = f.read()

    def get(self, name):
        m = re.search(rf'^{name}="?([^"\n]*)"?$', self.text, re.M)
        if not m:
            raise KeyError(f"{name} not found in {self.path}")
        return m.group(1)

    def set(self, name, value):
        new, n = re.subn(rf"^{name}=.*$", f"{name}={value}", self.text, flags=re.M)
        if n != 1:
            raise KeyError(f"{name}: expected one assignment in {self.path}, found {n}")
        self.text = new

    def url(self, name, version):
        """First URL of <name>_URL with its ${<NAME>_VERSION} expanded to version."""
        template = self.get(f"{name}_URL").split()[0]
        return template.replace("${%s_VERSION}" % name, version)

    def save(self):
        with open(self.path, "w", encoding="utf-8") as f:
            f.write(self.text)


# ------------------------------------------------------------- GitHub API ----
def github_releases(repo):
    return json.loads(http(f"https://api.github.com/repos/{repo}/releases?per_page=100"))


def github_candidates(repo, tag_re):
    """[(version, release)] for stable releases whose tag matches tag_re."""
    out = []
    for rel in github_releases(repo):
        if rel.get("draft") or rel.get("prerelease"):
            continue
        m = re.fullmatch(tag_re, rel["tag_name"])
        if m:
            out.append((".".join(g for g in m.groups() if g is not None), rel))
    return out


def asset(release, name):
    for a in release.get("assets", []):
        if a["name"] == name:
            return a
    return None


def asset_digest(release, name):
    a = asset(release, name)
    digest = (a or {}).get("digest") or ""
    if not digest.startswith("sha256:"):
        raise RuntimeError(f"no sha256 digest recorded for release asset {name}")
    return digest[len("sha256:"):]


def asset_sha256_file(release, name):
    a = asset(release, name + ".sha256")
    if not a:
        raise RuntimeError(f"no release asset {name}.sha256")
    return http(a["browser_download_url"]).split()[0]


# --------------------------------------------------------------- checkers ----
# Each returns None (up to date) or a dict: name, label, old, new, sha256
# (published or computed upstream hash), plus "verify" telling how the
# downloaded file must match: ("sha256", hex) or ("sha1", hex).
def pick(current, candidates, same):
    """Newest candidate version within the series `same` selects; notes newer ones outside it."""
    cur = vtuple(current)
    inside = [c for c in candidates if same(vtuple(c[0]))]
    outside = [c[0] for c in candidates if not same(vtuple(c[0])) and vtuple(c[0]) > cur]
    best = max(inside, key=lambda c: vtuple(c[0]), default=None)
    note = max(outside, key=vtuple) if outside else None
    if best and vtuple(best[0]) > cur:
        return best, note
    return None, note


def check_postgres(v, major):
    name = f"PG{major}"
    current = v.get(f"{name}_VERSION")
    listing = http("https://ftp.postgresql.org/pub/source/")
    minors = {int(m) for m in re.findall(rf'href="v{major}\.(\d+)/"', listing)}
    if not minors:
        raise RuntimeError(f"no v{major}.* releases in the ftp.postgresql.org listing")
    new = f"{major}.{max(minors)}"
    if vtuple(new) <= vtuple(current):
        return None, None
    url = f"https://ftp.postgresql.org/pub/source/v{new}/postgresql-{new}.tar.bz2"
    published = http(url + ".sha256").split()[0]
    return {"name": name, "label": f"PostgreSQL {major}", "old": current, "new": new,
            "url": url, "verify": ("sha256", published)}, None


def check_pg_clickhouse(v):
    current = v.get("PGCH_VERSION")
    dist = json.loads(http("https://api.pgxn.org/dist/pg_clickhouse.json"))
    stable = [r["version"] for r in dist["releases"].get("stable", []) if re.fullmatch(r"\d+(\.\d+)+", r["version"])]
    new = max(stable, key=vtuple)
    if vtuple(new) <= vtuple(current):
        return None, None
    meta = json.loads(http(f"https://api.pgxn.org/dist/pg_clickhouse/{new}/META.json"))
    return {"name": "PGCH", "label": "pg_clickhouse", "old": current, "new": new,
            "url": v.url("PGCH", new), "verify": ("sha1", meta["sha1"])}, None


def check_github(v, name, label, repo, tag_re, file_fmt, hash_source, series_len):
    """series_len: how many leading version components must stay the same."""
    current = v.get(f"{name}_VERSION")
    cur = vtuple(current)
    best, note = pick(current, github_candidates(repo, tag_re), lambda t: t[:series_len] == cur[:series_len])
    if not best:
        return None, note
    new, release = best
    published = hash_source(release, file_fmt.format(v=new))
    return {"name": name, "label": label, "old": current, "new": new,
            "url": v.url(name, new), "verify": ("sha256", published)}, note


def check_util_linux(v):
    current = v.get("UTIL_LINUX_VERSION")
    series = ".".join(current.split(".")[:2])
    base = f"https://cdn.kernel.org/pub/linux/utils/util-linux/v{series}/"
    listing = http(base)
    found = set(re.findall(rf'href="util-linux-({re.escape(series)}(?:\.\d+)?)\.tar\.xz"', listing))
    new = max(found, key=vtuple, default=current)
    if vtuple(new) <= vtuple(current):
        return None, None
    sums = http(base + "sha256sums.asc")
    m = re.search(rf"^([0-9a-f]{{64}})\s+\*?util-linux-{re.escape(new)}\.tar\.xz$", sums, re.M)
    if not m:
        raise RuntimeError(f"util-linux-{new}.tar.xz is not in sha256sums.asc")
    return {"name": "UTIL_LINUX", "label": "util-linux (libuuid)", "old": current, "new": new,
            "url": v.url("UTIL_LINUX", new), "verify": ("sha256", m.group(1))}, None


def checkers(v):
    for major in v.get("PG_MAJORS").split():
        yield f"PostgreSQL {major}", lambda major=major: check_postgres(v, major)
    yield "pg_clickhouse", lambda: check_pg_clickhouse(v)
    yield "OpenSSL", lambda: check_github(
        v, "OPENSSL", "OpenSSL", "openssl/openssl", r"openssl-(\d+)\.(\d+)\.(\d+)",
        "openssl-{v}.tar.gz", asset_sha256_file, 2)
    yield "curl", lambda: check_github(
        v, "CURL", "curl", "curl/curl", r"curl-(\d+)_(\d+)_(\d+)",
        "curl-{v}.tar.xz", asset_digest, 1)
    yield "lz4", lambda: check_github(
        v, "LZ4", "lz4", "lz4/lz4", r"v(\d+)\.(\d+)\.(\d+)",
        "lz4-{v}.tar.gz", asset_sha256_file, 1)
    yield "zstd", lambda: check_github(
        v, "ZSTD", "zstd", "facebook/zstd", r"v(\d+)\.(\d+)\.(\d+)",
        "zstd-{v}.tar.gz", asset_sha256_file, 1)
    yield "zlib", lambda: check_github(
        v, "ZLIB", "zlib", "madler/zlib", r"v(\d+)\.(\d+)(?:\.(\d+))?(?:\.(\d+))?",
        "zlib-{v}.tar.gz", asset_digest, 1)
    yield "util-linux", lambda: check_util_linux(v)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--write", action="store_true", help="update scripts/versions.env (default: dry run)")
    parser.add_argument("--versions", default=VERSIONS_ENV, help="versions.env to read (and write)")
    parser.add_argument("--summary", help="write the list of updates (one per line) to this file")
    parser.add_argument("--github-output", help="append changed=true|false to this file ($GITHUB_OUTPUT)")
    args = parser.parse_args()

    v = Versions(args.versions)
    updates, failed = [], []
    for label, run in checkers(v):
        try:
            update, note = run()
        except Exception as e:  # one unreachable upstream must not hide the others
            log(f"FAILED    {label}: {e}")
            failed.append(label)
            continue
        if note:
            log(f"note      {label}: {note} is available but is outside the pinned series; not applied")
        if not update:
            log(f"current   {label}")
            continue
        try:
            sha256, sha1 = download_hashes(update["url"])
        except Exception as e:
            log(f"FAILED    {label}: {e}")
            failed.append(label)
            continue
        kind, want = update["verify"]
        got = sha256 if kind == "sha256" else sha1
        if got != want.lower():
            log(f"FAILED    {label} {update['new']}: {kind} of {update['url']} is {got}, upstream publishes {want}")
            failed.append(label)
            continue
        update["sha256"] = sha256
        log(f"UPDATE    {update['label']}: {update['old']} -> {update['new']} (sha256 {sha256}, {kind} matches upstream)")
        updates.append(update)

    # Any failure means the check is incomplete: change nothing, fail the run.
    if failed:
        log(f"error: could not check or verify: {', '.join(failed)}; nothing was changed")
        return 1
    lines = [f"{u['label']} {u['old']} -> {u['new']}" for u in updates]
    if args.write and updates:
        for u in updates:
            v.set(f"{u['name']}_VERSION", u["new"])
            v.set(f"{u['name']}_SHA256", u["sha256"])
        v.save()
        log(f"updated {args.versions}")
    elif updates:
        log("dry run: scripts/versions.env not changed (pass --write)")
    else:
        log("everything is up to date")
    if args.summary:
        with open(args.summary, "w", encoding="utf-8") as f:
            f.write("".join(line + "\n" for line in lines))
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as f:
            f.write(f"changed={'true' if updates else 'false'}\n")
    for line in lines:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
