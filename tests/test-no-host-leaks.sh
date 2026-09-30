#!/usr/bin/env bash
# test-no-host-leaks.sh — this is a PUBLIC repo. Fail the build if a tracked
# file contains a host-identifying literal: an absolute home path, an email
# address, a bare Environment=HOME=/... unit line, or a github.com URL that
# names an owner other than this repo's own origin.
#
# Design (see docs/genericize-host-specifics PR): this repo must not itself
# carry a curated list of any operator's private names — that would just be a
# second copy of the leak, checked in. So the checks below are split in two:
#
#   1. GENERIC patterns, always run, here in CI and on every fork. These catch
#      only structurally-identifiable host leaks (a real absolute path, a real
#      email, a real github owner) — never a specific operator's vocabulary.
#   2. An OPTIONAL host-specific denylist, read only from a file named by
#      $CRSS_LEAK_DENYLIST (one extended regex per line, '#'-comments and
#      blank lines ignored). CI does not set this var, so CI only ever runs
#      the generic checks. An operator who wants to also catch their own
#      project names, handle, bus/mailbox names, etc. runs:
#
#        CRSS_LEAK_DENYLIST=~/.config/crss/leak-denylist.txt bash tests/test-no-host-leaks.sh
#
#      (a per-host file living OUTSIDE this repo, e.g. under $CRSS_HOME — see
#      examples/crss-overlay/README.md — never committed here).
#
#      A denylist line may carry a per-term exclusion: "<ERE><TAB><globs>",
#      where <globs> is a comma-separated list of path globs (matched against
#      the path as `git ls-files` prints it). The term is then simply not
#      checked against any path matching one of those globs — e.g.
#      `\bxx[_-][a-z]<TAB>tests/*` means "don't check this term under
#      tests/". Use this (not the allowlist below) for a term that some
#      files legitimately need to contain — e.g. tests that pin a host-shaped
#      session-name-prefix fixture — without also exempting those files from
#      every OTHER term. A line with no TAB has no exclusion.
#
# Allowlist: tests/leak-allowlist.txt lists path GLOBS (matched against the
# path exactly as `git ls-files` prints it) that are exempt from ALL checks
# below — e.g. this test's own known-good
# sources. Every entry there needs a reason. Keep it minimal:
# prefer fixing a doc's content over adding a line here.
#
# Output: one "file:line: match  [reason]" per hit, then a FAIL summary.
# Exits non-zero on any hit (generic OR, when set, denylist).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 1

ALLOWLIST="$HERE/leak-allowlist.txt"
hits=0

# ── Load the allowlist (path globs, '#'-comments, blank lines ignored) ──────
allow_globs=()
if [ -f "$ALLOWLIST" ]; then
  while IFS= read -r _al_line || [ -n "$_al_line" ]; do
    _al_line="${_al_line%%#*}"                      # strip trailing comment
    _al_line="${_al_line#"${_al_line%%[![:space:]]*}"}"  # ltrim
    _al_line="${_al_line%"${_al_line##*[![:space:]]}"}"  # rtrim
    [ -n "$_al_line" ] || continue
    allow_globs+=("$_al_line")
  done < "$ALLOWLIST"
fi

_allowed() {  # $1 = path
  local p="$1" g
  for g in "${allow_globs[@]+"${allow_globs[@]}"}"; do
    # shellcheck disable=SC2053
    [[ "$p" == $g ]] && return 0
  done
  return 1
}

# ── Files to scan: every tracked file, minus the allowlist ──────────────────
files=()
while IFS= read -r -d '' f; do
  _allowed "$f" || files+=("$f")
done < <(git ls-files -z)

report() {  # $1 = file, $2 = grep -n output ("line:match"), $3 = reason
  local file="$1" reason="$3" line
  [ -n "$2" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "FAIL: $file:$line  [$reason]"
    hits=$((hits + 1))
  done <<< "$2"
}

# Universally-safe placeholders/domains a generic check must not flag —
# these are not any operator's private data, they're the conventional
# examples this repo (and its docs) use on purpose.
_is_safe_home_user() {
  case "$1" in
    youruser|user|me) return 0 ;;
    *) return 1 ;;
  esac
}
_is_safe_email() {
  case "$1" in
    noreply@anthropic.com|t@t.com) return 0 ;;
    *@example.com|*@example.org) return 0 ;;
    *) return 1 ;;
  esac
}

echo "=== Generic checks (always on — this is what CI runs) ==="

