#!/usr/bin/env bash
# session-doctor.sh — audit and clean up agenthost remote-control sessions across
# the layers they live in: tmux windows, systemd --user units, the Anthropic
# session registry (GET /v1/sessions), and per-session git worktrees
# (~/.claude/worktrees/, created by session-git-prep.sh for dirty/busy repos).
# Local reaping alone does not relieve session-count pressure, because the
# registry accumulates disconnected and zombie ("connected" but process-gone)
# entries independently, and worktrees accumulate independently of both.
#
# Usage:
#   session-doctor.sh                      # report (read-only) — default
#   session-doctor.sh reap-local           # remove DEAD local sessions (proc gone / orphaned unit+script)
#   session-doctor.sh reap <name> [--force] [--keep-registry] [--keep-worktree]
#                                           # one-shot teardown of a named ALIVE session (tmux+unit);
#                                           # refuses on unlanded work unless --force; also deletes
#                                           # that session's registry entry (by title == base name)
#                                           # unless --keep-registry — fails soft if the registry is
#                                           # unreachable, never changes reap's own exit status; also
#                                           # removes the session's ~/.claude/worktrees/<base> git
#                                           # worktree (branch kept) unless --keep-worktree — see
#                                           # _reap_remove_worktree's own header comment for the
#                                           # guards (dirty refusal, in-use-by-another-unit, caller's
#                                           # own cwd, primary checkout) that make this safe
#   session-doctor.sh registry-stale [--days N]   # list registry sessions disconnected > N days (default 30)
#   session-doctor.sh registry-prune [--days N] [--apply]
#                                           # same candidate set as registry-stale; DRY-RUN by default
#                                           # (prints deleted/skipped(reason)/failed(code) per row with
#                                           # no mutation); --apply performs the DELETEs. Always skips
#                                           # PROTECT-matching titles, any title matching a live tmux
#                                           # session, and requires_action rows (rows stale >2xN days
#                                           # are still skipped, just flagged for operator review).
#                                           # Exits non-zero if any delete failed.
#   session-doctor.sh worktree-stale       # list ~/.claude/worktrees/ dirs whose owning session is dead
#   session-doctor.sh land-check           # per-worktree unlanded-vs-real-default-branch + real-dirty; report only
#   session-doctor.sh idle-report [--days N | --minutes N] [--tsv]
#                                           # list LIVE local sessions with no GENUINE user turn
#                                           # in N days (default 2) or N minutes (--minutes;
#                                           # mutually exclusive with --days); a /compact summary
#                                           # entry itself does not count as a genuine turn; --tsv
#                                           # emits one machine-readable row per session (10 tab-
#                                           # separated columns, no header/summary) for actuator
#                                           # scripts; report only
#   session-doctor.sh history <foldername>        # NOW (live sessions) + PAST (transcript history) + status for a worktree; bare name, absolute path, or repo-name substring; report only
#
# Safety:
#   * Protected names (claude-remote*, *openclaw*, *hermes*) are NEVER reaped.
#   * A tmux/systemd entry is only reaped when its claude process is genuinely gone
#     (reap-local) or the operator named it explicitly (reap).
#   * `reap` refuses a session with unlanded/uncommitted work (via session-preserve.sh)
#     unless --force; a missing tmux session or systemd unit never fails the rest of it.
#   * registry-stale never deletes (it prints candidates + the exact curl to run by
#     hand); registry-prune is the automated form of that same candidate set — DRY-RUN
#     by default, mutates only with --apply, and never touches a PROTECTED title, a
#     title matching a live tmux session, or a requires_action row.
#   * reap's registry cleanup reuses registry-prune's same protect check and delete
#     mechanism, targeted at exactly the one entry it just tore down; --keep-registry
#     skips it. A registry lookup/delete failure there is soft — it never changes
#     reap's own exit status.
#   * `reap <name>` also removes that ONE session's own ~/.claude/worktrees/<base>
#     worktree by default (--keep-worktree opts out) — never the branch. `git worktree
#     remove` runs WITHOUT --force (a dirty worktree refuses and is left in place,
#     reported, and never fails the rest of reap) except under reap's own --force,
#     where --force is passed through. A worktree any OTHER systemd user unit
#     references (WorkingDirectory or anywhere in ExecStart, drop-ins included) is
#     never removed, nor is the caller's own cwd or a repo's primary checkout. See
#     _reap_remove_worktree's header comment and
#     tests/test-session-doctor-reap-worktree.sh.
#   * Worktree removal for everything ELSE (a dead session that was reap-local'd, not
#     reap'd by name; a worktree left behind by a session reaped before this existed)
#     is intentionally NOT automated. worktree-stale prints candidates, each one's
#     dirty/landed status, and the exact commands to run by hand after review.
#   * idle-report, land-check, and history are REPORT-ONLY: idle-report's rows are
#     still-alive procs reap-local won't touch; land-check never mutates anything;
#     history only reads transcripts, /proc, and git state. Feed any of them to a
#     manual pass.
set -uo pipefail

UD="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
BIN="$HOME/.local/bin"
PROTECT='claude-remote|openclaw|hermes'
MODE="${1:-report}"; shift || true
# Per-mode default window: idle-report wants a short "today/yesterday" window (2d);
# registry-stale keeps its 30d default. --days overrides either. --minutes (idle-
# report only) is a finer-grained alternate threshold and is mutually exclusive
# with --days — see the DAYS_SET/MINUTES_SET check below.
case "$MODE" in idle-report) DAYS=2;; *) DAYS=30;; esac
FORCE=no
TSV=no
APPLY=no
KEEP_REGISTRY=no
KEEP_WORKTREE=no
MINUTES=""
DAYS_SET=no
MINUTES_SET=no
# Positional args past MODE (e.g. `reap <name>`) must survive this loop, not
# just be discarded — collect anything that isn't a recognized flag into ARGS
# and restore it as $1.. below. (No mode needed a bare positional until `reap`,
# so this previously silently dropped one; caught while adding it.)
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="$2"; DAYS_SET=yes; shift 2;;
    --minutes) MINUTES="$2"; MINUTES_SET=yes; shift 2;;
    --tsv) TSV=yes; shift;;
    --force) FORCE=yes; shift;;
    --apply) APPLY=yes; shift;;
    --keep-registry) KEEP_REGISTRY=yes; shift;;
    --keep-worktree) KEEP_WORKTREE=yes; shift;;
    *) ARGS+=("$1"); shift;;
  esac
done
set -- "${ARGS[@]}"
# --minutes and --days both select an idle-report threshold — giving both is
# ambiguous (which one wins?), not additive, so reject it outright instead of
# silently picking one.
if [ "$DAYS_SET" = yes ] && [ "$MINUTES_SET" = yes ]; then
  echo "session-doctor: --days and --minutes are mutually exclusive" >&2
  exit 2
fi
# DAYS is spliced verbatim into an embedded Python snippet below (registry-stale
# and idle-report modes) as a bare identifier, e.g. `DAYS=$DAYS`. An unvalidated
# non-numeric value (typo, empty string) is therefore live Python, not data — it
# throws an uncaught NameError/SyntaxError there instead of a clean usage error.
# Validate here so a bad --days fails fast with a readable message.
case "$DAYS" in
  ''|*[!0-9]*) echo "session-doctor: --days requires a non-negative integer, got '$DAYS'" >&2; exit 2 ;;
