#!/usr/bin/env bash
# session-compact.sh — find idle sessions worth reclaiming and issue /compact
# into them. session-doctor.sh stays the report-only SENSOR (idle-report
# --minutes N --tsv); ALL mutation lives here. See docs/session-compaction.md
# for the full design rationale — this header is a summary, not the source of
# truth.
#
# Usage:
#   session-compact.sh report                        # who is eligible and why/why not (idle-window model) — mutates nothing
#   session-compact.sh sweep (--dry-run|--apply)      # context-aware two-trigger sweep (idle OR context); default (no flag) is --dry-run
#   session-compact.sh before-relay <session> <msg>   # compact IF stale, verify, then relay
#   session-compact.sh before-relay <session> --file <path>
#   session-compact.sh install-timer                  # write systemd units; enable NOTHING
#
#   report/sweep window flags: --min-idle N (default 60) --max-idle N (default 0 = unbounded)
#   before-relay/sweep --apply: --timeout N (default 240; seconds to wait for a compact to finish)
#   sweep --managed-only: opt-in scope filter. Only considers sessions named,
#     one per line, in $SESSION_COMPACT_MANAGED_FILE (default
#     $HOME/.claude/session-compact-managed; # comments/blank lines ignored).
#     FAILS SAFE: a missing/empty/no-usable-entries allowlist means ZERO
#     sessions in scope, NEVER fleet-wide. Without this flag, behavior is
#     unchanged. See the sweep dispatch's own comment for the full rationale.
#   install-timer: --force (overwrite existing unit files)
#
# `sweep` is intentionally a DIFFERENT eligibility model than `report` and
# `before-relay` (which still run on the idle-window model below, UNCHANGED):
#   trigger A: idle >= --min-idle minutes (default 60 — same threshold/flag
#              this repo's sweep always had)
#   trigger B: context >= 80% of the model's window AND idle >= 5 minutes
#              (the 5-minute floor exists so a session is never compacted
#              mid-turn purely because it is context-heavy)
# Both triggers are evaluated via _evaluate_row (see _sweep_decide) — NOT a
# separate, narrower reimplementation — specifically so protected/landed-and-
# clean/already-compacted/pane-safety all still apply to trigger B exactly as
# they already do to trigger A. This matters concretely for already-
# compacted: idle-report deliberately does NOT reset idle_minutes across a
# compact (a /compact summary is not a "genuine" turn — see idle-report's own
# comment), so without routing back through _decide's compacted-column/
# marker check, a low-context idle session would get /compact re-issued on
# every single sweep run, forever.
# Context % is read directly from the session's own transcript (last
# assistant message's usage: input + cache_read + cache_creation tokens,
# divided by a per-model window — see _model_window_for). If that can't be
# read/parsed, the session degrades to idle-only (trigger A only) and the
# report says so — it never guesses a percentage. `sweep --apply` reuses
# _do_compact/_write_marker unchanged (the SAME compaction mechanism report/
# before-relay already use) and is just as fail-closed as it always was: a
# compact that can't be verified logs FAILED and moves to the next session,
# writing no marker. See _sweep_decide's comment for the exact rule and
# docs/session-compaction.md for rationale once this lands.
#
# Why the default window is 60min+, unbounded (NOT the original 30-60min):
# Claude Code opts into a 1-hour prompt-cache TTL for ordinary interactive
# sessions, and that TTL is a SLIDING WINDOW refreshed on every cache read —
# so "idle N minutes" IS "N minutes since the cache was last refreshed".
# Below 60min the cache is still alive: compacting there destroys a cache a
# resumer would have hit at ~0.1x cost, making 30-60min the MOST expensive
# window to compact in, not the cheapest. Past 60min the TTL has lapsed, so
# the incremental cache cost of compacting drops to zero. See
# docs/session-compaction.md ("The default window is 60min+, not 30-60min")
# for the full derivation, measurement, and caveats. The original window is
# still one flag away: --min-idle 30 --max-idle 60.
#
# Data source: shells out to `session-doctor.sh idle-report --minutes N --tsv`
# (co-located first, then PATH — same resolution session-send.sh uses for
# session-handoff). Override with $SESSION_COMPACT_SENSOR to inject a fixture
# producer in tests instead of running the real scan.
#
# Eligibility (ALL must hold; report says which ONE failed first, in this
# order): idle_minutes is an integer, not "never" (never-touched) ->
# protected/compacted/landed/dirty each match the sensor's documented
# vocabulary, not truncated/garbage (malformed-row) -> idle inside the
# configured window (outside-window) -> protected == no (protected) -> NOT
# (landed=yes AND dirty=clean) (landed-and-clean) -> not already compacted
# this idle window, marker-file fallback when the sensor reports
# compacted=unknown (already-compacted) -> live pane safe to inject, via
# `session-handoff.sh ready <session>` (pane-<reason>).
#
# Compacting: `session-handoff.sh send <session> "/compact"`, then poll for
# completion (bounded by --timeout, default 240s — a compact measures ~101s
# wall-clock). PRIMARY signal is the transcript (ground truth — a newer
# compact_boundary/isCompactSummary marker than a pre-send baseline);
# pane-state (`session-handoff.sh check`) is a fallback only. See
# _do_compact's own comment for why: pane-state ALONE previously produced a
# false "timeout" on two genuinely-successful real compacts (Bug B, confirmed
# 2026-09-11) because the pane never reported `busy` even once during either
# run. On timeout (neither signal confirms), report it and do NOT write a
# success marker. `before-relay` fails CLOSED: if a compact was issued but
# completion could not be verified, the message is NOT sent.
set -uo pipefail

# ── pure-ish helpers (source-guarded below so tests can exercise them) ───────

# _find_helper <basename> — resolve a sibling script co-located first (repo/
# dev layout: <basename>.sh next to this script), then on PATH (deployed
# layout: flat copies in ~/.local/bin with the .sh dropped). Prints the path
# and returns 0, or prints nothing and returns 1 — callers must fail SAFE on
# a miss. Copied from session-doctor.sh's helper of the same name/contract.
_find_helper() {
  local base="$1" here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  if [ -f "$here/${base}.sh" ]; then printf '%s\n' "$here/${base}.sh"; return 0; fi
  if command -v "$base" >/dev/null 2>&1; then command -v "$base"; return 0; fi
  return 1
}

