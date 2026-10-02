#!/usr/bin/env bash
# session-trust-seed <dir> [<dir>...]
#
# Pre-accept Claude Code's first-launch "Do you trust this folder?" dialog for
# the directory a session is about to run in, so an unattended spawn is never
# parked on a prompt nobody can answer. It writes the same key the CLI writes on
# accept: projects.<key>.hasTrustDialogAccepted = true in the global config
# ($CLAUDE_CONFIG_DIR/.claude.json, else $HOME/.claude.json).
#
# <key> is what the CLI would ask about, not always <dir> (verified live against
# the installed CLI, see tests/test-session-trust-seed.sh):
#   * a git repo or ANY of its worktrees -> the MAIN repo root (the dirname of
#     `git rev-parse --git-common-dir`). Trust given there covers every worktree.
#     Ancestors do NOT confer trust on a git repo, however trusted they are.
#   * a non-git dir -> the dir itself (ancestors would also do; the exact key is
#     harmless and independent of that).
#
# Safe on a file many sessions write: an flock'd read-merge-write, temp file +
# atomic rename, original mode kept, every other key untouched, no write at all
# when already trusted. Missing or invalid JSON is an error (exit 1) and the file
# is never touched. A one-time backup <config>.crss-bak is made before the first
# write. Exit: 0 ok, 1 error, 2 usage.
#
# The CLI takes no lock we can share, so only our own seeders are serialised by
# flock. Against the CLI it is optimistic: size/mtime/sha256 of what was read are
# re-checked just before the rename; on a change it re-reads, re-merges and retries
# (6 tries, jittered), else exits 1 with the file untouched. The remaining race is
# the instant between that re-check and the rename.
# Test-only: CRSS_TRUST_SEED_TEST_HOOK=<shell cmd> runs once between the read and
# the re-check, to simulate a concurrent writer (tests/test-session-trust-seed.sh).
set -u
[ $# -ge 1 ] || { echo "usage: session-trust-seed <dir> [<dir>...]" >&2; exit 2; }
exec python3 - "$@" <<'PY'
import fcntl, hashlib, json, os, random, shutil, subprocess, sys, tempfile, time

def die(msg):
    sys.stderr.write("session-trust-seed: " + msg + "\n")
    sys.exit(1)

def git(path, *args):
    try:
        r = subprocess.run(["git", "-C", path] + list(args), capture_output=True, text=True)
    except OSError:
        return None
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else None

def trust_key(d):
    p = os.path.realpath(d)
    if not os.path.isdir(p):
        die("not a directory: %s" % d)
    common = git(p, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if common:
        common = os.path.realpath(common)
        if os.path.basename(common) == ".git":
            return os.path.dirname(common)
        top = git(p, "rev-parse", "--show-toplevel")  # bare repo / submodule gitdir
        return os.path.realpath(top) if top else common
    return p

cfgdir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~")
cfg = os.path.join(cfgdir, ".claude.json")
keys = []
for d in sys.argv[1:]:
    k = trust_key(d)
    if k not in keys:
        keys.append(k)

def snapshot():
    """(bytes, (size, mtime_ns, sha256)) of the live config, read in one go."""
    with open(cfg, "rb") as f:
        raw = f.read()
        st = os.fstat(f.fileno())
    return raw, (st.st_size, st.st_mtime_ns, hashlib.sha256(raw).hexdigest())

def attempt(hook):
    """One read-merge-write. Returns True when done, False when the file changed
    underneath us (the caller retries from a fresh read)."""
    try:
        raw, sig = snapshot()
        data = json.loads(raw.decode("utf-8"))
    except FileNotFoundError:
        die("%s does not exist; run claude once first (refusing to create it)" % cfg)
    except (OSError, ValueError) as e:
        die("%s is unreadable or not valid JSON (%s); left untouched" % (cfg, e))
    if not isinstance(data, dict) or not isinstance(data.get("projects", {}), dict):
        die("%s has an unexpected shape (want an object with an object 'projects'); left untouched" % cfg)
    projects = data.setdefault("projects", {})
    todo, already = [], []
    for k in keys:
        e = projects.get(k)
        if e is not None and not isinstance(e, dict):
            die("projects[%s] is not an object; left untouched" % k)
        (already if e is not None and e.get("hasTrustDialogAccepted") is True else todo).append(k)
    if not todo:
        for k in already:
            print("trusted (already): " + k)
        return True
    for k in todo:
        projects.setdefault(k, {})["hasTrustDialogAccepted"] = True
    mode = os.stat(cfg).st_mode & 0o7777
    fd, tmp = tempfile.mkstemp(prefix=".claude.json.crss-", dir=cfgdir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)  # the CLI's own format: no re-format churn
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        # One-time backup BEFORE the re-check, so its copy time is not an unchecked window.
        bak = cfg + ".crss-bak"
        if not os.path.exists(bak):
            shutil.copy2(cfg, bak)
        if hook:
            subprocess.run(hook, shell=True, check=False)
        # The CLI takes no lock we can share, so detect a concurrent write by
        # re-reading just before the rename and retry if the file moved.
        try:
            if snapshot()[1] != sig:
                os.unlink(tmp)
                return False
        except OSError:
            os.unlink(tmp)
            return False
        os.replace(tmp, cfg)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise
    for k in already:
        print("trusted (already): " + k)
    for k in todo:
        print("trusted (seeded): " + k)
    return True

lock = open(cfg + ".crss-lock", "a")
fcntl.flock(lock, fcntl.LOCK_EX)
try:
    hook = os.environ.get("CRSS_TRUST_SEED_TEST_HOOK")  # test-only: run once, between read and the recheck
    for i in range(6):
        if attempt(hook if i == 0 else None):
            break
        time.sleep(random.uniform(0.005, 0.05))
    else:
        die("%s kept changing underneath us after 6 tries; left untouched" % cfg)
finally:
    lock.close()
PY