esac
# A digit-only value can still break the embedded-as-a-literal splice: Python 3
# rejects a leading-zero integer literal (e.g. `08`) as a SyntaxError ("leading
# zeros ... not permitted"), so `--days 08` would pass the digits-only check
# above yet still crash inside the Python snippet. Canonicalize to base-10 (same
# `10#` pattern session-alias.sh uses for the same class of problem) so the
# spliced value is always a plain, leading-zero-free literal.
DAYS=$((10#$DAYS))
# --minutes gets the identical validate-then-canonicalize treatment, but only
# when actually given — an empty/unset MINUTES is the "not requested" sentinel
# idle-report's dispatch below checks for (MINUTES_SET), not a value to validate.
if [ "$MINUTES_SET" = yes ]; then
  case "$MINUTES" in
    ''|*[!0-9]*) echo "session-doctor: --minutes requires a non-negative integer, got '$MINUTES'" >&2; exit 2 ;;
  esac
  MINUTES=$((10#$MINUTES))
fi

# registry_json — fetch EVERY page of GET /v1/sessions and return them merged
# as {"data": [...]}. The registry paginates (confirmed live 2026-09-24: a
# bare GET returns {data, first_id, has_more, last_id}; production page size
# is 200; has_more flips false only once exhausted; after_id=<last_id> fetches
# the next page with zero id overlap with the previous one). A single
# unpaginated GET here used to silently truncate registry-stale,
# registry-prune, report's registry summary, and reap's title lookup to the
# first page — the bug that made `registry-prune --apply` need 6 repeated
# passes to exhaust a real stale backlog (10/7/4/2/2/1 deletions).
#
# Walks pages via after_id until has_more is false, MAX_PAGES is hit (hard
# cap so a malformed/adversarial has_more:true can't loop forever — each
# individual GET still has curl's own -m 25 timeout), or a page's JSON fails
# to parse. A bare JSON array (no has_more/last_id — the shape this
# repo's non-pagination tests fix as a registry fixture) is treated as a
# single complete page, same as today. A parse/fetch failure on page 1
# fails the whole call (return 1, matching the pre-existing credentials-
# missing failure path below); a failure on page 2+ stops pagination but
# still returns everything fetched so far, rather than discarding it.
registry_json() {
  local tok org
  tok=$(python3 -c "import json;print(json.load(open('$HOME/.claude/.credentials.json'))['claudeAiOauth']['accessToken'])" 2>/dev/null) || return 1
  org=$(python3 -c "import json;print(json.load(open('$HOME/.claude.json')).get('oauthAccount',{}).get('organizationUuid',''))" 2>/dev/null)

  local tmpdir
  tmpdir=$(mktemp -d) || return 1
  local page=0 max_pages=50 after="" more=yes ok=1 pagefile url meta
  while [ "$more" = yes ] && [ "$page" -lt "$max_pages" ]; do
    page=$((page+1))
    pagefile="$tmpdir/page_$(printf '%03d' "$page").json"
    url="https://api.anthropic.com/v1/sessions"
    [ -n "$after" ] && url="${url}?after_id=${after}"
    curl -s -m 25 "$url" \
      -H "Authorization: Bearer $tok" -H "x-organization-uuid: $org" \
      -H "anthropic-version: 2023-06-01" -H "anthropic-beta: ccr-byoc-2025-07-29" \
      -o "$pagefile" 2>/dev/null
    meta=$(python3 -c "
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    print('error'); sys.exit()
if isinstance(d, list):
    print('done')
elif d.get('has_more') and d.get('last_id'):
    print('more ' + str(d['last_id']))
else:
    print('done')
" "$pagefile" 2>/dev/null)
    case "$meta" in
      more\ *) after="${meta#more }"; more=yes ;;
      error) [ "$page" -eq 1 ] && ok=0; more=no ;;
      *) more=no ;;
    esac
  done

  if [ "$ok" -ne 1 ]; then
    rm -rf "$tmpdir"
    return 1
  fi
  python3 -c "
import json, glob, sys
merged = []
for f in sorted(glob.glob(sys.argv[1] + '/page_*.json')):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    merged.extend(d if isinstance(d, list) else d.get('data', d.get('sessions', [])))
print(json.dumps({'data': merged}))
" "$tmpdir"
  rm -rf "$tmpdir"
}

# _registry_candidates <DAYS> — reads registry JSON on stdin, prints one
# candidate per line as id<TAB>age<TAB>session_status<TAB>title, oldest-first:
# exactly registry-stale's long-standing selection (connection_status ==
# disconnected AND age>DAYS), extracted here so registry-stale (display) and
# registry-prune (deletion candidates) never drift on what counts as "stale".
# Exits 1 with no output if the JSON can't be parsed (registry unavailable or
# malformed) — callers print their own "(registry unavailable)"-style message
# on failure rather than this function doing it, since registry-stale and
# registry-prune word that differently.
_registry_candidates() {
  local days="$1"
  python3 -c "
import sys,json,datetime
try:
    arr=json.load(sys.stdin)
except Exception:
    sys.exit(1)
arr=arr if isinstance(arr,list) else arr.get('sessions',arr.get('data',[]))
now=datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None); DAYS=$days
def agedays(s):
    try: return (now-datetime.datetime.fromisoformat((s.get('updated_at') or s.get('created_at'))[:19])).days
    except Exception: return -1
cand=[s for s in arr if s.get('connection_status')=='disconnected' and agedays(s)>DAYS]
cand.sort(key=agedays, reverse=True)
for s in cand:
    title=(s.get('title') or '').replace('\t',' ').replace(chr(10),' ')
    status=(s.get('session_status') or '').replace('\t',' ')
    print('%s\t%s\t%s\t%s' % (s.get('id'), agedays(s), status, title))
"
}

# _title_protected <title> — PROTECT (defined above) is written for machine
# names (tmux/systemd, always hyphen-separated, e.g. claude-remote-bridge);
# registry titles can instead be human-typed with spaces (e.g. the real
# "Agenthost Direct Claude Remote" entry), which the literal PROTECT regex
# would silently miss. Squeeze whitespace runs to '-' before matching so the
# same PROTECT terms catch both forms, without widening PROTECT itself (it's
# also used against tmux/systemd names elsewhere, where that broadening isn't
# wanted).
_title_protected() {
  printf '%s' "$1" | tr -s '[:space:]' '-' | grep -qiE "$PROTECT"
}

# _registry_delete_one <id> <title> — protect-check + DELETE one registry
# entry by id, same auth/headers registry_json uses (token/org re-read fresh
# here rather than threaded through, since callers only have a handful of
# deletes at most). Prints one outcome line (deleted / skipped(protected) /
# failed(HTTP code)) and returns non-zero only when the DELETE itself failed
# (a protect-skip is not a failure). Never prints the token/org.
_registry_delete_one() {
  local id="$1" title="$2" tok org http_code
  if _title_protected "$title"; then
    echo "  skipped(protected)  $id  $title"
    return 0
  fi
  tok=$(python3 -c "import json;print(json.load(open('$HOME/.claude/.credentials.json'))['claudeAiOauth']['accessToken'])" 2>/dev/null)
  org=$(python3 -c "import json;print(json.load(open('$HOME/.claude.json')).get('oauthAccount',{}).get('organizationUuid',''))" 2>/dev/null)
  http_code=$(curl -s -o /dev/null -w '%{http_code}' -m 25 -X DELETE "https://api.anthropic.com/v1/sessions/$id" \
    -H "Authorization: Bearer $tok" -H "x-organization-uuid: $org" \
    -H "anthropic-version: 2023-06-01" -H "anthropic-beta: ccr-byoc-2025-07-29" 2>/dev/null)
  case "$http_code" in
    2??) echo "  deleted  $id  $title"; return 0 ;;
    *) echo "  failed($http_code)  $id  $title"; return 1 ;;
  esac
}

live_tmux()  { tmux ls 2>/dev/null | cut -d: -f1; }
# Liveness by the tmux PANE's foreground command, NOT by guessing the remote-control
# name from the tmux session name (they often differ, e.g. tmux agenthost_chimera-control
# vs remote-control chimera-server-control). claude/node = running; sleep = supervisor
# backoff (still alive); a bare shell = supervisor loop exited = genuinely dead.
proc_alive() {  # $1 = tmux session name
  case "$(tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null)" in
    claude|node|sleep) return 0 ;;
    *) return 1 ;;
  esac
}

# Prefix mapping. `agenthost`/`ah` are the only prefixes we own; anything else
# (e.g. codexhost_) is NOT ours and must be left alone. PROTECT (line ~22) stays
# in sync with session-alias.sh.
tmux_to_base() { case "$1" in agenthost_*) echo "agenthost-${1#agenthost_}";; ah_*) echo "ah-${1#ah_}";; *) echo "";; esac; }
svc_to_tmux()  { case "$1" in agenthost-*) echo "agenthost_${1#agenthost-}";; ah-*) echo "ah_${1#ah-}";; *) echo "$1";; esac; }

# _find_helper <basename> — resolve a sibling script co-located first (repo/dev
# layout: <basename>.sh next to this script), then on PATH (deployed layout:
# flat copies in ~/.local/bin with the .sh dropped, see session-git-prep.sh's
# header comment for why). Prints the path and returns 0, or prints nothing and
# returns 1 — callers must fail SAFE on a miss (refuse, don't silently skip
# whatever the helper was gating).
_find_helper() {
  local base="$1" here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  if [ -f "$here/${base}.sh" ]; then printf '%s\n' "$here/${base}.sh"; return 0; fi
  if command -v "$base" >/dev/null 2>&1; then command -v "$base"; return 0; fi
  return 1
}

# ── worktree-stale / land-check shared helpers ────────────────────────────────
# Factored so both modes compute dirty/base/landed identically (item 5 reuses
# item 4's fixes rather than re-deriving them).

# _wt_dirty <worktree> -> "clean" | "DIRTY", ignoring the spawner's own
# baseline (the .claude/skills symlink new-session.sh creates in every run
# dir, plus .sessions-init-* sentinels) — mirrors session-git-prep.sh's own
# dirty check (same ignore regex) so a fresh, otherwise-untouched worktree
# doesn't look dirty just because the spawner touched it. Before this fix,
# EVERY worktree was reported DIRTY unconditionally.
_wt_dirty() {
  if git -C "$1" status --porcelain 2>/dev/null | grep -qvE '^.. (\.claude(/|$)|\.sessions-init)'; then
    echo DIRTY
  else
    echo clean
  fi
}