# _encode_cwd <path> -> the ~/.claude/projects/<encoded> transcript-dir name
# for that cwd. Copied verbatim from session-doctor.sh's algorithm (same
# comment there): '.' -> '-' FIRST, then '/' -> '-'. Not re-derived — this
# ordering is load-bearing and already verified empirically over there.
_encode_cwd() {
  local p="$1"
  p="${p//./-}"
  printf '%s\n' "${p//\//-}"
}

# _compact_marker_newer <cwd> <baseline_ts-or-empty> -> the newest ISO-8601
# timestamp, STRICTLY AFTER <baseline_ts>, of any type:system/
# subtype:compact_boundary or type:user/isCompactSummary:true entry across
# every *.jsonl in <cwd>'s transcript dir — or empty if none qualify (dir
# missing, no matching entry, or nothing newer than the baseline). ISO-8601
# strings sort correctly as plain strings (same trick session-doctor.sh's
# idle-report already relies on for genuine_mx/compact_mx), so the "newer
# than" comparison is done as a string compare inside Python rather than in
# shell — deliberately: this repo's scripts avoid bash's `[[ ]]` (not used
# anywhere in this file or session-doctor.sh/session-handoff.sh), and POSIX
# `[ ]` has no string `>`/`<` operator at all, only numeric -gt/-lt.
#
# This is Bug B's completion signal: a completed /compact is ground truth in
# the transcript (docs/session-compaction.md point 3), unlike the pane's
# on-screen text, which is what _pane_state below actually gets wrong (see
# _do_compact's comment). Called once before send() to snapshot a baseline,
# then repeatedly during the poll loop with that baseline — never called with
# an empty baseline mid-poll, so a session that had ALREADY been compacted
# once before this call can't be mistaken for freshly-completing on the very
# first poll.
_compact_marker_newer() {
  local cwd="$1" baseline="$2" dir
  dir="$HOME/.claude/projects/$(_encode_cwd "$cwd")"
  [ -d "$dir" ] || { echo ""; return; }
  python3 -c "
import sys, glob, json, os
d, baseline = sys.argv[1], sys.argv[2]
mx = None
for fn in glob.glob(os.path.join(d, '*.jsonl')):
    try:
        with open(fn, encoding='utf-8', errors='ignore') as fh:
            for line in fh:
                # Cheap prefilter before json.loads (same trick session-
                # doctor.sh's idle-report scan uses) — skip lines that can't
                # possibly be either marker shape.
                if 'compact_boundary' not in line and 'isCompactSummary' not in line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                ts = None
                if o.get('type') == 'system' and o.get('subtype') == 'compact_boundary':
                    ts = o.get('timestamp')
                elif o.get('type') == 'user' and o.get('isCompactSummary'):
                    ts = o.get('timestamp')
                if not ts:
                    continue
                if baseline and ts <= baseline:
                    continue
                if mx is None or ts > mx:
                    mx = ts
    except OSError:
        pass   # transcript file gone mid-scan — just skip it
print(mx or '')
" "$dir" "$baseline"
}

# ── sweep v2: context-aware trigger (idle-OR-context, busy-checked) ─────────
# Added on top of the idle-window model above WITHOUT touching it: `report`
# and `before-relay` still run entirely on `_decide`/`_evaluate_row`, unedited,
# so every one of their existing tests stays a valid contract. `sweep` gets
# its own trigger model below because its thresholds are genuinely different
# in shape (idle-window vs. OR-of-two-triggers) — bolting that onto `_decide`
# would mean adding a context-pct positional argument to a function whose
# exact positional signature ~25 existing assertions pin by hand.

# _model_window_for <model-string> -> token count, or "" if unrecognized.
# ONE table, not scattered (see design brief). Sonnet-5/Opus-5/Fable-5 (any
# point release matching *sonnet*/*opus*/*fable*) default to a 1,000,000-token
# window; Haiku (*haiku*) to 200,000 — documented defaults, not a measured fact
# this repo has anywhere else. A model string matching none is UNKNOWN on
# purpose: callers must degrade to idle-only rather than divide by a guessed
# number — the same "never guess a percentage" rule that governs an
# unparseable transcript (see _context_snapshot below).
#
# *fable* added 2026-09-12 after a live dry-run showed all three `claude-fable-5`
# orchestrator sessions reporting "context unavailable" — their transcripts were
# large (3.4M-4.1M) and perfectly parseable; the model simply wasn't in this
# table, so the 80%-context trigger was silently inert on exactly the most
# bloated sessions on the host. Adding a model here is required whenever a new
# model starts being spawned, and the symptom is silence, not an error.
_model_window_for() {
  case "$1" in
    *sonnet*|*opus*|*fable*) echo 1000000 ;;
    *haiku*)                 echo 200000 ;;
    *)                       echo "" ;;
  esac
}

# _context_snapshot <cwd> -> "tokens\tmodel" for the LAST assistant message
# (by timestamp, across every *.jsonl in the cwd's transcript dir — same
# multi-file-per-cwd handling _compact_marker_newer uses above) that carries a
# real `message.usage` object, or "" if the transcript dir is missing, has no
# such message, or every candidate's model is the literal string
# "<synthetic>". That synthetic-model exclusion is load-bearing, not
# defensive filler: a REAL transcript on this host (2026-08-26,
# .../agent-host-control-framework) carries a trailing assistant entry with
# model="<synthetic>" and all-zero usage AFTER the last real turn (a hook- or
# statusline-injected pseudo-turn, not a model call) — picking it as "last"
# would silently report 0 tokens / 0% for a session that is actually at
# whatever its last REAL turn left it at. Tokens = input_tokens +
# cache_read_input_tokens + cache_creation_input_tokens (current context as
# of that turn — NOT + output_tokens, which hasn't been read back in as
# context by anything yet). "" on any parse failure — never a guessed number.
_context_snapshot() {
  local cwd="$1" dir
  dir="$HOME/.claude/projects/$(_encode_cwd "$cwd")"
  [ -d "$dir" ] || { echo ""; return; }
  python3 -c "
import sys, glob, json, os
d = sys.argv[1]
best_ts = None
best = None
for fn in glob.glob(os.path.join(d, '*.jsonl')):
    try:
        with open(fn, encoding='utf-8', errors='ignore') as fh:
            for line in fh:
                if '\"assistant\"' not in line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if o.get('type') != 'assistant':
                    continue
                msg = o.get('message') or {}
                model = msg.get('model')
                if not model or model == '<synthetic>':
                    continue
                usage = msg.get('usage')
                if not isinstance(usage, dict):
                    continue
                ts = o.get('timestamp')
                if not ts:
                    continue
                if best_ts is None or ts > best_ts:
                    best_ts = ts
                    best = (usage, model)
    except OSError:
        pass   # transcript file gone mid-scan — just skip it
if best is None:
    print('')
else:
    usage, model = best
    def num(k):
        try:
            return int(usage.get(k) or 0)
        except Exception:
            return 0
    tokens = num('input_tokens') + num('cache_read_input_tokens') + num('cache_creation_input_tokens')
    print('%d\t%s' % (tokens, model))
" "$dir"
}

