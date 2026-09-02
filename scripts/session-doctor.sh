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
#   session-doctor.sh reap <name> [--force]       # one-shot teardown of a named ALIVE session (tmux+unit); refuses on unlanded work unless --force
#   session-doctor.sh registry-stale [--days N]   # list registry sessions disconnected > N days (default 30)
#   session-doctor.sh worktree-stale       # list ~/.claude/worktrees/ dirs whose owning session is dead
#   session-doctor.sh land-check           # per-worktree unlanded-vs-real-default-branch + real-dirty; report only
#   session-doctor.sh idle-report [--days N]      # list LIVE local sessions with no type:user msg in N days (default 2); report only
#
# Safety:
#   * Protected names (claude-remote*, *openclaw*, *hermes*) are NEVER reaped.
#   * A tmux/systemd entry is only reaped when its claude process is genuinely gone
#     (reap-local) or the operator named it explicitly (reap).
#   * `reap` refuses a session with unlanded/uncommitted work (via session-preserve.sh)
#     unless --force; a missing tmux session or systemd unit never fails the rest of it.
#   * Registry DELETION is intentionally NOT automated (it is account-facing and
#     irreversible). registry-stale prints candidates + the exact curl to run by hand.
#   * Worktree removal is intentionally NOT automated (a dead session's worktree may
#     hold unpushed/uncommitted work). worktree-stale prints candidates, each one's
#     dirty/landed status, and the exact commands to run by hand after review.
#   * idle-report and land-check are REPORT-ONLY: idle-report's rows are still-alive
#     procs reap-local won't touch; land-check never mutates anything. Feed either to
#     a manual pass.
set -uo pipefail

UD="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
BIN="$HOME/.local/bin"
PROTECT='claude-remote|openclaw|hermes'
MODE="${1:-report}"; shift || true
# Per-mode default window: idle-report wants a short "today/yesterday" window (2d);
# registry-stale keeps its 30d default. --days overrides either.
case "$MODE" in idle-report) DAYS=2;; *) DAYS=30;; esac
FORCE=no
# Positional args past MODE (e.g. `reap <name>`) must survive this loop, not
# just be discarded — collect anything that isn't a recognized flag into ARGS
# and restore it as $1.. below. (No mode needed a bare positional until `reap`,
# so this previously silently dropped one; caught while adding it.)
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="$2"; shift 2;;
    --force) FORCE=yes; shift;;
    *) ARGS+=("$1"); shift;;
  esac
done
set -- "${ARGS[@]}"
# DAYS is spliced verbatim into an embedded Python snippet below (registry-stale
# mode) as a bare identifier, e.g. `DAYS=$DAYS`. An unvalidated non-numeric value
# (typo, empty string) is therefore live Python, not data — it throws an uncaught
# NameError/SyntaxError there instead of a clean usage error. Validate here so a
# bad --days fails fast with a readable message.
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

registry_json() {
  local tok org
  tok=$(python3 -c "import json;print(json.load(open('$HOME/.claude/.credentials.json'))['claudeAiOauth']['accessToken'])" 2>/dev/null) || return 1
  org=$(python3 -c "import json;print(json.load(open('$HOME/.claude.json')).get('oauthAccount',{}).get('organizationUuid',''))" 2>/dev/null)
  curl -s -m 25 https://api.anthropic.com/v1/sessions \
    -H "Authorization: Bearer $tok" -H "x-organization-uuid: $org" \
    -H "anthropic-version: 2023-06-01" -H "anthropic-beta: ccr-byoc-2025-07-29" 2>/dev/null
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
# never leak into this answer. Prefers GitHub's actual setting via `gh` (a
# hardcoded "main" assumption, or a stale local origin/HEAD, can silently
# disagree with reality — an observed failure: a stale origin/main decoy in one
# repo made an unrelated fleet look unlanded). Falls back sanely when `gh` is
# absent/unauthenticated or the repo has no (or a non-GitHub) remote: origin/
# HEAD -> local main -> local master -> current HEAD (same chain session-git-
# prep.sh uses for the same problem). `gh` is only ever tried against a
# github.com origin (never invoked for a local-path/other-host remote — keeps
# this fast and hermetic in tests) and bounded with `timeout` so a
# hung/unreachable network call can't stall a whole worktree scan.
_default_branch() {
  local repo="$1" def="" url slug
  if [ -n "${_DEFBR_CACHE[$repo]+x}" ]; then printf '%s\n' "${_DEFBR_CACHE[$repo]}"; return; fi
  if command -v gh >/dev/null 2>&1 && url="$(git -C "$repo" remote get-url origin 2>/dev/null)"; then
    case "$url" in
      *github.com*)
        slug="$(printf '%s' "$url" | sed -E 's#^(git@github\.com:|https://github\.com/|git://github\.com/)##; s#\.git$##')"
        def="$(timeout 5 gh repo view "$slug" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)"
        ;;
    esac
  fi
  if [ -z "$def" ] && git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    def="$(git -C "$repo" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
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
    registry_json | python3 -c "
import sys,json,datetime
try: arr=json.load(sys.stdin)
except: print('  (registry unavailable)'); sys.exit()
arr=arr if isinstance(arr,list) else arr.get('sessions',arr.get('data',[]))
now=datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None); DAYS=$DAYS
def agedays(s):
    try: return (now-datetime.datetime.fromisoformat((s.get('updated_at') or s.get('created_at'))[:19])).days
    except: return -1
