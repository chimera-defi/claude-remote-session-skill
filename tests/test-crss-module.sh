#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
SCRIPT="$HERE/../scripts/crss-module.sh"
export CRSS_HOME="$CRSS_TEST_TMP/overlay with spaces"
export CRSS_BIN_DIR="$CRSS_TEST_TMP/bin with spaces"
export MODULE_LOG="$CRSS_TEST_TMP/module.log"

out="$(bash "$SCRIPT" list)"; rc=$?
ok 'missing modules directory succeeds' "$rc" 0
ok 'missing modules directory lists nothing' "$out" ''
mkdir -p "$CRSS_HOME/modules"
ok 'empty modules directory lists nothing' "$(bash "$SCRIPT" list)" ''
ok 'install all without modules succeeds' "$(yn bash "$SCRIPT" install --all)" yes

mkdir -p "$CRSS_HOME/modules/demo" "$CRSS_HOME/modules/other"
cat > "$CRSS_HOME/modules/demo/install.sh" <<'HOOK'
#!/usr/bin/env bash
printf '%s\n' "$CRSS_MODULE_DIR" "$CRSS_BIN_DIR" "$CRSS_DRY_RUN" > "$MODULE_LOG"
HOOK
chmod +x "$CRSS_HOME/modules/demo/install.sh"
out="$(bash "$SCRIPT" list)"
has 'list reports installer present' "$out" $'demo\tinstall.sh: present'
has 'list reports installer missing' "$out" $'other\tinstall.sh: missing'
ok 'path resolves module' "$(bash "$SCRIPT" path demo)" "$CRSS_HOME/modules/demo"
ok 'install succeeds' "$(yn bash "$SCRIPT" install demo)" yes
ok 'install receives environment' "$(cat "$MODULE_LOG")" "$(printf '%s\n' "$CRSS_HOME/modules/demo" "$CRSS_BIN_DIR" 0)"
ok 'default bin directory' "$(env -u CRSS_BIN_DIR bash "$SCRIPT" install demo && sed -n '2p' "$MODULE_LOG")" "$HOME/.local/bin"
ok 'dry run succeeds' "$(yn bash "$SCRIPT" install demo --dry-run)" yes
ok 'dry run reaches installer' "$(sed -n '3p' "$MODULE_LOG")" 1

cat > "$CRSS_HOME/modules/other/install.sh" <<'HOOK'
#!/usr/bin/env bash
printf 'other:%s\n' "$CRSS_DRY_RUN" >> "$MODULE_LOG"
HOOK
chmod +x "$CRSS_HOME/modules/other/install.sh"
ok 'install all succeeds' "$(yn bash "$SCRIPT" install --all)" yes
has 'install all runs both modules' "$(cat "$MODULE_LOG")" other:0
ok 'install all dry run succeeds' "$(yn bash "$SCRIPT" install --all --dry-run)" yes
has 'install all forwards dry run' "$(cat "$MODULE_LOG")" other:1

cat > "$CRSS_HOME/modules/demo/test.sh" <<'HOOK'
#!/usr/bin/env bash
printf 'tested:%s\n' "$CRSS_MODULE_DIR"
exit 7
HOOK
chmod +x "$CRSS_HOME/modules/demo/test.sh"
out="$(bash "$SCRIPT" test demo)"; rc=$?
ok 'test runs hook' "$out" "tested:$CRSS_HOME/modules/demo"
ok 'test propagates exit code' "$rc" 7
out="$(bash "$SCRIPT" test other 2>&1)"; rc=$?
ok 'missing test hook rejected' "$rc" 2
has 'missing test hook diagnostic' "$out" 'requires executable test.sh'

for name in 'Bad-name' '../demo' 'demo/other' ''; do
  for command in install test path; do
    out="$(bash "$SCRIPT" "$command" "$name" 2>&1)"; rc=$?
    ok "$command rejects invalid name '$name'" "$rc" 2
    has "$command explains invalid name '$name'" "$out" 'invalid module name'
  done
done
out="$(bash "$SCRIPT" install absent 2>&1)"; rc=$?
ok 'missing module rejected' "$rc" 2
has 'missing module diagnostic' "$out" 'module not found'
rm "$CRSS_HOME/modules/other/install.sh"
out="$(bash "$SCRIPT" install other 2>&1)"; rc=$?
ok 'missing installer rejected' "$rc" 2
has 'missing installer diagnostic' "$out" 'requires executable install.sh'
chmod -x "$CRSS_HOME/modules/demo/install.sh"
out="$(bash "$SCRIPT" install demo 2>&1)"; rc=$?
ok 'nonexecutable installer rejected' "$rc" 2
printf '#!/usr/bin/env bash\nexit 23\n' > "$CRSS_HOME/modules/demo/install.sh"
chmod +x "$CRSS_HOME/modules/demo/install.sh"
bash "$SCRIPT" install demo; rc=$?
ok 'install propagates exit code' "$rc" 23
bash "$SCRIPT" install --all; rc=$?
ok 'install all propagates first failure' "$rc" 23

# Resolve defaults without consulting a real overlay or config loader.
ok 'XDG overlay default' "$(env -u CRSS_HOME XDG_CONFIG_HOME="$CRSS_TEST_TMP" bash "$SCRIPT" list)" ''
mkdir -p "$CRSS_TEST_TMP/home/.config/crss/modules/default"
ok 'HOME overlay default' "$(env -u CRSS_HOME -u XDG_CONFIG_HOME HOME="$CRSS_TEST_TMP/home" bash "$SCRIPT" path default)" "$CRSS_TEST_TMP/home/.config/crss/modules/default"
finish test-crss-module