# _context_pct_for_row <cwd> -> "tokens\tpct" or "" (degraded — no transcript,
# no usable usage entry, or a model _model_window_for doesn't recognize).
# Callers MUST treat "" as "context trigger unavailable, fall back to
# idle-only for this session and report the degradation" — never substitute a
# guessed window just to produce a number.
_context_pct_for_row() {
  local cwd="$1" raw tokens model window
  raw="$(_context_snapshot "$cwd")"
  [ -n "$raw" ] || { echo ""; return; }
  tokens="${raw%%$'\t'*}"
  model="${raw#*$'\t'}"
  case "$tokens" in ''|*[!0-9]*) echo ""; return ;; esac
  window="$(_model_window_for "$model")"
  [ -n "$window" ] || { echo ""; return; }
  printf '%s\t%s\n' "$tokens" "$(( tokens * 100 / window ))"
}

# _validate_uint <flag-name> <var-name> — validates the NAMED variable's
# current value and canonicalizes it in place (base-10, leading-zero-safe —
# same idiom used throughout this repo: session-doctor.sh --days, session-
# alias.sh). Takes a variable NAME (nameref), not its value, and is called as
# a plain statement, NOT `X="$(_validate_uint ...)"` — that command-
# substitution form runs this in a subshell, where `exit 2` would only kill
# the subshell and silently leave $X empty instead of failing the script (a
# real bug caught in testing: an invalid --min-idle was swallowed, not
# rejected).
_validate_uint() {
  local name="$1"
  local -n ref="$2"
  case "$ref" in
    ''|*[!0-9]*) echo "session-compact: $name requires a non-negative integer, got '$ref'" >&2; exit 2 ;;
  esac
  ref=$((10#$ref))
}

# _managed_allowlist_file -> the allowlist path to read for `sweep
# --managed-only`: $SESSION_COMPACT_MANAGED_FILE if set (tests point this at
# a fixture so they never read or write the real file), else
# $HOME/.claude/session-compact-managed. Pure string logic, no I/O of its own.
_managed_allowlist_file() {
  printf '%s\n' "${SESSION_COMPACT_MANAGED_FILE:-$HOME/.claude/session-compact-managed}"
}

# _read_managed_allowlist <path> -> one usable tmux-session-name per line to
# stdout: each line of <path>, trimmed of leading/trailing whitespace, with
# blank lines and whole-line '#' comments dropped. A missing file prints
# nothing and returns 0 — NOT an error. This function has no fallback logic
# of its own on purpose: "prints nothing" is exactly the signal `sweep`'s
# --managed-only dispatch treats as "the allowlist is empty" (see the sweep
# dispatch's own comment for why that must mean zero sessions in scope, never
# fleet-wide).
_read_managed_allowlist() {
  local f="$1" line trimmed
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      '#'*) continue ;;
    esac
    printf '%s\n' "$trimmed"
  done < "$f"
}

# _decide <min_idle> <max_idle> <tmux_session> <remote_name> <pid> <cwd> \
#         <idle_minutes> <last_genuine_user_ts> <protected> \
#         <compacted_since_last_turn> <landed> <dirty> <marker_hit>
#
# PURE — no I/O, no subprocesses, no filesystem/tmux access. Args 3-12 are
# the sensor's 10 TSV columns in contract order, unchanged. <marker_hit>
# (yes/no/na) is NOT one of the 10 columns: it is the pre-computed result of
# checking the compact-marker file for the compacted=unknown fallback path
# (see _marker_hit, which does the actual I/O) — the caller looks it up and
# hands in the answer so this function itself never touches the filesystem.
# Prints "eligible" or "skip:<reason>" on stdout; never exits/fails.
_decide() {
  local min_idle="$1" max_idle="$2"
  # ${N:-} rather than bare $N: a genuinely short/ragged row (fewer than 13
  # args — the "no crash" requirement) must not trip `set -u`'s unbound-
  # variable error. Missing fields resolve to "" the same way an explicit
  # empty TSV field would. For idle_minutes that's enough to fail the same
  # way explicit garbage does (caught below, "not an integer"/"not never").
  # It is NOT enough for protected/compacted/landed/dirty: those are tested
  # with `= yes` / case matches, so an empty (or otherwise-unrecognized)
  # value would silently read as the PERMISSIVE answer — "not protected",
  # "not landed", "not already compacted" — the opposite of failing closed.
  # So those four are validated below against the sensor's documented
  # vocabulary (session-doctor.sh never legitimately emits anything else)
  # and rejected as skip:malformed-row on any other value, including "".
  local idle_minutes="${7:-}" protected="${9:-}" compacted="${10:-}" landed="${11:-}" dirty="${12:-}" marker_hit="${13:-}"

  if [ "$idle_minutes" = never ]; then echo "skip:never-touched"; return; fi
  case "$idle_minutes" in
    ''|*[!0-9]*) echo "skip:bad-idle-field"; return ;;
  esac
  local idle_n=$((10#$idle_minutes))

  case "$protected" in
    yes|no) : ;;
    *) echo "skip:malformed-row"; return ;;
  esac
  case "$compacted" in
    yes|no|unknown) : ;;
    *) echo "skip:malformed-row"; return ;;
  esac
  case "$landed" in
    yes|no|unknown|no-worktree) : ;;
    *) echo "skip:malformed-row"; return ;;
  esac
  case "$dirty" in
    clean|DIRTY|unknown) : ;;
    *) echo "skip:malformed-row"; return ;;
  esac

  if [ "$idle_n" -lt "$min_idle" ]; then echo "skip:outside-window"; return; fi
  if [ "$max_idle" != 0 ] && [ "$idle_n" -gt "$max_idle" ]; then echo "skip:outside-window"; return; fi

  if [ "$protected" = yes ]; then echo "skip:protected"; return; fi

  if [ "$landed" = yes ] && [ "$dirty" = clean ]; then echo "skip:landed-and-clean"; return; fi

  case "$compacted" in
    yes) echo "skip:already-compacted"; return ;;
    unknown)
      if [ "$marker_hit" = yes ]; then echo "skip:already-compacted"; return; fi
      ;;
  esac

  echo eligible
}