# _wt_mainrepo <worktree> -> absolute path to the worktree's main repo, from
# its (possibly relative, on older git) --git-common-dir.
_wt_mainrepo() {
  local common_dir
  common_dir="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || { echo ""; return; }
  case "$common_dir" in /*) : ;; *) common_dir="$1/$common_dir" ;; esac
  (cd "$common_dir/.." 2>/dev/null && pwd) || echo ""
}

declare -A _DEFBR_CACHE
# _default_branch <repo> -> the repo's REAL default branch name (no origin/
# prefix). Every git call here is -C-scoped to the given repo, never to $PWD or
# any other repo — a stale/decoy ref living in some OTHER repo on disk can
# never leak into this answer (the observed failure mode this -C scoping
# exists to prevent: a stale origin/main decoy in one repo made an unrelated
# fleet look unlanded).
#
# Resolution order is LOCAL-FIRST, not gh-first: `git symbolic-ref
# refs/remotes/origin/HEAD` (no network, set in most clones) is tried before
# ever shelling out to `gh`. This is a deliberate perf tradeoff, not an
# oversight — idle-report --tsv (this function's hottest caller, via
# _wt_landed/_tsv_git_status) is about to run unattended on an hourly systemd
# timer across every worktree's main repo; at up to N sequential 5s-timeout
# `gh repo view` network round-trips per run, that no longer scales. The
# accepted risk is a STALE local origin/HEAD (e.g. the upstream default
# branch was renamed after this clone's last `git remote set-head`/fetch
# --prune) silently disagreeing with GitHub's actual setting — narrow in
# practice, and fails toward the conservative side in _wt_landed (a wrong
# base ref tends to read as landed=no/unknown, i.e. "keep the worktree",
# never a false "safe to delete"). `gh` remains the fallback when there's no
# usable local origin/HEAD (repo has no remote, or a non-GitHub remote, or
# `gh` itself is absent/unauthenticated): origin/HEAD -> gh repo view -> local
# main -> local master -> current HEAD (same chain session-git-prep.sh uses
# for the same problem). `gh` is only ever tried against a github.com origin
# (never invoked for a local-path/other-host remote — keeps this fast and
# hermetic in tests) and bounded with `timeout` so a hung/unreachable network
# call can't stall a whole worktree scan.
_default_branch() {
  local repo="$1" def="" url slug
  if [ -n "${_DEFBR_CACHE[$repo]+x}" ]; then printf '%s\n' "${_DEFBR_CACHE[$repo]}"; return; fi
  if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    def="$(git -C "$repo" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
  fi
  if [ -z "$def" ] && command -v gh >/dev/null 2>&1 && url="$(git -C "$repo" remote get-url origin 2>/dev/null)"; then
    case "$url" in
      *github.com*)
        slug="$(printf '%s' "$url" | sed -E 's#^(git@github\.com:|https://github\.com/|git://github\.com/)##; s#\.git$##')"
        def="$(timeout 5 gh repo view "$slug" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)"
        ;;
    esac
  fi
  if [ -z "$def" ]; then
    if   git -C "$repo" show-ref --verify --quiet refs/heads/main;   then def=main
    elif git -C "$repo" show-ref --verify --quiet refs/heads/master; then def=master
    else
      # NOT `$(cmd 2>/dev/null || echo HEAD)`: on an unborn-HEAD repo (no
      # commits, no main/master) git can print "HEAD" to stdout AND still
      # exit non-zero, so the `||` fallback would ALSO fire and the
      # substitution would capture both — a literal "HEAD\nHEAD" (caught by
      # hand-testing this edge case). Check emptiness instead of exit status.
      def="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"
      [ -n "$def" ] || def="HEAD"
    fi
  fi
  _DEFBR_CACHE[$repo]="$def"
  printf '%s\n' "$def"
}

# _wt_landed <worktree> <mainrepo> -> "base=<branch> landed=yes|no|unknown".
# landed=yes means HEAD is already an ancestor of the real default branch (safe
# to forget about); unknown means neither origin/<default> nor a local
# <default> branch exists in this repo to compare against.
_wt_landed() {
  local wt="$1" mainrepo="$2" def base_ref landed
  def="$(_default_branch "$mainrepo")"
  if git -C "$wt" show-ref --verify --quiet "refs/remotes/origin/$def"; then
    base_ref="origin/$def"
  elif git -C "$wt" show-ref --verify --quiet "refs/heads/$def"; then
    base_ref="$def"
  else
    base_ref=""
  fi
  if [ -z "$base_ref" ]; then
    landed=unknown
  elif git -C "$wt" merge-base --is-ancestor HEAD "$base_ref" 2>/dev/null; then
    landed=yes
  else
    landed=no
  fi
  printf 'base=%s landed=%s\n' "$def" "$landed"
}

# ── reap worktree-removal helpers ───────────────────────────────────────────
# Factored out of `reap` so each guard is independently unit-testable (see
# tests/test-session-doctor-reap-worktree.sh), the same way _registry_delete_one
# is tested directly rather than only through the full `reap` dispatch (which
# would otherwise require going through session-preserve's own safety gate
# just to exercise a worktree-removal edge case).

# _is_caller_cwd <worktree> -> true if the CALLING process's own cwd is that
# worktree or somewhere under it. Removing the worktree a `reap` invocation is
# itself running from would pull the rug out from under the rest of the
# script (and anything else still running there).
_is_caller_cwd() {
  local wt="$1" wt_real pwd_real
  wt_real="$(cd "$wt" 2>/dev/null && pwd -P)" || return 1
  pwd_real="$(pwd -P)"
  case "$pwd_real" in
    "$wt_real"|"$wt_real"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# _wt_used_by_other_unit <worktree> <own_service> -> prints the blocking
# unit's filename and returns 0 if any systemd --user unit OTHER than
# <own_service> references <worktree>'s path — as WorkingDirectory, or
# anywhere in ExecStart (a flag value like --state-dir=<path>, not just a
# literal `ExecStart=<path>/...`) — including a drop-in override under
# <unit>.service.d/*.conf. Real case this guards against: a live session's
# worktree can go on being another unit's WorkingDirectory/--state-dir long
# after the SESSION that first created it is reaped (e.g.
# ah-bus-follower-v2-0919-0108, the WorkingDirectory/--state-dir of the live
# bus timers). A plain substring match on the whole unit file is deliberately
# used instead of parsing specific directive names — these generated unit
# files only ever contain [Unit]/[Service]/[Install] directives, so a path
# appearing anywhere in one is already a reference worth refusing over.
# Checks both the given path and its resolved realpath (a unit may reference
# either form), and for each of those also the systemd %h-relative form —
# %h expands to $HOME, and generated unit files may spell a home-relative
# path as %h/... instead of the literal $HOME/... (real case:
# bus-router-idle-reaper.service.d/state-dir.conf uses
# %h/.claude/worktrees/<name>/...). Returns 1 (nothing printed) if no other
# unit references it in any of these forms.
_wt_ref_in_file() {
  local f="$1" wt="$2" wt_real="$3" cand
  for cand in "$wt" "$wt_real"; do
    [ -n "$cand" ] || continue
    grep -qF "$cand" "$f" 2>/dev/null && return 0
    case "$cand" in
      "$HOME"/*) grep -qF "%h/${cand#"$HOME"/}" "$f" 2>/dev/null && return 0 ;;
    esac
  done
  return 1
}
_wt_used_by_other_unit() {
  local wt="$1" own="$2" wt_real f unit
  wt_real="$(cd "$wt" 2>/dev/null && pwd -P)" || wt_real="$wt"
  for f in "$UD"/*.service; do
    [ -f "$f" ] || continue
    unit="$(basename "$f")"
    [ "$unit" = "$own" ] && continue
    if _wt_ref_in_file "$f" "$wt" "$wt_real"; then
      printf '%s\n' "$unit"; return 0
    fi
  done
  for f in "$UD"/*.service.d/*.conf; do
    [ -f "$f" ] || continue
    unit="$(basename "$(dirname "$f")")"; unit="${unit%.d}"
    [ "$unit" = "$own" ] && continue
    if _wt_ref_in_file "$f" "$wt" "$wt_real"; then
      printf '%s\n' "$unit"; return 0
    fi
  done
  return 1
}

# _wt_resolve_for_base <base> -> absolute path of the ~/.claude/worktrees/
# dir owned by session <base>, or empty (return 1) if none. Prefers a BRANCH
# match (session/<base>) over a bare directory-name match — the same
# resolution order session-preserve.sh's worktree_of() and worktree-stale
# already use, and for the same reason (see their own comments, duplicated
# here rather than sourced, matching how every script in this repo is a
# standalone deployable file): session-git-prep.sh suffixes the worktree
# DIRECTORY with -$$ on a path collision while leaving the branch
# (session/<base>) unsuffixed, so a plain "$HOME/.claude/worktrees/$base"
# path join silently misses the real, suffixed worktree on a collision and
# would leave it behind forever (reap runs unattended on a schedule, with no
# other path back to it).
_wt_resolve_for_base() {
  local base="$1" dir="$HOME/.claude/worktrees" wt branch fallback=""
  [ -d "$dir" ] || return 1
  for wt in "$dir"/*/; do
    [ -d "$wt" ] || continue
    wt="${wt%/}"
    branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" || true
    if [ "$branch" = "session/$base" ]; then printf '%s\n' "$wt"; return 0; fi
    [ -z "$fallback" ] && [ "$(basename "$wt")" = "$base" ] && fallback="$wt"
  done
  if [ -n "$fallback" ]; then printf '%s\n' "$fallback"; return 0; fi
  return 1
}