for f in "${files[@]}"; do
  [ -f "$f" ] || continue

  # 1. Absolute home paths: /home/<user>/ except the documented placeholders.
  while IFS=: read -r ln match; do
    [ -n "${ln:-}" ] || continue
    user="${match#/home/}"; user="${user%/}"   # trailing slash is optional: bare /home/<name> leaks too
    _is_safe_home_user "$user" && continue
    echo "FAIL: $f:$ln: $match  [absolute home path — use /home/youruser/, /home/user/, or /home/me/]"
    hits=$((hits + 1))
  done < <(grep -noE '/home/[a-z_][a-z0-9_-]*' "$f" 2>/dev/null)

  # 2. macOS-style absolute home paths.
  report "$f" "$(grep -noE '/Users/[A-Za-z0-9_.-]+/' "$f" 2>/dev/null)" "/Users/ absolute path"

  # 3. This harness's per-session scratch dirs.
  report "$f" "$(grep -noE '/tmp/claude-[0-9]+' "$f" 2>/dev/null)" "/tmp/claude-<pid> scratch path"

  # 4. Email addresses, except the safe/placeholder set.
  while IFS=: read -r ln match; do
    [ -n "${ln:-}" ] || continue
    _is_safe_email "$match" && continue
    echo "FAIL: $f:$ln: $match  [email address — not on the safe/placeholder list]"
    hits=$((hits + 1))
  done < <(grep -noE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$f" 2>/dev/null)

  # 5. A systemd unit's HOME baked in as a literal absolute path (should
  #    always be derived at generation time from $HOME instead).
  report "$f" "$(grep -noE 'Environment=HOME=/[^[:space:]]*' "$f" 2>/dev/null)" "systemd unit hardcodes HOME as a literal path"
done

# ── Extra generic checks (added after a privacy audit found whole classes
#    invisible to the checks above). Still NO private vocabulary: only shapes
#    and this machine's own runtime identity.  HARD = fails the build;
#    WARN = printed, never fails.
_host_name="$(hostname -s 2>/dev/null | tr 'A-Z' 'a-z')"
case "$_host_name" in
  localhost|runner|ubuntu|debian|fedora|centos|alpine|docker|github|server|hostname|machine|buildkitd|builder|codespaces|linux|macbook) _host_name="" ;;
esac
# Too short / too word-like to be a meaningful literal: need >=6 chars or a digit.
if [ "${#_host_name}" -lt 4 ] || { [ "${#_host_name}" -lt 6 ] && [[ "$_host_name" != *[0-9]* ]]; }; then _host_name=""; fi

# Allowances: an sk- token must contain a digit (real keys always do; it keeps
# kebab-case words like "sk-dry-run-still-resolves" from matching), and a
# credential assignment whose value says FAKE/EXAMPLE/PLACEHOLDER/DUMMY/YOUR/HERE/CHANGEME/XXX/LOCAL/REDACTED/TEST (or '...') is a
# self-evidently fake test fixture.
# Secret shapes built from fragments so this file does not match itself.
_SECRET_RE='\bsk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|0x[0-9a-fA-F]{40}([0-9a-fA-F]{24})?\b|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.|Bearer [A-Za-z0-9._-]{20,}'
_SECRET_ASSIGN_RE='(api[_-]?key|token|secret|password)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"'$<{ ][^"'"'"']{12,}'
_BUS_RE='\bbus seq\b|\bseq #[0-9]{3,}\b|scope_claim|coordination_bus|[Oo]perator (directive|ruling)|OPERATOR RULING'
# <word>[_-]<slug>-MMDD-HHMM with a real-looking date. Fixtures stamp 0101-HHMM
# (January 1st) or use placeholders (MMDD, xxxx), so a month of 02-12 is what
# marks a real session name.
_SESSION_RE='\b[A-Za-z]{2,12}[_-][a-z][a-z0-9-]*-(0[2-9]|1[0-2])[0-3][0-9]-[0-2][0-9][0-5][0-9]\b|-20[0-9]{2}(0[2-9]|1[0-2])[0-3][0-9]-[0-9]{4}\b'
_WARN_NARR_RE='(this|our) (host|box|machine|server)\b|on this host|happened for real|[Rr]eal (loss|case|repro)\b|confirmed live'
_WARN_DOMAIN_RE='\b(broker(age)?|execution gate|EXECUTION_APPROVED[A-Za-z_]*|equities|sleeve|portfolio|wallet|book_domain|prereg(istration|istered)?)\b'
# shellcheck disable=SC2088  # a literal "~/" in prose, deliberately unexpanded
_WARN_HOMEDIR_RE='~/(backups|agent-[a-z-]+|research[a-z-]*|\.gbrain|\.sessions)'