# _marker_file <tmux_session> -> path to its compact-marker JSON file.
_marker_file() { printf '%s\n' "$HOME/.sessions/compact-markers/$1.json"; }

# _marker_hit <tmux_session> <last_genuine_user_ts> -> yes|no. I/O: reads the
# marker file. Only meaningful when the sensor's compacted_since_last_turn
# column reads "unknown" (older CLI, no compact_boundary marker in the
# transcript — see docs/session-compaction.md point 4).
_marker_hit() {
  local session="$1" ts="$2" f stored
  f="$(_marker_file "$session")"
  [ -f "$f" ] || { echo no; return; }
  stored="$(python3 -c "
import json, sys
try:
    print(json.load(open(sys.argv[1])).get('last_user_ts_at_compact', ''))
except Exception:
    print('')
" "$f" 2>/dev/null)"
  if [ -n "$stored" ] && [ "$stored" = "$ts" ]; then echo yes; else echo no; fi
}

# _write_marker <tmux_session> <last_genuine_user_ts> <injected_at_iso> <result>
# I/O: atomic write via mktemp+mv under flock — the session-alias.sh
# store_upsert idiom (`exec 9>"$f.lock"; flock 9` ... `flock -u 9`), NOT
# record-spawn-telemetry.sh's unlocked append (wrong pattern for a
# read-then-overwrite file like this one). Written after EVERY successful
# compact regardless of detection mode — cheap, and it's the only safety net
# on older CLI builds that lack the compact_boundary transcript marker.
_write_marker() {
  local session="$1" ts="$2" injected_at="$3" result="$4" dir f tmp
  dir="$HOME/.sessions/compact-markers"
  mkdir -p "$dir"
  f="$dir/$session.json"
  exec 9>"$f.lock"
  flock 9
  tmp="$(mktemp "$f.XXXXXX")"
  python3 -c "
import json, sys
json.dump({'session': sys.argv[1], 'last_user_ts_at_compact': sys.argv[2],
           'injected_at': sys.argv[3], 'result': sys.argv[4]}, open(sys.argv[5], 'w'))
" "$session" "$ts" "$injected_at" "$result" "$tmp"
  mv -f "$tmp" "$f"
  flock -u 9
}

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── shelling out to the sensor / session-handoff (I/O) ───────────────────────

# _fetch_tsv <min_idle> -> the sensor's TSV to stdout; propagates its exit
# status. $SESSION_COMPACT_SENSOR overrides the real sensor entirely — set to
# a full command (e.g. "bash /path/to/fixture.sh"); it is intentionally
# word-split so a multi-word override works without requiring an exported
# array, and is invoked with the same --minutes/--tsv args the real sensor
# gets so a fixture can ignore-or-honor them as it likes.
_fetch_tsv() {
  local min="$1"
  if [ -n "${SESSION_COMPACT_SENSOR:-}" ]; then
    # shellcheck disable=SC2086
    $SESSION_COMPACT_SENSOR --minutes "$min" --tsv
    return $?
  fi
  local bin
  bin="$(_find_helper session-doctor)" || {
    echo "session-compact: could not locate session-doctor (looked next to this script and on PATH)" >&2
    return 127
  }
  bash "$bin" idle-report --minutes "$min" --tsv
}

_SESSION_HANDOFF_BIN=""
# _session_handoff <args...> — resolve session-handoff co-located first, then
# on PATH (same resolution session-send.sh uses), memoized per invocation.
_session_handoff() {
  if [ -z "$_SESSION_HANDOFF_BIN" ]; then
    _SESSION_HANDOFF_BIN="$(_find_helper session-handoff)" || {
      echo "session-compact: could not locate session-handoff (looked next to this script and on PATH)" >&2
      return 127
    }
  fi
  bash "$_SESSION_HANDOFF_BIN" "$@"
}

# _pane_ready_reason <tmux_session> — the one live call this script makes to
# decide whether a pane is safe to type into: `session-handoff.sh ready
# <session>`. Prints "safe" and returns 0 when it is; otherwise prints the
# failure reason (e.g. "busy", "menu", "no-prompt", "draft-in-input-box", or
# "unreachable" when `ready`'s own output doesn't carry a reason=... token)
# and returns 1. Shared by _evaluate_row (the normal eligibility path) and
# before-relay's not-found-in-sensor branch (Bug 1 fix — that branch used to
# send with zero information about pane state).
_pane_ready_reason() {
  local session="$1" ready_out rc reason
  ready_out="$(_session_handoff ready "$session" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo safe
    return 0
  fi
  reason="$(printf '%s' "$ready_out" | sed -n 's/.*reason=\(.*\)$/\1/p')"
  [ -n "$reason" ] || reason="unreachable"
  printf '%s\n' "$reason"
  return 1
}

# _evaluate_row <min_idle> <max_idle> <10 TSV fields> — non-pure wrapper
# around _decide: resolves the marker-file I/O when needed, then (only if
# the cheap pure checks all pass) makes the one live call this needs —
# `session-handoff.sh ready <session>` — for the pane-safety verdict. Prints
# "eligible" or "skip:<reason>".
_evaluate_row() {
  local min_idle="$1" max_idle="$2"; shift 2
  local tmux_session="$1" last_user_ts="$6" compacted="$8"
  local marker_hit=na
  if [ "$compacted" = unknown ]; then
    marker_hit="$(_marker_hit "$tmux_session" "$last_user_ts")"
  fi
  local decision
  decision="$(_decide "$min_idle" "$max_idle" "$@" "$marker_hit")"
  if [ "$decision" != eligible ]; then
    printf '%s\n' "$decision"
    return
  fi
  local pane_reason pane_rc
  pane_reason="$(_pane_ready_reason "$tmux_session")"; pane_rc=$?
  if [ "$pane_rc" -eq 0 ]; then
    echo eligible
    return
  fi
  printf 'skip:pane-%s\n' "$pane_reason"
}

_pane_state() {  # $1=tmux_session -> dead|starting|busy|ready|"" (I/O)
  local out
  out="$(_session_handoff check "$1" 2>&1)" || true
  printf '%s' "$out" | grep -oE 'state=[a-z]+' | head -1 | cut -d= -f2
}