cand=[s for s in arr if s.get('connection_status')=='disconnected' and agedays(s)>DAYS]
cand.sort(key=agedays, reverse=True)
for s in cand:
    print('  %s  age=%3dd  status=%-9s  %s' % (s.get('id'), agedays(s), s.get('session_status'), (s.get('title') or '')[:40]))
print('  --- %d candidate(s). To delete one (VERIFY FIRST): ---' % len(cand))
print('  curl -X DELETE https://api.anthropic.com/v1/sessions/<ID> \\\\')
print('    -H \"Authorization: Bearer \$TOKEN\" -H \"x-organization-uuid: \$ORG\" \\\\')
print('    -H \"anthropic-version: 2023-06-01\" -H \"anthropic-beta: ccr-byoc-2025-07-29\"')
"
    ;;

  worktree-stale)
    echo "=== ~/.claude/worktrees/ dirs with no live owning session (NOT auto-removed) ==="
    WT_BASE="$HOME/.claude/worktrees"
    cand=0
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
      if [ -n "$mainrepo" ]; then
        # %q shell-quotes each value so the printed command is safe to copy-paste
        # even if a path or branch name contains whitespace or shell metacharacters.
        q_main="$(printf '%q' "$mainrepo")"; q_wt="$(printf '%q' "$wt")"
        if [ "$owned" = yes ]; then
          q_branch="$(printf '%q' "$branch")"
          printf '    remove: git -C %s worktree remove --force %s && git -C %s branch -D %s\n' "$q_main" "$q_wt" "$q_main" "$q_branch"
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
    echo "  --- $cand candidate(s). VERIFY dirty/unpushed work is not needed before removing. ---"
    ;;
  idle-report)
    # Report-only (mirrors registry-stale): LIVE local claude sessions with no
    # type:user transcript activity in the last N days (default 2 = today/yday).
    # NEVER kills. Every row is a still-ALIVE proc, so reap-local deliberately
    # won't touch it — feed dead ones to reap-local, reap an idle-but-alive one
    # by hand. type:user includes tool-result turns, so a session looping on its
    # own counts as active and stays off this list (intended: keep live work off
    # the reap list). Protected names are flagged and must never be reaped.
    if [ "$DAYS" -gt 0 ] 2>/dev/null; then
      echo "=== LOCAL: live sessions with NO type:user message in the last ${DAYS} day(s) — REPORT ONLY, kills nothing ==="
    else
      echo "=== LOCAL: ALL live sessions, no threshold (--days 0) — REPORT ONLY, kills nothing ==="
    fi
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
home = os.path.expanduser('~')
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
cutoff = (now - datetime.timedelta(days=DAYS)) if DAYS > 0 else None
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
    mx = None
    for fn in files:
        try:
            for l in open(fn, encoding='utf-8', errors='ignore'):
                if '\"user\"' not in l: continue           # cheap prefilter (authoritative check below)
                try: o = json.loads(l)
                except Exception: continue
                if o.get('type') == 'user':
                    ts = o.get('timestamp')
                    if ts and (mx is None or ts > mx): mx = ts
        except Exception: pass
    if mx is None:
        # 'never messaged' — distinguish no-transcript from present-but-no-user.
        state = 'never: no transcript' if not files else 'never: no user msgs'
        mxdt = None
    else:
        state = mx[:19] + 'Z'
        try: mxdt = datetime.datetime.fromisoformat(mx[:19])
        except Exception: mxdt = None
    if DAYS > 0 and mxdt is not None and mxdt >= cutoff:
        continue                                          # had a user turn within the window -> not idle
    rows.append((mxdt, state, tm or rc, cwd, prot))
# oldest-first: 'never' (mxdt None) first, then ascending timestamp.
rows.sort(key=lambda r: (r[0] is not None, r[0] or datetime.datetime.min))
print('  %-22s %-5s %-46s %s' % ('LAST type:user', 'PROT', 'TMUX SESSION', 'CWD'))
nprot = 0
for mxdt, state, tm, cwd, prot in rows:
    if prot == 'yes': nprot += 1
    print('  %-22s %-5s %-46s %s' % (state[:22], ('[P]' if prot == 'yes' else ''), tm[:46], cwd))
print('  --- %d idle session(s)%s. All are ALIVE -> reap-local will NOT touch them.' % (
      len(rows), (', incl. %d PROTECTED (never reap)' % nprot) if nprot else ''))
print('  Report only. Reap an idle-but-alive one by hand:')
print('    tmux kill-session -t <name> ; systemctl --user disable --now <name>.service')
"
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
  *) echo "usage: session-doctor.sh [report|reap-local|reap <name>|registry-stale [--days N]|worktree-stale|land-check|idle-report [--days N]]"; exit 2;;
esac
fi
