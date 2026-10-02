#!/usr/bin/env bash
# scripts/session-trust-seed.sh: pre-accepting the folder-trust dialog. Hermetic —
# CLAUDE_CONFIG_DIR points at a temp dir, the real global config is never read or written.
# The key rule (worktree -> MAIN repo root; ancestors do not count for git repos) was
# verified live against the installed CLI; this suite pins the helper's side of it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
SEED="$HERE/../scripts/session-trust-seed.sh"
command -v python3 >/dev/null 2>&1 || { echo "session-trust-seed: SKIP (no python3)"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "session-trust-seed: SKIP (no git)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export CLAUDE_CONFIG_DIR="$T/cfg"; mkdir -p "$CLAUDE_CONFIG_DIR"
CFG="$CLAUDE_CONFIG_DIR/.claude.json"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

REPO="$T/repo"; git init -q "$REPO" && git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" worktree add -q "$T/wt" -b wtb
mkdir -p "$T/plain/sub"; ln -s "$T/wt" "$T/wtlink"
REPO="$(cd "$REPO" && pwd -P)"; PLAIN="$(cd "$T/plain" && pwd -P)"
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["projects"].get(sys.argv[2],{}).get("hasTrustDialogAccepted","absent"))' "$CFG" "$1"; }

printf '{\n  "numStartups": 7,\n  "oauth": {"k": "vé"},\n  "projects": {"/other": {"hasTrustDialogAccepted": false, "allowedTools": ["x"]}}\n}' > "$CFG"
chmod 640 "$CFG"

# worktree -> the MAIN repo root key; other keys survive; mode kept; backup made
out="$(bash "$SEED" "$T/wt" 2>&1)"; rc=$?
ok  "seed-worktree-rc" "$rc" "0"
has "seed-worktree-says-main-root" "$out" "trusted (seeded): $REPO"
ok  "seed-worktree-key-true" "$(jget "$REPO")" "True"
ok  "no-worktree-key" "$(jget "$(cd "$T/wt" && pwd -P)")" "absent"
ok  "other-project-untouched" "$(jget /other)" "False"
ok  "other-toplevel-key-kept" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["numStartups"], d["oauth"]["k"], d["projects"]["/other"]["allowedTools"])' "$CFG")" "7 vé ['x']"
ok  "mode-preserved" "$(stat -c %a "$CFG")" "640"
isfile "backup-made" "$CFG.crss-bak"
ok  "no-stray-temp" "$(ls -A "$CLAUDE_CONFIG_DIR" | grep -c '^\.claude\.json\.crss-[A-Za-z0-9_]\{6,\}$')" "0"

# idempotent: second run reports already-trusted and does not rewrite the file
before="$(cksum < "$CFG")"; touch -d '2001-01-01' "$CFG"
out="$(bash "$SEED" "$T/wt" "$REPO" 2>&1)"
has "idempotent-already" "$out" "trusted (already): $REPO"
hasnt "idempotent-no-reseed" "$out" "seeded"
ok  "idempotent-content-same" "$(cksum < "$CFG")" "$before"
ok  "idempotent-not-rewritten" "$(stat -c %Y "$CFG")" "$(date -d '2001-01-01' +%s)"

# path normalisation: symlink, trailing slash, nested dir inside a worktree all resolve to the same key
out="$(bash "$SEED" "$T/wtlink" "$T/wt/" 2>&1)"
hasnt "symlink-and-slash-same-key" "$out" "seeded"
# non-git dir -> its own (realpath) key; nested non-git dir keyed by itself
out="$(bash "$SEED" "$T/plain/sub" 2>&1)"
has "plain-dir-own-key" "$out" "trusted (seeded): $PLAIN/sub"

# refusals leave the file byte-identical
before="$(cksum < "$CFG")"
out="$(bash "$SEED" "$T/does-not-exist" 2>&1)"; rc=$?
ok "missing-dir-rc1" "$rc" "1"; has "missing-dir-msg" "$out" "not a directory"
out="$(bash "$SEED" 2>&1)"; rc=$?
ok "no-args-rc2" "$rc" "2"
ok "refusals-leave-file-alone" "$(cksum < "$CFG")" "$before"
printf '{"projects": {' > "$CFG"; before="$(cksum < "$CFG")"
out="$(bash "$SEED" "$T/plain" 2>&1)"; rc=$?
ok "invalid-json-rc1" "$rc" "1"; has "invalid-json-msg" "$out" "not valid JSON"
ok "invalid-json-not-clobbered" "$(cksum < "$CFG")" "$before"
printf '[1,2]' > "$CFG"; out="$(bash "$SEED" "$T/plain" 2>&1)"; rc=$?
ok "bad-shape-rc1" "$rc" "1"; has "bad-shape-msg" "$out" "unexpected shape"
printf '{"projects": {"%s": 5}}' "$PLAIN" > "$CFG"; out="$(bash "$SEED" "$T/plain" 2>&1)"; rc=$?
ok "bad-entry-rc1" "$rc" "1"
rm -f "$CFG"; out="$(bash "$SEED" "$T/plain" 2>&1)"; rc=$?
ok "missing-config-rc1" "$rc" "1"; has "missing-config-msg" "$out" "does not exist"
nofile "missing-config-not-created" "$CFG"

# concurrent seeders (parallel processes, distinct dirs) must not lose each other's entries
printf '{"keep": 1, "projects": {}}' > "$CFG"
N=12; for i in $(seq 1 $N); do mkdir -p "$T/c$i"; done
for i in $(seq 1 $N); do bash "$SEED" "$T/c$i" >/dev/null 2>&1 & done; wait
ok "concurrent-all-present" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sum(1 for v in d["projects"].values() if v.get("hasTrustDialogAccepted") is True), d["keep"])' "$CFG")" "$N 1"

finish "session-trust-seed"