# _sweep_decide <min_idle> <max_idle> <context_pct-or-empty> <10 TSV fields>
# -> "eligible:idle" | "eligible:context" | "skip:<reason>" (the SAME skip
# vocabulary _decide/_evaluate_row already use — nothing new is invented).
# Reuses _evaluate_row for BOTH checks below rather than re-deriving
# protected/landed/already-compacted/pane-safety — deliberately: an earlier
# version of this function re-implemented those checks against just
# (idle_minutes, protected, context_pct) and, under review, that turned out
# to reopen a real bug idle-report's own history warns about (#60/#61): a
# compact does NOT reset idle_minutes (idle is measured from the last GENUINE
# user turn, and idle-report's whole point is that a /compact summary itself
# does not count as one), so a session sitting idle at low context forever
# would get /compact re-issued on EVERY sweep run, indefinitely, unless
# something consults the sensor's `compacted` column / the marker file the
# way _decide already does. Routing eligibility back through _evaluate_row
# inherits that guard (and protected/landed-and-clean/pane-safety) for free,
# on BOTH triggers, instead of re-deriving a narrower and buggier copy.
#   Trigger A: _evaluate_row with the caller's own <min_idle>/<max_idle>
#              (defaults 60/0 — same as this repo's pre-existing sweep).
#   Trigger B: _evaluate_row with a fixed 5-minute floor, promoted to
#              "eligible:context" only when that ALSO clears
#              _SWEEP_CONTEXT_TRIGGER_PCT. Only consulted when A's decision
#              was SPECIFICALLY skip:outside-window — any other A reason
#              (protected/landed-and-clean/already-compacted/malformed/
#              never-touched/pane-unsafe) is idle-window-independent: _decide
#              checks all of those either before consulting the window at
#              all, or (pane-safety) only after the window already passed —
#              so a second live pane check at a looser window cannot change
#              the answer, and calling B there would just double the I/O.
_SWEEP_CONTEXT_TRIGGER_PCT=80
_SWEEP_CONTEXT_IDLE_FLOOR=5

_sweep_decide() {
  local min_idle="$1" max_idle="$2" context_pct="$3"; shift 3
  local decision_a decision_b
  decision_a="$(_evaluate_row "$min_idle" "$max_idle" "$@")"
  if [ "$decision_a" = eligible ]; then
    echo "eligible:idle"
    return
  fi
  if [ "$decision_a" != "skip:outside-window" ]; then
    printf '%s\n' "$decision_a"
    return
  fi
  decision_b="$(_evaluate_row "$_SWEEP_CONTEXT_IDLE_FLOOR" 0 "$@")"
  if [ "$decision_b" != eligible ]; then
    printf '%s\n' "$decision_b"
    return
  fi
  case "$context_pct" in
    ''|*[!0-9]*) echo "skip:outside-window"; return ;;
  esac
  if [ "$context_pct" -ge "$_SWEEP_CONTEXT_TRIGGER_PCT" ]; then
    echo "eligible:context"
  else
    echo "skip:outside-window"
  fi
}

declare -A _COMPACT_ISSUED=()
# _do_compact <tmux_session> <timeout_seconds> [<cwd>] -> prints one of:
# compacted | send-failed | timeout. Exit code 0 only for "compacted" (fully
# verified). Refuses to send /compact to the SAME session twice within one
# invocation (per-session guard — sweep legitimately compacts many DIFFERENT
# sessions in one run; this only stops re-issuing to one already handled).
#
# <cwd> is OPTIONAL (both real call sites have it — the sensor's column 4 —
# but tests calling this directly may omit it) and drives the PRIMARY
# completion signal: the transcript. Bug B (found by running this for real
# against two live sessions 2026-09-11): both compactions genuinely succeeded
# — panes showed "Compacted (ctrl+o to see full summary)" — but this function
# sat the full --timeout and reported "timeout" both times, writing no
# success marker. Root cause, confirmed by reading _pane_state's call chain
# down to _is_working (session-handoff.sh): the pane-state poll below required
# observing `busy` at least once before it would accept `ready` as done, and
# during a real compact `busy` was never observed even once — a compact
# genuinely measures ~101s wall-clock (docs/session-compaction.md) against a
# 240s default timeout, so if `busy` had ever been seen, a `ready` poll well
# before the timeout would have caught it and returned early; it never did,
# for the entire window, on two separate real runs. The only reading
# consistent with that is that Claude Code's compacting indicator doesn't
# match `_is_working`'s spinner/"esc to interrupt" patterns — NOT investigated
# further live (this host is read-only for this fix: no sending text into
# real panes), because the fix below doesn't need pane text to be correct at
# all: it moves the PRIMARY signal off the pane entirely.
#
# The transcript is ground truth and already the documented-preferred
# idempotency signal (docs/session-compaction.md point 3: a completed compact
# writes a type:system/subtype:compact_boundary entry, or isCompactSummary on
# older builds). So: snapshot the newest such marker BEFORE sending, then poll
# for a NEWER one — exactly the comparison session-doctor.sh's idle-report
# already does for column 8, reused here via _compact_marker_newer. Pane state
# is kept as a FALLBACK ONLY (still gated on the same seen-busy-before-ready
# rule as before), for: no cwd given, no transcript dir for that cwd, or an
# older CLI whose transcript never gets a fresh marker within the timeout for
# some other reason. Both signals are checked every poll — whichever confirms
# first wins — so a working pane-state reading (if the indicator IS matched on
# some build) still short-circuits the wait instead of always burning time on
# a transcript re-scan first.
#
# Stays FAIL CLOSED: neither signal confirming within --timeout is still
# "timeout", exit 1, no marker written by the caller — this function does not
# relax that to paper over Bug B, only fixes the false negative.
_do_compact() {
  local session="$1" timeout="$2" cwd="${3:-}" out rc waited=0 seen_busy=no state baseline_ts newer

  if [ -n "${_COMPACT_ISSUED[$session]+x}" ]; then
    echo "session-compact: INTERNAL — refusing to send /compact to '$session' a second time in this invocation" >&2
    echo send-failed
    return 1
  fi
  _COMPACT_ISSUED[$session]=1

  baseline_ts=""
  [ -n "$cwd" ] && baseline_ts="$(_compact_marker_newer "$cwd" "")"

  out="$(_session_handoff send "$session" "/compact" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "session-compact: /compact to '$session' did not land: $out" >&2
    echo send-failed
    return 1
  fi

  # Wait for completion (measured ~101s wall-clock — see design doc).
  # Transcript check first (the primary, reliable signal); pane-state check
  # second (fallback — see the function comment above for both). Require
  # having OBSERVED busy at least once before accepting "ready" as done on the
  # pane-state path specifically: `send`'s own "landed" verdict can fire the
  # instant the /compact text is echoed into the transcript, a beat before
  # Claude Code actually starts the compaction spinner — so a "ready" reading
  # taken immediately after send returns is not trustworthy evidence the
  # compact finished. This restriction does not apply to the transcript path,
  # which has its own, independent ground-truth check (a NEWER marker than
  # the pre-send baseline).
  while [ "$waited" -lt "$timeout" ]; do
    if [ -n "$cwd" ]; then
      newer="$(_compact_marker_newer "$cwd" "$baseline_ts")"
      [ -n "$newer" ] && { echo compacted; return 0; }
    fi
    state="$(_pane_state "$session")"
    case "$state" in
      busy) seen_busy=yes ;;
      ready) [ "$seen_busy" = yes ] && { echo compacted; return 0; } ;;
    esac
    sleep 3
    waited=$((waited+3))
  done
  echo timeout
  return 1
}