# _reap_remove_worktree <base> <force:yes|no> — the worktree-removal step of
# `reap`, called as `_reap_remove_worktree "$base" "$FORCE"` unless
# --keep-worktree was given. Resolves the session's worktree via
# _wt_resolve_for_base (branch-first, so a PID-suffixed collision directory
# is still found — see its own comment). Finds the owning main repo via
# `git -C <wt> rev-parse --git-common-dir` (_wt_mainrepo, same helper
# worktree-stale/land-check use), then removes ONLY the worktree
# registration + directory — the branch (session/<base>, or whatever it was
# switched to) is NEVER deleted here.
#
# `git worktree remove` runs WITHOUT --force by default, so IT decides
# dirtiness (untracked/modified files) the same way it always has — reap does
# not re-derive that check. A refusal is reported and the worktree is left in
# place; it never fails the rest of reap (always returns 0). --force is
# passed through to `git worktree remove` ONLY when reap's own --force was
# given (force already means "skip the safety net"; leaving a known-dirty
# worktree half torn-down behind a force-reaped session would be a worse,
# more confusing outcome than force-removing it too).
#
# Guards, checked before ever calling `git worktree remove`, each one a
# refusal (worktree kept, nothing removed):
#  - no worktree found at that path at all -> "(ok)", not an error
#  - the resolved path IS the repo's primary checkout (defensive — should
#    never happen since this only ever looks under ~/.claude/worktrees, but
#    never risk running `worktree remove` against a non-worktree checkout)
#  - the CALLER's own cwd is that worktree (see _is_caller_cwd)
#  - any OTHER systemd user unit references it (see _wt_used_by_other_unit)
#
# `git worktree prune` runs on the main repo afterward regardless of outcome
# (bookkeeping only — never removes a directory still present on disk).
_reap_remove_worktree() {
  local base="$1" force="$2" wt mainrepo wt_real mainrepo_real own_unit blocking
  wt="$(_wt_resolve_for_base "$base")"
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    echo "  worktree: none found for '$base' (ok)"
    return 0
  fi
  mainrepo="$(_wt_mainrepo "$wt")"
  if [ -z "$mainrepo" ]; then
    echo "  worktree: $wt is not a git worktree (main repo unresolvable) — leaving in place" >&2
    return 0
  fi
  wt_real="$(cd "$wt" 2>/dev/null && pwd -P)"
  mainrepo_real="$(cd "$mainrepo" 2>/dev/null && pwd -P)"
  if [ -n "$wt_real" ] && [ "$wt_real" = "$mainrepo_real" ]; then
    echo "  worktree: $wt IS $mainrepo's primary checkout — refusing to remove"
    return 0
  fi
  if _is_caller_cwd "$wt"; then
    echo "  worktree: $wt is the caller's own working directory — refusing to remove"
    return 0
  fi
  own_unit="${base}.service"
  if blocking="$(_wt_used_by_other_unit "$wt" "$own_unit")"; then
    echo "  worktree: kept (in use by unit $blocking): $wt"
    return 0
  fi
  local -a rmargs=(worktree remove)
  [ "$force" = yes ] && rmargs+=(--force)
  rmargs+=("$wt")
  if git -C "$mainrepo" "${rmargs[@]}" >/dev/null 2>&1; then
    echo "  worktree removed (branch kept): $wt"
  else
    echo "  worktree: kept (git worktree remove refused — untracked/modified files?): $wt"
  fi
  git -C "$mainrepo" worktree prune >/dev/null 2>&1 || true
  return 0
}

declare -A _TSV_STATUS_CACHE
# _tsv_git_status <cwd> -> sets globals _TSV_LANDED/_TSV_DIRTY for idle-report
# --tsv columns 9/10 (landed: yes|no|unknown|no-worktree; dirty:
# clean|DIRTY|unknown). Reuses _wt_dirty/_wt_landed/_wt_mainrepo exactly as
# worktree-stale/land-check do — no reimplementation. "no-worktree"/"unknown"
# when cwd no longer exists on disk or git doesn't recognize it as a working
# tree at all (transcripts commonly outlive worktrees — see _history_footer
# below for the same problem).
#
# Cached per-cwd (mirrors the _DEFBR_CACHE idiom above _default_branch) so a
# cwd that repeats across multiple idle rows doesn't re-shell git for each
# one. Deliberately sets globals instead of printing a value for the caller
# to capture via `$(...)`: command substitution forks a subshell, and an
# associative-array write made inside that subshell is discarded the instant
# it exits — a `status="$(_tsv_git_status "$cwd")"` call site would silently
# repopulate an empty cache on every single row and never actually cache
# anything. Callers MUST invoke this directly (no `$(...)` wrapper) for the
# cache to have any effect.
_tsv_git_status() {
  local cwd="$1" mainrepo landedinfo
  if [ -n "${_TSV_STATUS_CACHE[$cwd]+x}" ]; then
    _TSV_LANDED="${_TSV_STATUS_CACHE[$cwd]%%$'\t'*}"
    _TSV_DIRTY="${_TSV_STATUS_CACHE[$cwd]#*$'\t'}"
    return
  fi
  if [ ! -d "$cwd" ] || ! git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _TSV_LANDED="no-worktree"; _TSV_DIRTY="unknown"
  else
    _TSV_DIRTY="$(_wt_dirty "$cwd")"
    mainrepo="$(_wt_mainrepo "$cwd")"
    if [ -n "$mainrepo" ]; then
      landedinfo="$(_wt_landed "$cwd" "$mainrepo")"
      _TSV_LANDED="${landedinfo#*landed=}"
    else
      _TSV_LANDED="unknown"
    fi
  fi
  _TSV_STATUS_CACHE[$cwd]="$_TSV_LANDED"$'\t'"$_TSV_DIRTY"
}

# ── history helpers ────────────────────────────────────────────────────────

# _encode_cwd <path> -> the ~/.claude/projects/<encoded> transcript-dir name
# for that cwd. Pure string transform (does NOT require the path to exist):
# '.' -> '-' FIRST, then '/' -> '-' (this order is load-bearing and already
# verified empirically for idle-report above — this is the same algorithm,
# just factored out so `history` can reuse it instead of re-deriving it).
_encode_cwd() {
  local p="$1"
  p="${p//./-}"
  printf '%s\n' "${p//\//-}"
}