_warn() {  # $1 = file, $2 = grep -n output, $3 = reason
  local line
  [ -n "$2" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "WARN: $1:$line  [$3]"
  done <<< "$2"
}

for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  report "$f" "$(grep -noE -- "$_SECRET_RE" "$f" 2>/dev/null | grep -vE ':sk-[A-Za-z-]*$' | grep -viE 'fake|example|placeholder|dummy|your|here|changeme|xxx|local|\.\.\.|redacted|test')" "secret-shaped literal"
  report "$f" "$(grep -noiE -- "$_SECRET_ASSIGN_RE" "$f" 2>/dev/null | grep -viE 'fake|example|placeholder|dummy|your|here|changeme|xxx|local|\.\.\.|redacted|test')" "quoted credential assignment with a literal value"
  report "$f" "$(grep -noE -- "$_BUS_RE" "$f" 2>/dev/null)" "coordination-bus / operator-ruling reference"
  report "$f" "$(grep -noE -- "$_SESSION_RE" "$f" 2>/dev/null)" "real-looking session name (use a 0101-HHMM fixture stamp)"
  if [ -n "$_host_name" ]; then
    report "$f" "$(grep -noiwF -- "$_host_name" "$f" 2>/dev/null)" "this machine's own hostname"
  fi
  _warn "$f" "$(grep -noE -- "$_WARN_NARR_RE" "$f" 2>/dev/null)" "host-narrative phrasing"
  _warn "$f" "$(grep -noE -- "$_WARN_DOMAIN_RE" "$f" 2>/dev/null)" "trading/broker vocabulary"
  _warn "$f" "$(grep -noE -- "$_WARN_HOMEDIR_RE" "$f" 2>/dev/null)" "host-specific ~/ directory"
done

# 6. github.com/<owner>/ other than this repo's own origin owner.
origin_owner=""
if origin_url="$(git remote get-url origin 2>/dev/null)"; then
  origin_owner="$(printf '%s' "$origin_url" | sed -nE 's#.*github\.com[:/]+([A-Za-z0-9_.-]+)/.*#\1#p')"
fi
if [ -n "$origin_owner" ]; then
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    while IFS=: read -r ln match; do
      [ -n "${ln:-}" ] || continue
      owner="${match#github.com/}"; owner="${owner%/}"
      [ "$owner" = "$origin_owner" ] && continue
      [ "$owner" = "fakeorg" ] && continue    # self-evidently-fake test-fixture owner
      [ "$owner" = "garrytan" ] && continue   # README.md's real citation of the upstream
                                               # gstack project this skill is compatible
                                               # with — a legitimate public credit, not a
                                               # leaked private repo
      echo "FAIL: $f:$ln: $match  [github.com owner other than this repo's own origin ($origin_owner)]"
      hits=$((hits + 1))
    done < <(grep -noE 'github\.com/[A-Za-z0-9_.-]+/' "$f" 2>/dev/null)
  done
else
  echo "note: no 'github.com' remote found via git remote get-url origin — skipping the github-owner sub-check"
fi

# ── Host-specific denylist (optional; off in CI) ─────────────────────────────
if [ -n "${CRSS_LEAK_DENYLIST:-}" ]; then
  if [ ! -f "$CRSS_LEAK_DENYLIST" ]; then
    echo "FAIL: CRSS_LEAK_DENYLIST=$CRSS_LEAK_DENYLIST set but not readable" >&2
    hits=$((hits + 1))
  else
    echo "=== Host-specific denylist: $CRSS_LEAK_DENYLIST ==="
    terms=()
    term_excl=()
    while IFS= read -r _dl_line || [ -n "$_dl_line" ]; do
      _dl_line="${_dl_line%%#*}"
      _dl_line="${_dl_line#"${_dl_line%%[![:space:]]*}"}"
      _dl_line="${_dl_line%"${_dl_line##*[![:space:]]}"}"
      [ -n "$_dl_line" ] || continue
      if [[ "$_dl_line" == *$'\t'* ]]; then
        terms+=("${_dl_line%%$'\t'*}")
        term_excl+=("${_dl_line#*$'\t'}")
      else
        terms+=("$_dl_line")
        term_excl+=("")
      fi
    done < "$CRSS_LEAK_DENYLIST"
    _term_excluded() {  # $1 = path, $2 = comma-separated globs (may be empty)
      local p="$1" globs="$2" g
      [ -n "$globs" ] || return 1
      local -a _tg_arr
      IFS=',' read -ra _tg_arr <<< "$globs"
      for g in "${_tg_arr[@]}"; do
        # shellcheck disable=SC2053
        [[ "$p" == $g ]] && return 0
      done
      return 1
    }
    for f in "${files[@]}"; do
      [ -f "$f" ] || continue
      for i in "${!terms[@]}"; do
        term="${terms[$i]}"
        _term_excluded "$f" "${term_excl[$i]}" && continue
        report "$f" "$(grep -noE -- "$term" "$f" 2>/dev/null)" "denylist term: $term"
      done
    done
  fi
else
  echo "(CRSS_LEAK_DENYLIST not set — host-specific checks skipped, generic-only mode, matches CI)"
fi

echo "---"
if [ "$hits" -eq 0 ]; then
  echo "test-no-host-leaks: PASS (0 hits)"
  exit 0
else
  echo "test-no-host-leaks: FAIL ($hits hit(s))"
  exit 1
fi