# ── mode dispatch ─────────────────────────────────────────────────────────

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
MODE="${1:-}"; shift || true

_usage() {
  echo "usage: session-compact.sh (report [--min-idle N] [--max-idle N]" >&2
  echo "         | sweep [--dry-run|--apply] [--min-idle N] [--max-idle N] [--timeout N] [--managed-only]  # default: --dry-run" >&2
  echo "         | before-relay <session> (<msg>|--file <path>) [--timeout N]" >&2
  echo "         | install-timer [--force])" >&2
  exit 2
}

case "$MODE" in
  report)
    MIN_IDLE=60; MAX_IDLE=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --min-idle) MIN_IDLE="$2"; shift 2 ;;
        --max-idle) MAX_IDLE="$2"; shift 2 ;;
        *) echo "session-compact: $MODE: unrecognized argument '$1'" >&2; exit 2 ;;
      esac
    done
    _validate_uint --min-idle MIN_IDLE
    _validate_uint --max-idle MAX_IDLE

    TSV="$(_fetch_tsv "$MIN_IDLE")"; rc=$?
    [ "$rc" -eq 0 ] || { echo "session-compact: sensor command failed (exit $rc)" >&2; exit 1; }

    window_desc="idle >= ${MIN_IDLE}m"
    [ "$MAX_IDLE" != 0 ] && window_desc="$window_desc, <= ${MAX_IDLE}m"

    echo "=== session-compact report: $window_desc — REPORT ONLY, mutates nothing ==="
    printf '%-40s %-9s %-8s %s\n' "TMUX SESSION" "ELIGIBLE" "IDLE" "REASON"
    n=0
    while IFS=$'\t' read -r c1 c2 c3 c4 c5 c6 c7 c8 c9 c10; do
      [ -n "$c1" ] || continue
      n=$((n+1))
      decision="$(_evaluate_row "$MIN_IDLE" "$MAX_IDLE" "$c1" "$c2" "$c3" "$c4" "$c5" "$c6" "$c7" "$c8" "$c9" "$c10")"
      case "$decision" in
        eligible) elig=yes; reason=eligible ;;
        skip:*)   elig=no;  reason="${decision#skip:}" ;;
        *)        elig=no;  reason="$decision" ;;
      esac
      printf '%-40s %-9s %-8s %s\n' "$c1" "$elig" "$c5" "$reason"
    done <<< "$TSV"
    echo "  --- $n candidate(s) scanned. Report only; mutates nothing."
    ;;

  sweep)
    # Two-trigger, context-aware model (see _sweep_decide's comment for the
    # exact rule and why it reuses _evaluate_row twice instead of deriving
    # its own narrower copy) — a DIFFERENT eligibility model than report/
    # before-relay still use (those two are UNCHANGED). The flag surface,
    # compaction mechanism (_do_compact/_write_marker), and fail-closed
    # behavior on an unverified compact are ALL unchanged from this repo's
    # pre-existing sweep — only the eligibility SOURCE changed (idle-window
    # OR context, instead of idle-window only), plus one default: neither
    # --dry-run nor --apply given now means dry-run (report-only) instead of
    # a hard error — a sweep that mutates by default is too dangerous to
    # ship, but refusing to run at all by default is needless friction for
    # what should be the routine, safe invocation.
    MIN_IDLE=60; MAX_IDLE=0; TIMEOUT=240; DRY_RUN=no; APPLY=no; MANAGED_ONLY=no
    while [ $# -gt 0 ]; do
      case "$1" in
        --min-idle)     MIN_IDLE="$2"; shift 2 ;;
        --max-idle)     MAX_IDLE="$2"; shift 2 ;;
        --timeout)      TIMEOUT="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=yes; shift ;;
        --apply)        APPLY=yes; shift ;;
        --managed-only) MANAGED_ONLY=yes; shift ;;
        *) echo "session-compact: sweep: unrecognized argument '$1'" >&2; exit 2 ;;
      esac
    done
    _validate_uint --min-idle MIN_IDLE
    _validate_uint --max-idle MAX_IDLE
    _validate_uint --timeout TIMEOUT

    if [ "$DRY_RUN" = yes ] && [ "$APPLY" = yes ]; then
      echo "session-compact: sweep: pass at most one of --dry-run or --apply, not both" >&2
      exit 2
    fi
    if [ "$DRY_RUN" = no ] && [ "$APPLY" = no ]; then DRY_RUN=yes; fi

    # --managed-only opt-in scope filter (see docs/session-compaction.md and
    # the brief this shipped under): WITHOUT this flag, everything below is a
    # no-op and behavior is byte-identical to before. WITH it, sweep must only
    # ever consider sessions named, one per line, in the allowlist file (see
    # _read_managed_allowlist) — never the whole fleet. n_managed/n_live are
    # computed here (n_managed) and cross-referenced against the sensor's live
    # rows below (n_live) purely for the scope-line report ("N managed, M
    # live"); a stale allowlist entry (named session no longer live) is
    # dropped silently from the table, not reported as a skip.
    #
    # FAIL SAFE: an allowlist that is missing, empty, or has no usable entries
    # (blank/comment-only) means ZERO sessions in scope — full stop, exit 0,
    # right here, before the sensor is even consulted. This must NEVER fall
    # through to the unfiltered fleet-wide fetch below: a misconfigured or
    # accidentally-deleted allowlist compacting the entire host is the exact
    # failure this flag exists to prevent, so "can't determine scope" and
    # "scope is the whole fleet" must never be reachable by the same code
    # path. See tests/test-session-compact-managed.sh for the tamper-verified
    # proof that breaking this exits somewhere other than here.
    MANAGED_FILE="$(_managed_allowlist_file)"
    n_managed=0
    declare -A _MANAGED_SET=()
    if [ "$MANAGED_ONLY" = yes ]; then
      while IFS= read -r _managed_name; do
        [ -n "$_managed_name" ] || continue
        n_managed=$((n_managed+1))
        _MANAGED_SET["$_managed_name"]=1
      done < <(_read_managed_allowlist "$MANAGED_FILE")
      if [ "$n_managed" -eq 0 ]; then
        echo "=== session-compact sweep --managed-only: allowlist ($MANAGED_FILE) is missing, empty, or has no usable entries — 0 sessions in scope. Refusing to fall back to fleet-wide scanning. ==="
        echo "sweep --managed-only: 0 managed, 0 live — 0 session(s) in scope."
        exit 0
      fi
    fi

    # Sweep must SEE every live session, not just ones already past
    # MIN_IDLE — the context trigger can fire well under it — so the sensor
    # is asked for everything (0), unlike report's MIN_IDLE-filtered fetch.
    TSV="$(_fetch_tsv 0)"; rc=$?
    [ "$rc" -eq 0 ] || { echo "session-compact: sensor command failed (exit $rc)" >&2; exit 1; }

    # Apply the scope filter BEFORE the eligibility pass below, not after: a
    # non-managed session must never even reach _sweep_decide, so it can never
    # print as a `skip:` row in the table — it is out of scope, not skipped
    # (see the brief's item 5). n_live counts, of the allowlist's n_managed
    # entries, how many actually matched a row in the sensor's TSV — since
    # the sensor (session-doctor.sh idle-report) only ever enumerates
    # currently-live claude sessions (see its own header comment), "matched a
    # row" and "is live" are the same test; anything else in the allowlist is
    # a stale entry and is dropped here silently (not printed as skip:stale),
    # only counted. TSV is REASSIGNED unconditionally to the filtered result
    # (never `${TSV_FILTERED:-$TSV}` or similar) — an EMPTY filtered result
    # (every allowlist entry stale) must still leave TSV empty, not silently
    # revert to the fleet-wide fetch above. That "no coalescing fallback"
    # property is exactly what tests/test-session-compact-managed.sh's
    # tamper-verified fail-safe assertions exist to pin.
    scope_note=""
    if [ "$MANAGED_ONLY" = yes ]; then
      n_live=0
      TSV_FILTERED=""
      while IFS=$'\t' read -r _row_session _row_rest; do
        [ -n "$_row_session" ] || continue
        if [ -n "${_MANAGED_SET[$_row_session]+x}" ]; then
          n_live=$((n_live+1))
          TSV_FILTERED="${TSV_FILTERED}${_row_session}$(printf '\t')${_row_rest}"$'\n'
        fi
      done <<< "$TSV"
      TSV="$TSV_FILTERED"
      scope_note="; scope: managed-only ($n_managed managed, $n_live live)"
    fi

    window_desc="idle >= ${MIN_IDLE}m"
    [ "$MAX_IDLE" != 0 ] && window_desc="$window_desc, <= ${MAX_IDLE}m"

    echo "=== session-compact sweep --$([ "$DRY_RUN" = yes ] && echo dry-run || echo apply): $window_desc, OR context >= ${_SWEEP_CONTEXT_TRIGGER_PCT}% + idle >= ${_SWEEP_CONTEXT_IDLE_FLOOR}m${scope_note} ==="
    printf '%-32s %-8s %-11s %-6s %-22s %s\n' "SESSION" "IDLE(m)" "CTX_TOKENS" "CTX%" "VERDICT" "NOTE"
    n=0; n_eligible=0; n_compacted=0; n_failed=0
    while IFS=$'\t' read -r c1 c2 c3 c4 c5 c6 c7 c8 c9 c10; do
      [ -n "$c1" ] || continue
      n=$((n+1))

      ctx_raw="$(_context_pct_for_row "$c4")"
      if [ -n "$ctx_raw" ]; then
        ctx_tokens="${ctx_raw%%$'\t'*}"
        ctx_pct="${ctx_raw#*$'\t'}"
        note="-"
      else
        ctx_tokens="n/a"; ctx_pct=""; note="context unavailable (unparseable/missing transcript or unrecognized model) — idle-only fallback"
      fi

      # detail: the underlying _decide/_evaluate_row reason, surfaced in NOTE
      # even when the verdict column already names it (kept for the free-text
      # explanation, not for disambiguation — see below).
      #
      # SUPERSEDES the prior comment here (kept in git history, not repeated):
      # this used to argue for pinning VERDICT to exactly 5 values and
      # collapsing already-compacted/landed-and-clean/malformed-row/
      # never-touched/bad-idle-field into one shared "skip: under thresholds"
      # label, on the theory that NOTE already disambiguates them. In
      # practice that hid real problems: a MALFORMED sensor row and a session
      # that simply isn't idle enough are operationally very different (one
      # is a bug to investigate, the other is normal), but both printed the
      # identical verdict — an operator scanning the VERDICT column alone
      # (the column this table is sorted/skimmed by) could not tell them
      # apart without reading every NOTE. Each cause now gets its own short,
      # distinct label instead. "skip: under thresholds" is preserved for the
      # one case it always correctly described and still describes:
      # skip:outside-window (idle/context genuinely below both trigger
      # thresholds) — that keeps falling through to the wildcard below.
      decision="$(_sweep_decide "$MIN_IDLE" "$MAX_IDLE" "$ctx_pct" "$c1" "$c2" "$c3" "$c4" "$c5" "$c6" "$c7" "$c8" "$c9" "$c10")"
      detail="-"
      case "$decision" in
        eligible:idle)          verdict="would-compact: idle" ;;
        eligible:context)       verdict="would-compact: context" ;;
        skip:protected)         verdict="skip: protected" ;;
        skip:pane-*)            verdict="skip: busy"; detail="live pane: ${decision#skip:pane-}" ;;
        skip:already-compacted) verdict="skip: compacted"; detail="already compacted this idle window" ;;
        skip:landed-and-clean)  verdict="skip: landed+clean"; detail="worktree landed + clean" ;;
        skip:malformed-row)     verdict="skip: malformed row"; detail="malformed sensor row" ;;
        skip:never-touched)     verdict="skip: never touched"; detail="never had a genuine user turn" ;;
        skip:bad-idle-field)    verdict="skip: bad idle field"; detail="unparseable idle field" ;;
        *)                      verdict="skip: under thresholds" ;;
      esac
      if [ "$note" = "-" ]; then
        note="$detail"
      elif [ "$detail" != "-" ]; then
        note="$note; $detail"
      fi
      printf '%-32s %-8s %-11s %-6s %-22s %s\n' "${c1:0:32}" "$c5" "$ctx_tokens" "${ctx_pct:-n/a}" "$verdict" "$note"

      case "$decision" in
        eligible:*)
          n_eligible=$((n_eligible+1))
          if [ "$DRY_RUN" = yes ]; then
            echo "would-compact: $c1 (idle=${c5}m)"
            continue
          fi
          echo "compacting: $c1 (idle=${c5}m) ..."
          result="$(_do_compact "$c1" "$TIMEOUT" "$c4")"; rc2=$?
          if [ "$rc2" -eq 0 ]; then
            _write_marker "$c1" "$c6" "$(_now_iso)" compacted
            n_compacted=$((n_compacted+1))
            echo "  -> compacted: $c1"
          else
            n_failed=$((n_failed+1))
            echo "  -> FAILED ($result): $c1 — NOT writing a success marker" >&2
          fi
          ;;
      esac
    done <<< "$TSV"
    if [ "$DRY_RUN" = yes ]; then
      echo "sweep --dry-run: $n_eligible session(s) would be compacted"
    else
      echo "sweep --apply: $n_eligible eligible, $n_compacted compacted, $n_failed failed"
    fi
    echo "  --- $n session(s) scanned."
    ;;

  before-relay)
    # --timeout is only recognized as a LEADING flag, before the session
    # positional — never after, so a free-form message can never collide
    # with it (session-handoff.sh's own --file check is the same exact-
    # string-before-positional shape).
    TIMEOUT=240
    if [ "${1:-}" = "--timeout" ]; then TIMEOUT="$2"; shift 2; fi
    _validate_uint --timeout TIMEOUT
    SESSION="${1:?usage: session-compact.sh before-relay <tmux-session> (<msg>|--file <path>) [--timeout N]}"; shift
    if [ "${1:-}" = "--file" ]; then
      MSG_ARGS=(--file "${2:?--file needs a path}")
    else
      MSG_ARGS=("${1:?message required}")
    fi

    MIN_IDLE=60; MAX_IDLE=0
    TSV="$(_fetch_tsv 0)"; rc=$?
    [ "$rc" -eq 0 ] || { echo "session-compact: sensor command failed (exit $rc)" >&2; exit 1; }
    row_line="$(printf '%s\n' "$TSV" | awk -F'\t' -v s="$SESSION" '$1==s{print; exit}')"

    if [ -z "$row_line" ]; then
      # Not seen by the sensor at all — we have zero eligibility signal, but
      # we can and must still check the ONE thing that's always unsafe to
      # skip: is the pane actually safe to type into right now. (Bug 1 fix:
      # this branch used to relay unconditionally here, with no pane check.)
      pane_reason="$(_pane_ready_reason "$SESSION")"; pane_rc=$?
      if [ "$pane_rc" -ne 0 ]; then
        echo "before-relay: '$SESSION' not seen by the sensor AND not safe to inject into (${pane_reason}) — refusing to relay" >&2
        exit 1
      fi
      echo "before-relay: '$SESSION' not seen by the sensor — pane is safe, relaying without compacting"
      _session_handoff send "$SESSION" "${MSG_ARGS[@]}"
      exit $?
    fi
    IFS=$'\t' read -r c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 <<< "$row_line"

    decision="$(_evaluate_row "$MIN_IDLE" "$MAX_IDLE" "$c1" "$c2" "$c3" "$c4" "$c5" "$c6" "$c7" "$c8" "$c9" "$c10")"
    case "$decision" in
      eligible) : ;;
      skip:pane-*)
        # The pane-safety check we JUST ran said this pane is not safe to
        # type into (busy / on a menu / no prompt / holding an unsent draft)
        # — fail CLOSED here too, same as the compact-unverified path below.
        # (Bug 1 fix: this used to fall through to a plain relay like any
        # other skip reason, injecting into a pane it had itself just flagged
        # unsafe.)
        echo "before-relay: '$SESSION' is not safe to inject into (${decision#skip:pane-}) — refusing to relay" >&2
        exit 1 ;;
      *)
        echo "before-relay: '$SESSION' not stale/eligible (${decision#skip:}) — relaying without compacting"
        _session_handoff send "$SESSION" "${MSG_ARGS[@]}"
        exit $? ;;
    esac

    echo "before-relay: '$SESSION' is stale and eligible — compacting first"
    result="$(_do_compact "$SESSION" "$TIMEOUT" "$c4")"; rc2=$?
    if [ "$rc2" -ne 0 ]; then
      echo "before-relay: compact of '$SESSION' could not be verified ($result) — FAILING CLOSED, message NOT sent" >&2
      exit 1
    fi
    _write_marker "$SESSION" "$c6" "$(_now_iso)" compacted
    echo "before-relay: compact verified — relaying message"
    _session_handoff send "$SESSION" "${MSG_ARGS[@]}"
    exit $?
    ;;

  install-timer)
    FORCE=no
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) FORCE=yes; shift ;;
        *) echo "session-compact: install-timer: unrecognized argument '$1'" >&2; exit 2 ;;
      esac
    done
    UD="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    STATE_DIR="$HOME/.local/state/session-compact"
    SVC="$UD/session-compact-report.service"
    TMR="$UD/session-compact-report.timer"
    if [ "$FORCE" != yes ] && { [ -f "$SVC" ] || [ -f "$TMR" ]; }; then
      echo "session-compact: install-timer: unit file(s) already exist ($SVC and/or $TMR) — refusing to overwrite without --force" >&2
      exit 2
    fi
    mkdir -p "$UD" "$STATE_DIR"
    cat > "$SVC" <<EOF
[Unit]
Description=session-compact report-only scan (report mode; never mutates)

[Service]
Type=oneshot
ExecStart=$HOME/.local/bin/session-compact report
StandardOutput=append:$STATE_DIR/report.log
StandardError=append:$STATE_DIR/report.log
EOF
    cat > "$TMR" <<EOF
[Unit]
Description=Trigger for session-compact-report.service

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF
    echo "session-compact: wrote $SVC"
    echo "session-compact: wrote $TMR"
    echo "session-compact: NOT enabled (report mode only; no mutation ever happens from this unit)."
    echo "session-compact: to opt in, run:"
    echo "  systemctl --user enable --now session-compact-report.timer"
    ;;

  *) _usage ;;
esac
fi