# _history_matches <query> <wt_base> <proj_base> -> one matched worktree
# absolute path per line (may not exist on disk — transcripts outlive
# worktrees, see _history_report/_history_footer). <query> may be a bare
# folder name, an absolute path to the worktree (only its basename is used,
# so `.../worktrees/<name>` and `.../worktrees/<name>/` both work), or a
# repo-name substring.
#
# Candidate folder names come from TWO sources, unioned: (a) directories
# currently under <wt_base>, and (b) names recovered from every
# <proj_base>/<encoded> transcript dir by stripping the deterministic
# "<encode(wt_base)>-" prefix (safe: we only strip a known-constant prefix,
# we never try to invert the lossy '.'/'/' -> '-' collapse for the remainder)
# — so a substring/repo-name query still finds worktrees that were already
# removed from disk, not just live ones.
#
# Exact match (query's basename equals a candidate name exactly) wins outright;
# otherwise every candidate whose name CONTAINS the query substring is
# returned. Prints nothing and returns 1 when there is no match at all.
_history_matches() {
  local query="$1" wt_base="$2" proj_base="$3" qname d dn n prefix found=0 trimmed
  # A query that LOOKS like a path (contains a slash, or is exactly "." or
  # "..") and resolves to a real, existing directory is authoritative: use it
  # exactly as given (resolved to an absolute path) and skip name-based
  # matching entirely. Without this short-circuit, an absolute path whose
  # basename happens to be a substring of some unrelated worktree name (e.g.
  # a main-repo checkout that lives OUTSIDE ~/.claude/worktrees/, whose
  # basename is also a substring of a stale worktree dir like
  # "agenthost-<same-name>-<date>") gets silently hijacked by the substring
  # fallback below instead of matching the literal folder the caller named.
  # CONFIRMED: `history /home/agents/workspace/claude-remote-session-skill`
  # (a real, existing directory, NOT under wt_base) matched a long-deleted
  # `agenthost-claude-remote-session-skill-20260715-0630` worktree instead —
  # the basename-based substring search never even looked at whether the
  # literal path existed. A query that does NOT resolve to a real directory
  # (folder already deleted from disk, or a bare name/substring with no
  # slash) still falls through to the name-based search below exactly as
  # before, so PAST-only lookups by name are unaffected.
  case "$query" in
    */*|.|..)
      trimmed="${query%/}"
      [ -n "$trimmed" ] || trimmed="/"
      if [ -d "$trimmed" ]; then
        printf '%s\n' "$(cd "$trimmed" >/dev/null 2>&1 && pwd)"
        return 0
      fi
      qname="$(basename "$trimmed")"
      ;;
    *) qname="$query" ;;
  esac
  local -A seen=()
  local -a candidates=()
  for d in "$wt_base"/*/; do
    [ -d "$d" ] || continue
    n="$(basename "${d%/}")"
    [ -n "${seen[$n]+x}" ] && continue
    seen[$n]=1; candidates+=("$n")
  done
  prefix="$(_encode_cwd "$wt_base")-"
  if [ -d "$proj_base" ]; then
    for d in "$proj_base"/*/; do
      [ -d "$d" ] || continue
      dn="$(basename "${d%/}")"
      case "$dn" in
        "$prefix"*) n="${dn#"$prefix"}" ;;
        *) continue ;;
      esac
      [ -n "$n" ] || continue
      [ -n "${seen[$n]+x}" ] && continue
      seen[$n]=1; candidates+=("$n")
    done
  fi
  if [ "${#candidates[@]}" -gt 0 ]; then
    mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | sort)
  fi
  if [ -n "${seen[$qname]+x}" ]; then
    printf '%s\n' "$wt_base/$qname"
    return 0
  fi
  for n in "${candidates[@]}"; do
    case "$n" in
      *"$qname"*) printf '%s\n' "$wt_base/$n"; found=1 ;;
    esac
  done
  [ "$found" -eq 1 ]
}

# _history_report <worktree> <proj_base> — prints the NOW (live sessions with
# this exact cwd) and PAST (transcript history for this cwd) sections for one
# worktree. Report-only: reads /proc and transcript files, never sends keys,
# never kills, never writes anything.
#
# NOW is derived exactly the way idle-report (above) already does it — same
# `pgrep -af 'claude.*--remote-control'` + basename filter (also matches the
# tmux launcher and the bash supervisor loop, so keep only claude|node), same
# `readlink /proc/<pid>/cwd`, same svc_to_tmux name mapping — just filtered
# down to processes whose cwd is exactly this worktree, instead of every live
# session. A vanished pid mid-scan (empty readlink) is skipped, same as
# idle-report.
#
# PAST reads every <uuid>.jsonl in the transcript dir for this cwd. A process
# command line carries no session uuid, so a live pid can't be mapped to a
# specific transcript file directly; when a live session exists for this cwd
# we assume it is the writer of whichever transcript file here has the latest
# type:user timestamp (normally exactly one file is being actively written per
# cwd) and fold that file into NOW instead of also listing it under PAST — so
# the two sections cross-reference rather than double-count. This is a
# heuristic, not a guarantee; it is called out in the printed output.
_history_report() {
  local wt="$1" proj_base="$2" encoded tdir now_rows
  encoded="$(_encode_cwd "$wt")"
  tdir="$proj_base/$encoded"
  echo ""
  echo "--- $wt ---"
  now_rows="$(
    pgrep -af 'claude.*--remote-control' 2>/dev/null | while read -r pid cmd; do
      case "$(basename "$(printf '%s' "$cmd" | awk '{print $1}')")" in claude|node) ;; *) continue;; esac
      rc="$(printf '%s' "$cmd" | grep -oE -- '--remote-control[ =][^ ]+' | head -1 | sed -E 's/^--remote-control[ =]//')"
      [ -n "$rc" ] || continue
      tm="$(svc_to_tmux "$rc")"
      cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)"
      [ -n "$cwd" ] || continue
      [ "$cwd" = "$wt" ] || continue
      prot=no; printf '%s %s %s' "$rc" "$tm" "$cwd" | grep -qiE "$PROTECT" && prot=yes
      printf '%s\t%s\t%s\t%s\n' "$pid" "$rc" "$tm" "$prot"
    done
  )"
  python3 - "$tdir" "$now_rows" <<'PYEOF'
import sys, os, glob, json, datetime

tdir, now_raw = sys.argv[1], sys.argv[2]
now_rows = [l.split('\t') for l in now_raw.splitlines() if l.strip()]
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)

files = sorted(glob.glob(os.path.join(tdir, '*.jsonl')))
per_file = {}
dir_max_ts = None
for fn in files:
    uuid = os.path.basename(fn)
    if uuid.endswith('.jsonl'):
        uuid = uuid[:-6]
    first_ts = last_ts = None
    turns = 0
    try:
        size = os.path.getsize(fn)
    except OSError:
        size = 0
    try:
        with open(fn, encoding='utf-8', errors='ignore') as fh:
            for line in fh:
                if '"user"' not in line:            # cheap prefilter, same trick idle-report uses
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if o.get('type') != 'user':
                    continue
                ts = o.get('timestamp')
                if not ts:
                    continue
                turns += 1
                if first_ts is None or ts < first_ts:
                    first_ts = ts
                if last_ts is None or ts > last_ts:
                    last_ts = ts
    except OSError:
        pass                                          # transcript dir/file gone mid-scan — just skip it
    per_file[uuid] = {'first': first_ts, 'last': last_ts, 'turns': turns, 'size': size}
    if last_ts and (dir_max_ts is None or last_ts > dir_max_ts):
        dir_max_ts = last_ts

def human_size(n):
    n = float(n)
    for unit in ('B', 'K', 'M', 'G', 'T'):
        if n < 1024 or unit == 'T':
            return ('%d%s' % (n, unit)) if unit == 'B' else ('%.1f%s' % (n, unit))
        n /= 1024

print('  NOW — live session(s) with this cwd:')
if not now_rows:
    print('    (none)')
else:
    print('    %-30s %-30s %-8s %-9s %s' % ('TMUX SESSION', 'REMOTE-CONTROL NAME', 'PID', 'IDLE', 'PROT'))
    for pid, rc, tm, prot in now_rows:
        if dir_max_ts:
            try:
                dt = datetime.datetime.fromisoformat(dir_max_ts[:19])
                idle_s = '%dm' % int((now - dt).total_seconds() // 60)
            except Exception:
                idle_s = '?'
        else:
            idle_s = 'never'
        flag = '[P]' if prot == 'yes' else ''
        print('    %-30s %-30s %-8s %-9s %s' % (tm[:30], rc[:30], pid, idle_s, flag))

# See _history_report's comment above for why this cross-reference is a
# heuristic (no uuid on the process command line to match against directly).
live_uuid = None
if now_rows and dir_max_ts:
    for uuid, info in per_file.items():
        if info['last'] == dir_max_ts:
            live_uuid = uuid
            break

past = [u for u in per_file if u != live_uuid]
past.sort(key=lambda u: (per_file[u]['last'] or '', per_file[u]['first'] or ''))

print('')
print('  PAST — sessions that previously touched this folder (%s):' % tdir)
if not files:
    print('    (no transcript directory — no recorded sessions)')
elif not past:
    print('    (no PAST sessions%s)' % (' — only session here is the LIVE one above' if live_uuid else ''))
else:
    print('    %-10s %-21s %-21s %-6s %s' % ('SESSION', 'FIRST type:user', 'LAST type:user', 'TURNS', 'SIZE'))
    for uuid in past:
        info = per_file[uuid]
        first_s = (info['first'][:19] + 'Z') if info['first'] else '(none)'
        last_s = (info['last'][:19] + 'Z') if info['last'] else '(none)'
        print('    %-10s %-21s %-21s %-6d %s' % (uuid[:8], first_s, last_s, info['turns'], human_size(info['size'])))
if live_uuid:
    print('    [%s is LIVE now — see NOW section above, not double-counted here]' % live_uuid[:8])
print('  --- %d past session(s), %d live session(s) ---' % (len(past), len(now_rows)))
PYEOF
}

# _history_footer <worktree> — branch/landed/dirty + recent commits, reusing
# _wt_dirty/_wt_landed/_wt_mainrepo/_default_branch exactly as worktree-stale
# and land-check already do (no reimplementation). Handles a worktree that no
# longer exists on disk (transcripts outlive worktrees — the common case for a
# genuinely PAST session) by saying so instead of running git against a
# missing directory.
_history_footer() {
  local wt="$1" branch dirty mainrepo landedinfo logout
  echo ""
  echo "  worktree status:"
  if [ ! -d "$wt" ]; then
    echo "    worktree no longer exists on disk at $wt (history above is from transcripts only)"
    return 0
  fi
  branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  dirty="$(_wt_dirty "$wt")"
  mainrepo="$(_wt_mainrepo "$wt")"
  landedinfo="base=? landed=unknown"
  [ -n "$mainrepo" ] && landedinfo="$(_wt_landed "$wt" "$mainrepo")"
  printf '    branch=%s status=%s %s\n' "$branch" "$dirty" "$landedinfo"
  echo "    git log --oneline -5:"
  logout="$(git -C "$wt" log --oneline -5 2>/dev/null)"
  if [ -n "$logout" ]; then
    printf '%s\n' "$logout" | sed 's/^/      /'
  else
    echo "      (no commits)"
  fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
case "$MODE" in
  report)
    echo "=== LOCAL: tmux sessions ==="
    for s in $(live_tmux); do
      alive=$(proc_alive "$s" && echo yes || echo NO-PROC)
      prot=$(echo "$s" | grep -qiE "$PROTECT" && echo " [PROTECTED]" || true)
      printf "  %-52s proc=%s%s\n" "$s" "$alive" "$prot"
    done
    echo "=== LOCAL: systemd units without a live tmux (orphans) ==="
    for u in $(ls "$UD" 2>/dev/null | grep -E '^(agenthost|ah)-.*\.service$'); do
      base="${u%.service}"; tm="$(svc_to_tmux "$base")"
      live_tmux | grep -qx "$tm" || echo "  ORPHAN unit: $u"
    done
    echo "=== REGISTRY: staleness summary ==="
    registry_json | python3 -c "
import sys,json,datetime
try: arr=json.load(sys.stdin)
except: print('  (registry unavailable)'); sys.exit()
arr=arr if isinstance(arr,list) else arr.get('sessions',arr.get('data',[]))
from collections import Counter
now=datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
def agedays(s):
    try: return (now-datetime.datetime.fromisoformat((s.get('updated_at') or s.get('created_at'))[:19])).days
    except: return -1
disc=[s for s in arr if s.get('connection_status')=='disconnected']
zomb=[s for s in arr if s.get('connection_status')=='connected' and agedays(s)>7]
print('  total=%d  connected=%d  disconnected=%d' % (len(arr),
      sum(1 for s in arr if s.get('connection_status')=='connected'), len(disc)))
print('  disconnected >%dd (reapable): %d' % (30, sum(1 for s in disc if agedays(s)>30)))
print('  \"connected\" but >7d (likely zombies): %d' % len(zomb))
print('  session_status:', dict(Counter(s.get('session_status') for s in arr)))
"
    ;;

  reap-local)
    [ "$FORCE" = yes ] || echo "(DRY-RUN — re-run with --force to actually reap)"
    do_reap() {  # $1=tmux-name-or-empty $2=service $3=start-script
      if [ "$FORCE" = yes ]; then
        systemctl --user disable --now "$2" >/dev/null 2>&1 || true
        [ -n "$UD" ] && [ -f "$UD/$2" ] && rm -f "$UD/$2"
        [ -n "$UD" ] && [ -L "$UD/default.target.wants/$2" ] && rm -f "$UD/default.target.wants/$2"
        [ -n "$BIN" ] && [ -n "$3" ] && [ -f "$BIN/$3" ] && rm -f "$BIN/$3"
        [ -n "$1" ] && tmux kill-session -t "$1" 2>/dev/null || true
      fi
    }
    reaped=0
    # 1. tmux sessions whose claude proc is gone (skip protected).
    for s in $(live_tmux); do
      echo "$s" | grep -qiE "$PROTECT" && continue
      base="$(tmux_to_base "$s")"; [ -z "$base" ] && continue   # not ours (e.g. codexhost_) → leave it
      proc_alive "$s" && continue                                # alive → keep
      echo "DEAD tmux (no claude proc): $s"
      do_reap "$s" "${base}.service" "${base}-start.sh"
      reaped=$((reaped+1))
    done
    # 2. orphaned systemd units (no live tmux for them). These units are
    # Type=oneshot/RemainAfterExit=yes (see new-session.sh) — once ExecStart
    # finishes, systemd holds them "active (exited)" indefinitely regardless
    # of what later happens to the tmux session they spawned, so an is-active
    # check here would almost never be false and would skip real orphans
    # (the exact case this loop exists to reap). Same liveness definition as
    # `report`'s ORPHAN listing above: no live tmux match.
    for u in $(ls "$UD" 2>/dev/null | grep -E '^(agenthost|ah)-.*\.service$'); do
      echo "$u" | grep -qiE "$PROTECT" && continue
      base="${u%.service}"; tm="$(svc_to_tmux "$base")"
      live_tmux | grep -qx "$tm" && continue
      echo "ORPHAN unit (no tmux): $u"
      do_reap "" "$u" "${base}-start.sh"
      reaped=$((reaped+1))
    done
    [ "$FORCE" = yes ] && systemctl --user daemon-reload >/dev/null 2>&1 || true
    echo "$([ "$FORCE" = yes ] && echo reaped || echo would-reap) $reaped dead local item(s)"
    ;;

  registry-stale)
    echo "=== registry sessions disconnected > ${DAYS}d (deletion candidates; NOT auto-deleted) ==="
    if ! out=$(registry_json | _registry_candidates "$DAYS"); then
      echo "  (registry unavailable)"
    else
      n=0
      while IFS=$'\t' read -r id age status title; do
        [ -z "$id" ] && continue
        printf '  %s  age=%3dd  status=%-9s  %s\n' "$id" "$age" "$status" "${title:0:40}"
        n=$((n+1))
      done <<< "$out"
      echo "  --- $n candidate(s). To delete one (VERIFY FIRST): ---"
      echo "  curl -X DELETE https://api.anthropic.com/v1/sessions/<ID> \\"
      echo "    -H \"Authorization: Bearer \$TOKEN\" -H \"x-organization-uuid: \$ORG\" \\"
      echo "    -H \"anthropic-version: 2023-06-01\" -H \"anthropic-beta: ccr-byoc-2025-07-29\""
    fi
    ;;

  registry-prune)
    # Automated form of registry-stale's candidate set (see _registry_candidates
    # above — reused, not re-derived): registry sessions disconnected > ${DAYS}d.
    # Default is a dry run (no mutation, "would-delete" preview); --apply performs
    # the DELETEs, via the same _registry_delete_one helper `reap`'s registry
    # cleanup uses. This is the standard/automatable replacement for the
    # hand-run curl registry-stale prints — see its header comment above.
    echo "=== registry-prune: sessions disconnected > ${DAYS}d ($([ "$APPLY" = yes ] && echo APPLY || echo DRY-RUN)) ==="
    if ! cand_out=$(registry_json | _registry_candidates "$DAYS"); then
      echo "  (registry unavailable)"
      exit 1
    fi
    # Live tmux session names, converted to the hyphenated base form registry
    # titles use (tmux_to_base — the same conversion `report`/`reap-local` use
    # above), so "any entry whose name matches a live tmux session" compares
    # like-for-like instead of a fresh ad hoc string comparison.
    live_bases=""
    for s in $(live_tmux); do
      b="$(tmux_to_base "$s")"
      [ -n "$b" ] && live_bases="$live_bases$b"$'\n'
    done
    n_del=0; n_skip=0; n_fail=0
    while IFS=$'\t' read -r id age status title; do
      [ -z "$id" ] && continue
      if _title_protected "$title"; then
        echo "  skipped(protected)  $id  $title"
        n_skip=$((n_skip+1)); continue
      fi
      if printf '%s' "$live_bases" | grep -qxF "$title"; then
        echo "  skipped(live-tmux)  $id  $title"
        n_skip=$((n_skip+1)); continue
      fi
      # requires_action is ALWAYS skipped here (never auto-deleted — it may
      # need a human decision) regardless of age; a row stale beyond 2xDAYS
      # just gets a louder, distinct message so it surfaces for review instead
      # of blending into the ordinary skip line.
      if [ "$status" = "requires_action" ]; then
        if [ "$age" -gt $((2*DAYS)) ]; then
          echo "  skipped(requires_action, age=${age}d > $((2*DAYS))d — needs operator review)  $id  $title"
        else
          echo "  skipped(requires_action)  $id  $title"
        fi
        n_skip=$((n_skip+1)); continue
      fi
      if [ "$APPLY" != yes ]; then
        echo "  would-delete  $id  age=${age}d  $title"
        n_del=$((n_del+1)); continue
      fi
      if _registry_delete_one "$id" "$title"; then n_del=$((n_del+1)); else n_fail=$((n_fail+1)); fi
    done <<< "$cand_out"
    echo "  --- $([ "$APPLY" = yes ] && echo deleted || echo would-delete)=$n_del skipped=$n_skip failed=$n_fail ---"
    if [ "$n_fail" -gt 0 ]; then
      exit 1
    fi
    ;;

  worktree-stale)
    echo "=== ~/.claude/worktrees/ dirs with no live owning session (NOT auto-removed) ==="
    WT_BASE="$HOME/.claude/worktrees"
    cand=0; kept=0
    for wt in "$WT_BASE"/*/; do
      [ -d "$wt" ] || continue
      wt="${wt%/}"
      branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
      # Prefer the session name embedded in the branch (session/<remote>) over the
      # worktree DIRECTORY name: session-git-prep suffixes the directory with -$$ on
      # a path collision while leaving the branch (and so the real owning tmux
      # session) unsuffixed. Deriving liveness from the directory name in that case
      # would misread a LIVE session's worktree as dead and offer to force-remove it.
      case "$branch" in
        session/*) owned=yes; remote="${branch#session/}" ;;
        *)         owned=no;  remote="$(basename "$wt")" ;;
      esac
      echo "$remote" | grep -qiE "$PROTECT" && continue
      tm="$(svc_to_tmux "$remote")"
      # Owning session still live (tmux present AND its claude proc running)? Keep it.
      if [ -n "$tm" ] && live_tmux | grep -qx "$tm" && proc_alive "$tm"; then
        continue
      fi
      cand=$((cand+1))
      dirty="$(_wt_dirty "$wt")"
      # Resolve the main repo this worktree belongs to, so the removal command
      # below is copy-pasteable without the reviewer having to hunt for the
      # repo, and so landed-ness can be checked against its REAL default
      # branch (not an assumed "main") — see _default_branch/_wt_landed above.
      mainrepo="$(_wt_mainrepo "$wt")"
      landedinfo="base=? landed=unknown"
      [ -n "$mainrepo" ] && landedinfo="$(_wt_landed "$wt" "$mainrepo")"
      printf '  %-60s branch=%-30s status=%-6s %s\n' "$wt" "$branch" "$dirty" "$landedinfo"
      # Same guard `reap` applies (_reap_remove_worktree): a worktree any OTHER
      # systemd --user unit still references is never offered for removal — the
      # printed `remove:` line is what gets pasted. The dead session's own unit
      # (${remote}.service, derived exactly as reap derives own_unit from <base>)
      # doesn't count: it goes away with the session.
      if blocking="$(_wt_used_by_other_unit "$wt" "${remote}.service")"; then
        printf '    KEEP: in use by unit %s — do not remove\n' "$blocking"
        kept=$((kept+1))
      elif [ -n "$mainrepo" ]; then
        # %q shell-quotes each value so the printed command is safe to copy-paste
        # even if a path or branch name contains whitespace or shell metacharacters.
        q_main="$(printf '%q' "$mainrepo")"; q_wt="$(printf '%q' "$wt")"
        if [ "$owned" = yes ]; then
          # `branch -D` only for a known-landed branch (landed=yes; unknown counts
          # as not known). The session/* ref is what keeps a dead session's commits
          # reachable once the worktree is gone — `reap` never deletes it either.
          # A squash-merged branch reads landed=no (ancestry check): that costs a
          # suggestion, never a wrong delete.
          if [ "${landedinfo#*landed=}" = yes ]; then
            q_branch="$(printf '%q' "$branch")"
            printf '    remove: git -C %s worktree remove --force %s && git -C %s branch -D %s\n' "$q_main" "$q_wt" "$q_main" "$q_branch"
          else
            printf '    remove: git -C %s worktree remove --force %s\n' "$q_main" "$q_wt"
            printf '    NOTE: branch %s is not known-landed — keep the ref; it is the only thing keeping its commits reachable\n' "$branch"
          fi
        else
          # Current branch isn't the session-owned session/<remote> name (the
          # session switched branches) — only suggest removing the worktree
          # itself; force-deleting an arbitrary, possibly-unmerged branch here
          # would risk destroying work unrelated to session cleanup.
          printf '    remove: git -C %s worktree remove --force %s\n' "$q_main" "$q_wt"
          printf '    NOTE: current branch %s is not a session/* name — leaving branch cleanup for manual review\n' "$branch"
        fi
      fi
    done
    keepnote=""
    [ "$kept" -gt 0 ] && keepnote=", $kept KEEP (in use by a systemd unit — no removal command printed)"
    echo "  --- $cand candidate(s)$keepnote. VERIFY dirty/unpushed work is not needed before removing. ---"
    ;;
  idle-report)
    # Report-only (mirrors registry-stale): LIVE local claude sessions with no
    # GENUINE user turn in the last N days (default 2 = today/yesterday) or N
    # minutes (--minutes; mutually exclusive with --days — enforced in the
    # flag-parsing block above). NEVER kills. Every row is a still-ALIVE proc,
    # so reap-local deliberately won't touch it — feed dead ones to reap-local,
    # reap an idle-but-alive one by hand.
    #
    # "Genuine" turn: ordinary tool-result turns (also type:"user" in Claude
    # Code transcripts) DO count as activity — a session looping on its own
    # counts as active and stays off this list, intentionally (documented in
    # docs/idle-report.md). The one type:"user" entry that does NOT count is a
    # /compact summary itself (isCompactSummary:true): if that counted, a
    # freshly-compacted session would look freshly active, drift back into the
    # idle window roughly one compaction cycle later, and get compacted again
    # forever. So idle here is measured from the last type:"user" entry that is
    # NOT a compact summary. Protected names are flagged and must never be
    # reaped.
    #
    # --tsv emits one machine-readable row per still-idle session — 10 tab-
    # separated columns (tmux_session, remote_name, pid, cwd, idle_minutes,
    # last_genuine_user_ts, protected, compacted_since_last_turn, landed,
    # dirty), no header, no summary/footer lines — for an actuator script to
    # consume with `while IFS=$'\t' read -r ...`. Columns 9/10 (landed/dirty)
    # reuse _wt_landed/_wt_dirty exactly as worktree-stale/land-check do (via
    # _tsv_git_status above); a cwd that's gone from disk or was never a git
    # working tree reports no-worktree/unknown there instead of failing the row
    # (transcripts commonly outlive worktrees).
    if [ "$TSV" != yes ]; then
      if [ "$MINUTES_SET" = yes ]; then
        if [ "$MINUTES" -gt 0 ] 2>/dev/null; then
          echo "=== LOCAL: live sessions with NO genuine user turn in the last ${MINUTES} minute(s) — REPORT ONLY, kills nothing ==="
        else
          echo "=== LOCAL: ALL live sessions, no threshold (--minutes 0) — REPORT ONLY, kills nothing ==="
        fi
      else
        if [ "$DAYS" -gt 0 ] 2>/dev/null; then
          echo "=== LOCAL: live sessions with NO type:user message in the last ${DAYS} day(s) — REPORT ONLY, kills nothing ==="
        else
          echo "=== LOCAL: ALL live sessions, no threshold (--days 0) — REPORT ONLY, kills nothing ==="
        fi
      fi
    fi
    PY_TSV=False; [ "$TSV" = yes ] && PY_TSV=True
    PY_MINUTES=None; [ "$MINUTES_SET" = yes ] && PY_MINUTES="$MINUTES"
    {
      # Enumerate LIVE claude --remote-control procs. pgrep -f also matches the
      # tmux launcher and the bash supervisor loop (both carry the string in
      # their args), so keep only rows whose executable basename is the claude
      # binary itself.
      pgrep -af 'claude.*--remote-control' | while read -r pid cmd; do
        case "$(basename "$(printf '%s' "$cmd" | awk '{print $1}')")" in claude|node) ;; *) continue;; esac
        rc="$(printf '%s' "$cmd" | grep -oE -- '--remote-control[ =][^ ]+' | head -1 | sed -E 's/^--remote-control[ =]//')"
        [ -n "$rc" ] || continue
        tm="$(svc_to_tmux "$rc")"                       # reuse existing name mapping
        cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)"
        [ -n "$cwd" ] || continue                       # proc vanished mid-scan
        prot=no; printf '%s %s %s' "$rc" "$tm" "$cwd" | grep -qiE "$PROTECT" && prot=yes
        printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$rc" "$tm" "$cwd" "$prot"
      done
    } | python3 -c "
import sys, os, glob, json, datetime
DAYS = $DAYS
MINUTES = $PY_MINUTES
TSV = $PY_TSV
home = os.path.expanduser('~')
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
if MINUTES is not None:
    cutoff = (now - datetime.timedelta(minutes=MINUTES)) if MINUTES > 0 else None
else:
    cutoff = (now - datetime.timedelta(days=DAYS)) if DAYS > 0 else None

# The only Claude Code build empirically verified (on this host) to emit a
# type:system/subtype:compact_boundary entry (with a compactMetadata object)
# for a completed /compact is 2.1.206. The true minimum version this shipped
# in is unknown, so rather than guess a lower bound, only a transcript whose
# highest seen 'version' is >= this exact verified build is treated as
# 'version-aware' (making an absence a real 'no'); anything older, unparseable,
# or missing a version entirely reports 'unknown' rather than a guessed 'no'.
MIN_COMPACT_AWARE_VERSION = (2, 1, 206)

def parse_version(v):
    try:
        parts = [int(x) for x in str(v).split('.')[:3]]
    except Exception:
        return None
    if not parts:
        return None
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts)

rows, seen = [], set()
for line in sys.stdin:
    line = line.rstrip('\n')
    if not line: continue
    f = line.split('\t')
    if len(f) < 5: continue
    pid, rc, tm, cwd, prot = f[0], f[1], f[2], f[3], f[4]
    key = tm or rc
    if key in seen: continue
    seen.add(key)
    # cwd -> ~/.claude/projects/<encoded> transcript dir (verified empirically,
    # incl. dotted paths: '.'-> '-' then '/'-> '-').
    d = os.path.join(home, '.claude', 'projects', cwd.replace('.', '-').replace('/', '-'))
    files = glob.glob(os.path.join(d, '*.jsonl'))
    genuine_mx = None    # max ts over type:user entries that are NOT a /compact summary
    compact_mx = None    # max ts over type:system/subtype:compact_boundary entries
    ver_mx = None         # highest 'version' field seen on any entry read below
    for fn in files:
        try:
            for l in open(fn, encoding='utf-8', errors='ignore'):
                # Cheap prefilter before json.loads (same trick the rest of
                # this file uses): an ordinary type:user line always contains
                # the literal substring \"user\"; a compact_boundary line does
                # NOT (its only 'user'-ish key is userType, which doesn't
                # match the quoted-literal check) but always carries its
                # subtype name verbatim — check both in the one pass instead
                # of adding a second scan over the same files.
                if '\"user\"' not in l and 'compact_boundary' not in l:
                    continue
                try: o = json.loads(l)
                except Exception: continue
                v = o.get('version')
                if v:
                    vt = parse_version(v)
                    if vt and (ver_mx is None or vt > ver_mx): ver_mx = vt
                t = o.get('type')
                if t == 'user':
                    if o.get('isCompactSummary'):
                        continue   # the /compact write itself is not genuine activity
                    # A completed /compact leaves THREE MORE type:user artifacts
                    # in the transcript beyond the isCompactSummary write above,
                    # and none of them is genuine activity either. Confirmed
                    # against two REAL sweep --apply runs on this host
                    # (2026-09-11): excluding only isCompactSummary was NOT
                    # enough to fix the resulting idle-reset bug, because the
                    # /compact keystroke itself is EARLIER than these three, so
                    # it was never the max timestamp — these three were:
                    #   1. an isMeta:true local-command-caveat wrapper Claude
                    #      Code re-emits for ANY local slash command, not just
                    #      /compact.
                    #   2. the command-name echo of /compact itself.
                    #   3. the local-command-stdout line Claude Code writes once
                    #      compaction finishes (reads 'Compacted ...'). This one
                    #      lands LAST and LATEST of the four, so it — not 1 or 2
                    #      — is what actually dominated genuine_mx pre-fix.
                    # Also excluded: the bare '/compact' keystroke that triggers
                    # the whole cascade (see below).
                    #
                    # isMeta is excluded UNCONDITIONALLY (any command, not just
                    # /compact): it is pure caveat boilerplate, and excluding it
                    # loses no human-presence signal, because Claude Code writes
                    # a sibling command-name echo (kept as genuine here) at
                    # essentially the same timestamp for every OTHER command —
                    # confirmed against a real /clear in a live transcript.
                    #
                    # The command-name echo, the bare trigger, and the stdout
                    # line are, by contrast, excluded ONLY when tied to /compact
                    # specifically. Do NOT generalize this to 'any command-name
                    # echo' or 'any bare slash command' or 'any local-command-
                    # stdout': a human typing /clear, /context, /model, etc. is
                    # real evidence of presence, and blanket-excluding those
                    # would push toward compacting a session someone is
                    # actively using — the dangerous direction. (/model and
                    # /login were both observed emitting their own
                    # local-command-stdout line on this host; an un-scoped
                    # 'starts with local-command-stdout' exclusion would have
                    # swallowed those genuine turns too.)
                    #
                    # The bare-trigger match is EXACT ('/compact', stripped),
                    # not a prefix match: a real transcript on this host holds
                    # a genuine chat message '/compact handoff first' that is
                    # NOT a command invocation (no caveat/echo/stdout cascade
                    # follows it) — a prefix match would have wrongly swallowed
                    # that real human turn.
                    if o.get('isMeta'):
                        continue
                    msg = o.get('message') or {}
                    content = msg.get('content')
                    if not isinstance(content, str):
                        content = ''
                    if content.startswith('<command-name>/compact</command-name>'):
                        continue
                    if content.strip() == '/compact':
                        continue
                    # ANSI dim styling (e.g. ESC[2m) sits between the tag and
                    # 'Compacted' on a real capture, so match within a short
                    # window after the tag rather than requiring adjacency.
                    if content.startswith('<local-command-stdout>') and 'Compacted' in content[:64]:
                        continue
                    ts = o.get('timestamp')
                    if ts and (genuine_mx is None or ts > genuine_mx): genuine_mx = ts
                elif t == 'system' and o.get('subtype') == 'compact_boundary':
                    ts = o.get('timestamp')
                    if ts and (compact_mx is None or ts > compact_mx): compact_mx = ts
        except Exception: pass
    mx = genuine_mx
    if mx is None:
        # 'never messaged' — distinguish no-transcript from present-but-no-user.
        state = 'never: no transcript' if not files else 'never: no user msgs'
        mxdt = None
    else:
        state = mx[:19] + 'Z'
        try: mxdt = datetime.datetime.fromisoformat(mx[:19])
        except Exception: mxdt = None
    if cutoff is not None and mxdt is not None and mxdt >= cutoff:
        continue                                          # had a genuine turn within the window -> not idle
    idle_field = str(int((now - mxdt).total_seconds() // 60)) if mxdt is not None else 'never'
    last_ts_field = (mx[:19] + 'Z') if mx else '-'
    if compact_mx is not None and (genuine_mx is None or compact_mx > genuine_mx):
        compacted = 'yes'
    elif ver_mx is not None and ver_mx >= MIN_COMPACT_AWARE_VERSION:
        compacted = 'no'
    else:
        compacted = 'unknown'
    rows.append((mxdt, state, cwd, prot, pid, rc, tm, idle_field, last_ts_field, compacted))
# oldest-first: 'never' (mxdt None) first, then ascending timestamp.
rows.sort(key=lambda r: (r[0] is not None, r[0] or datetime.datetime.min))

if TSV:
    for mxdt, state, cwd, prot, pid, rc, tm, idle_field, last_ts_field, compacted in rows:
        print('\t'.join([tm, rc, pid, cwd, idle_field, last_ts_field, prot, compacted]))
else:
    print('  %-22s %-5s %-46s %s' % ('LAST type:user', 'PROT', 'TMUX SESSION', 'CWD'))
    nprot = 0
    for mxdt, state, cwd, prot, pid, rc, tm, idle_field, last_ts_field, compacted in rows:
        if prot == 'yes': nprot += 1
        print('  %-22s %-5s %-46s %s' % (state[:22], ('[P]' if prot == 'yes' else ''), tm[:46], cwd))
    print('  --- %d idle session(s)%s. All are ALIVE -> reap-local will NOT touch them.' % (
          len(rows), (', incl. %d PROTECTED (never reap)' % nprot) if nprot else ''))
    print('  Report only. Reap an idle-but-alive one by hand:')
    print('    tmux kill-session -t <name> ; systemctl --user disable --now <name>.service')
" | {
      if [ "$TSV" = yes ]; then
        while IFS=$'\t' read -r tmux_session remote_name pid cwd idle_minutes last_ts prot compacted; do
          [ -n "$tmux_session" ] && [ -n "$cwd" ] || continue
          # Called directly (NOT via `$(...)`) so _TSV_STATUS_CACHE's writes
          # land in THIS while loop's own subshell and actually persist across
          # iterations — see _tsv_git_status's comment above for why a
          # command-substitution call site would silently defeat the cache.
          _tsv_git_status "$cwd"
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$tmux_session" "$remote_name" "$pid" "$cwd" "$idle_minutes" "$last_ts" "$prot" "$compacted" "$_TSV_LANDED" "$_TSV_DIRTY"
        done
      else
        cat
      fi
    }
    ;;

  reap)
    # One-shot clean teardown of a named ALIVE session — the missing live
    # counterpart to reap-local (which only handles sessions whose claude proc
    # is already gone). Idempotent: a missing tmux session or a missing/never-
    # installed systemd unit does not fail the rest of the teardown.
    NAME="${1:?usage: session-doctor.sh reap <tmux-session> [--force]}"
    echo "$NAME" | grep -qiE "$PROTECT" && { echo "session-doctor: refusing to reap PROTECTED session '$NAME'" >&2; exit 2; }
    # Safety gate: refuse a session with unlanded/uncommitted work unless
    # --force. Reuses session-preserve.sh's own audit (exit 0 = safe to reap)
    # rather than re-deriving dirty/unpushed/reachability logic here. If the
    # helper can't be found at all, fail SAFE (refuse) rather than silently
    # skip the check.
    if [ "$FORCE" != yes ]; then
      SP="$(_find_helper session-preserve)" || {
        echo "session-doctor: REFUSING to reap '$NAME' — could not locate session-preserve to check for unlanded work (looked next to this script and on PATH). Re-run with --force to skip the safety check." >&2
        exit 1
      }
      if ! bash "$SP" "$NAME"; then
        echo "" >&2
        echo "REFUSING to reap '$NAME': unlanded/uncommitted work detected (see session-preserve output above)." >&2
        echo "  Rescue first: session-preserve $NAME --rescue --wip   (then re-run reap)" >&2
        echo "  Or force through data loss: session-doctor reap $NAME --force" >&2
        exit 1
      fi
    fi
    base="$(tmux_to_base "$NAME")"
    tmux kill-session -t "$NAME" 2>/dev/null \
      && echo "  tmux session killed: $NAME" || echo "  no live tmux session '$NAME' (ok)"
    if [ -n "$base" ]; then
      systemctl --user disable --now "${base}.service" >/dev/null 2>&1 \
        && echo "  unit disabled: ${base}.service" || echo "  unit '${base}.service' not active/installed (ok)"
      systemctl --user reset-failed "${base}.service" >/dev/null 2>&1 || true
    else
      echo "  '$NAME' is not an ah_/agenthost_ session — no systemd unit to tear down" >&2
    fi
    echo "reaped '$NAME'"
    # Registry cleanup: this session's registry entry (matched by title ==
    # base name — the hyphenated "ah-..."/"agenthost-..." form the registry
    # uses for a remote-control session's title, confirmed against a live
    # pull) is deleted too, unless --keep-registry. Fails soft: an
    # unreachable or unparsable registry only prints a note here and never
    # changes reap's own exit status — the teardown above already succeeded,
    # and that's what reap promises regardless of registry hygiene.
    if [ "$KEEP_REGISTRY" != yes ] && [ -n "$base" ]; then
      if reg_json=$(registry_json); then
        match_id=$(printf '%s' "$reg_json" | python3 -c "
import sys,json
try:
    arr=json.load(sys.stdin)
except Exception:
    sys.exit(1)
arr=arr if isinstance(arr,list) else arr.get('sessions',arr.get('data',[]))
target=sys.argv[1]
for s in arr:
    if (s.get('title') or '')==target:
        print(s.get('id')); break
" "$base" 2>/dev/null)
        if [ -n "$match_id" ]; then
          _registry_delete_one "$match_id" "$base"
        else
          echo "  registry: no entry found for '$base' (ok)"
        fi
      else
        echo "  registry: unreachable — leaving any registry entry for '$base' in place (reap still counts as done)" >&2
      fi
    fi
    # Worktree cleanup: the session's own ~/.claude/worktrees/<base> git
    # worktree (created by session-git-prep.sh for a dirty/busy repo) is
    # removed too, unless --keep-worktree — see _reap_remove_worktree's own
    # header comment for the full guard list (dirty refusal, in-use-by-
    # another-unit, caller's own cwd, primary checkout). Never fails the rest
    # of reap; the branch is never deleted.
    if [ "$KEEP_WORKTREE" != yes ] && [ -n "$base" ]; then
      _reap_remove_worktree "$base" "$FORCE"
    fi
    ;;

  land-check)
    # Per session-worktree, report-only: unlanded-vs-correct-base + real-dirty,
    # reusing worktree-stale's two fixes (baseline-aware dirty, real default
    # branch). Unlike worktree-stale (removal candidates for DEAD worktrees
    # only), this audits EVERY worktree regardless of whether its owning
    # session is still live — a "will I lose this?" check, not a cleanup list.
    # No mutation.
    echo "=== ~/.claude/worktrees/ land-check: unlanded-vs-correct-base + real-dirty (report-only) ==="
    WT_BASE="$HOME/.claude/worktrees"
    n=0
    for wt in "$WT_BASE"/*/; do
      [ -d "$wt" ] || continue
      wt="${wt%/}"
      n=$((n+1))
      branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
      dirty="$(_wt_dirty "$wt")"
      mainrepo="$(_wt_mainrepo "$wt")"
      landedinfo="base=? landed=unknown"
      [ -n "$mainrepo" ] && landedinfo="$(_wt_landed "$wt" "$mainrepo")"
      printf '  %-60s branch=%-30s status=%-6s %s\n' "$wt" "$branch" "$dirty" "$landedinfo"
    done
    echo "  --- $n worktree(s) checked. Report only; see worktree-stale for removal candidates + commands. ---"
    ;;

  history)
    # Report-only: "what happened here before me, and who else is working here
    # right now?" for a worktree folder. <foldername> may be a bare name, an
    # absolute path, or a repo-name substring (see _history_matches). Every
    # match is printed: NOW (live sessions, via _history_report — same
    # pgrep/readlink/svc_to_tmux mechanism idle-report uses), PAST (transcript
    # history, also via _history_report), then a worktree-status footer (via
    # _history_footer, reusing _wt_dirty/_wt_landed — no reimplementation).
    # WT_BASE/PROJ_BASE come from $HOME exactly like every other mode here, so
    # the existing HOME-override convention (see idle-report/worktree-stale/
    # land-check tests) is all that's needed to sandbox this in tests too.
    NAME="${1:?usage: session-doctor.sh history <foldername|path|repo-substring>}"
    WT_BASE="$HOME/.claude/worktrees"
    PROJ_BASE="$HOME/.claude/projects"
    mapfile -t MATCHES < <(_history_matches "$NAME" "$WT_BASE" "$PROJ_BASE")
    if [ "${#MATCHES[@]}" -eq 0 ]; then
      echo "session-doctor: no worktree matches '$NAME' under $WT_BASE (checked live worktree dirs, transcript history, and repo-name substrings)" >&2
      exit 2
    fi
    echo "=== history: ${#MATCHES[@]} worktree(s) matching '$NAME' ==="
    for wt in "${MATCHES[@]}"; do
      _history_report "$wt" "$PROJ_BASE"
      _history_footer "$wt"
    done
    ;;
  *) echo "usage: session-doctor.sh [report|reap-local|reap <name> [--force] [--keep-registry] [--keep-worktree]|registry-stale [--days N]|registry-prune [--days N] [--apply]|worktree-stale|land-check|idle-report [--days N|--minutes N] [--tsv]|history <foldername>]" >&2; exit 2;;
esac
fi
