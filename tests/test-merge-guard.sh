#!/usr/bin/env bash
# merge-guard.sh — read-only per-PR vetoes, with gh fixtures (no network).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
isolate_overlay
GUARD="$HERE/../scripts/merge-guard.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home" FIX="$T/fixtures" GH_LOG="$T/gh.log"
export CRSS_HOME="$HOME/overlay"
mkdir -p "$T/bin" "$T/work" "$CRSS_HOME" "$FIX"
printf '# owner/repo#1 is only a comment\nowner/repo#5 operator park\nowner/repo#50\n' > "$CRSS_HOME/merge-parks.txt"
python3 - "$FIX" <<'PYEOF'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
cases = {
    1: {},
    279: {"body": "DO NOT MERGE without the operator's go-ahead. Merging publishes the site."},
    44: {"body": "Delete `tests/test_coverage_new.py`, `tests/test_old.py`, and `docs/old.md`.",
         "files": [{"path": "scripts/wrapper.py"}]},
    4: {"isDraft": True, "labels": [{"name": "HOLD"}]},
    5: {},
    6: {"body": "Ports the rewrite (`docs/x.md`) into the tool. WIP is mentioned in context."},
    8: {"body": "Add `docs/`, `README.md`, `https://example.com/x.md`, and `two words.md`.",
        "files": [{"path": "docs/x.md"}, {"path": "README.md"}]},
    9: {"title": "WIP: rewrite", "body": "Needs the operator's approval.",
        "labels": [{"name": "ON_HOLD"}, {"name": "Needs Operator"}]},
    10: {"body": "Remove `docs/x.md` and `docs/x.md`.", "files": [{"path": "docs/xy.md"}]},
}
for n, changes in cases.items():
    pr = dict(number=n, url=f"https://example.com/owner/repo/pull/{n}", title="Rewrite",
              body="", isDraft=False, labels=[], files=[])
    pr.update(changes)
    (root / f"{n}.json").write_text(json.dumps(pr))
(root / "11.json").write_text("not json")
(root / "12.json").write_text('{"number":12}')
PYEOF
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
[ "$1 $2" = 'pr view' ] || exit 1
[ "$3" != 7 ] || exit 1
key="${3##*/}"
cat "$FIX/$key.json"
STUB
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
cd "$T/work" || exit 1
snapshot() {
  python3 - "$HOME" "$FIX" "$PWD" <<'PYEOF'
import hashlib, pathlib, sys
for directory in sys.argv[1:]:
    for p in sorted(pathlib.Path(directory).rglob("*")):
        print(p, hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "dir")
PYEOF
}
before="$(snapshot)"
run() { out="$(bash "$GUARD" "$@" 2>&1)"; rc=$?; }
run 1 --repo owner/repo
ok clean-exit "$rc" 0
ok clean-output "$out" 'merge-guard: CLEAR https://example.com/owner/repo/pull/1'
run 279 --repo owner/repo
ok banner-exit "$rc" 3; has banner "$out" '  - banner:'
run 44 --repo owner/repo
ok claim-exit "$rc" 3
for path in tests/test_coverage_new.py tests/test_old.py docs/old.md; do has missing-path "$out" "$path"; done
run 4
ok draft-label-exit "$rc" 3; has draft "$out" '  - draft'; has label "$out" '  - label: HOLD'
run https://example.com/owner/repo/pull/5
ok parked-exit "$rc" 3; has parked "$out" '  - park: owner/repo#5'
run 6
ok contextual-mention "$rc" 0
run 7
ok gh-failed-exit "$rc" 2; has gh-failed-output "$out" 'merge-guard: UNKNOWN'
run 8
ok touched-directory-and-file "$rc" 0
run 9
ok title-operator-label-exit "$rc" 3; has title-operator-banner "$out" '  - banner:'
has underscore-label "$out" '  - label: ON_HOLD'; has space-label "$out" '  - label: Needs Operator'
run 10
ok prefix-is-not-directory "$rc" 3
ok deduplicate-missing-path "$(grep -c '  - body-vs-diff: docs/x.md' <<< "$out")" 1
for n in 11 12; do
  run "$n"
  ok invalid-json-exit "$rc" 2; has invalid-json-output "$out" 'merge-guard: UNKNOWN'
done
for args in '' '1 --repo' '1 --unknown' '1 --repo owner' '1 2'; do
  read -r -a argv <<< "$args"
  run "${argv[@]}"
  ok usage-exit "$rc" 2
done
ok read-only "$(snapshot)" "$before"
ok one-view-per-pr "$(wc -l < "$GH_LOG" | tr -d ' ')" 12
hasnt never-merge "$(cat "$GH_LOG")" merge
has forwarded-repo "$(cat "$GH_LOG")" 'pr view 1 --repo owner/repo --json'
finish merge-guard
