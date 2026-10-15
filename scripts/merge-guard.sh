#!/usr/bin/env bash
# merge-guard.sh <pr-number|pr-url> [--repo owner/repo] — read-only per-PR veto.
# Exit 0 = CLEAR, 3 = BLOCK, 2 = UNKNOWN/usage; any nonzero means do not merge.
set -uo pipefail
usage() { echo 'Usage: merge-guard.sh <pr-number|pr-url> [--repo owner/repo]' >&2; exit 2; }
[ "$#" -ge 1 ] || usage
pr="$1"; shift
[[ "$pr" =~ ^[1-9][0-9]*$|^https?://[^/]+/[^/]+/[^/]+/pull/[1-9][0-9]*$ ]] || usage
repo_args=()
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = --repo ] || usage
  [[ "$2" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
  repo_args=(--repo "$2")
fi
if ! pr_json="$(gh pr view "$pr" "${repo_args[@]}" --json number,url,title,body,isDraft,labels,files)"; then
  echo "merge-guard: UNKNOWN $pr (gh pr view failed)"; exit 2
fi
parks="${CRSS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/crss}/merge-parks.txt"
python3 - "$parks" 3< <(printf '%s' "$pr_json") <<'PYEOF'
import json, os, re, sys
from urllib.parse import urlsplit

try:
    with os.fdopen(3) as fh:
        pr = json.load(fh)
    for key, kind in (("number", int), ("url", str), ("title", str), ("body", str),
                      ("isDraft", bool), ("labels", list), ("files", list)):
        if type(pr[key]) is not kind:
            raise ValueError(f"invalid {key}")
    url = urlsplit(pr["url"])
    identity = re.fullmatch(r"/([^/]+/[^/]+)/pull/([1-9][0-9]*)", url.path)
    if (url.scheme not in ("http", "https") or not url.netloc or not identity
            or int(identity[2]) != pr["number"]):
        raise ValueError("invalid PR URL")
    labels = [label["name"] for label in pr["labels"]]
    files = [file["path"] for file in pr["files"]]
    if any(type(value) is not str for value in labels + files):
        raise ValueError("invalid labels/files")
    reasons = []
    if pr["isDraft"]:
        reasons.append("draft")
    banner = r"do[ -_]?not[ -_]?merge|don'?t merge|\bDNM\b|needs? (the )?operator('s)? (go-ahead|approval|ok)"
    if (re.search(banner + r"|\bWIP\b", pr["title"], re.I)
            or re.search(banner, pr["body"], re.I)):
        reasons.append("banner: per-item merge veto")
    veto_labels = {"do-not-merge", "dnm", "hold", "on-hold", "parked", "park",
                   "blocked", "wip", "needs-operator"}
    for label in labels:
        if label.lower().replace("_", "-").replace(" ", "-") in veto_labels:
            reasons.append(f"label: {label}")
    item = f"{identity[1]}#{pr['number']}"
    try:
        with open(sys.argv[1], encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and line.split(maxsplit=1)[0] == item:
                    reasons.append(f"park: {line}")
                    break
    except FileNotFoundError:
        pass
    missing = set()
    # Only change claims: the line (after list/bold markers) must START with the verb.
    claim = re.compile(r"(delet|remov|drop|add|creat|renam|mov)\w*\b", re.I)
    ext = r"\.(sh|py|md|js|jsx|ts|tsx|json|ya?ml|toml|txt|csv|html|css|go|rs|sql|cfg|ini)$"
    bases = {f.rsplit("/", 1)[-1] for f in files}
    for line in pr["body"].splitlines():
        match = claim.match(re.sub(r"^[\s>*+\-0-9.)#]*(\*\*)?", "", line))
        if not match:
            continue
        # A rename/move names an old and a new path; gh's files list only ever
        # carries the new one. The new path is usually last ("X to/into Y"), but
        # "Y from X" puts it first — so a path explicitly marked with "from" is
        # the source and excluded, and the destination is the last of what's left.
        is_rename = match.group(1).lower() in ("renam", "mov")
        line_paths = []
        for path in re.findall(r"`([^`]+)`", line):
            if (re.search(r"[\s<>{}*$]", path) or re.match(r"[a-z][a-z0-9+.-]*://", path, re.I)
                    or not re.search(ext, path, re.I) and not ("/" in path and not path.startswith("/"))):
                continue
            touched = (path in files or any(f.startswith(path.rstrip("/") + "/") for f in files)
                       or ("/" not in path and path in bases))
            line_paths.append((path, touched))
        if is_rename:
            non_source = [(p, t) for p, t in line_paths
                          if not re.search(r"\bfrom\s+`" + re.escape(p) + "`", line, re.I)]
            line_paths = (non_source or line_paths)[-1:]
        for path, touched in line_paths:
            if not touched and path not in missing:
                reasons.append(f"body-vs-diff: {path} is not touched by the diff")
                missing.add(path)
except (ValueError, TypeError, KeyError, OSError, AttributeError) as exc:
    print(f"merge-guard: UNKNOWN (cannot evaluate PR: {exc})")
    sys.exit(2)

print(f"merge-guard: {'BLOCK' if reasons else 'CLEAR'} {pr['url']}")
for reason in reasons:
    print(f"  - {reason}")
sys.exit(3 if reasons else 0)
PYEOF
