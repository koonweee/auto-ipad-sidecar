#!/bin/zsh
set -eu
cd "${0:A:h:h}"
as_test_project=$PWD
as_fixture=$(mktemp -d)
trap 'rm -rf "$as_fixture"' EXIT
mkdir -p "$as_fixture/project/bin" "$as_fixture/tools" "$as_fixture/home/Library/Application Support/AutoSidecar"
sed 's/\$HOME/\$AS_TEST_HOME/g' scripts/install.sh > "$as_fixture/project/install.sh"
print '#!/bin/zsh\nexit 0' > "$as_fixture/project/build.sh"
cat > "$as_fixture/project/bin/auto-sidecar" <<'STUB'
#!/bin/zsh
case "$1" in
  doctor) exit 0;;
  write-launchagent) exec "$AS_REAL_BINARY" "$@";;
  *) exit 99;;
esac
STUB
cat > "$as_fixture/tools/launchctl" <<'STUB'
#!/bin/zsh
case "$1" in
 print)
   if [[ -f "$AS_TEST_HOME/stopping" ]]; then
     remaining=$(<"$AS_TEST_HOME/stopping")
     if (( remaining > 0 )); then
       print $(( remaining - 1 )) > "$AS_TEST_HOME/stopping"
     else
       rm -f "$AS_TEST_HOME/loaded" "$AS_TEST_HOME/stopping"
     fi
   fi
   [[ -f "$AS_TEST_HOME/loaded" ]];;
 bootout)
   if [[ -f "$AS_TEST_HOME/loaded" ]]; then print 3 > "$AS_TEST_HOME/stopping"; fi;;
 bootstrap)
   # Match launchd: the same label cannot bootstrap during asynchronous unload.
   if [[ -f "$AS_TEST_HOME/loaded" ]]; then exit 5; fi
   if [[ -f "$AS_TEST_HOME/fail-once" ]]; then rm "$AS_TEST_HOME/fail-once"; exit 1; fi
   touch "$AS_TEST_HOME/loaded";;
 *) exit 99;;
esac
STUB
chmod +x "$as_fixture/project/"*.sh "$as_fixture/project/bin/auto-sidecar" "$as_fixture/tools/launchctl"
export AS_TEST_HOME="$as_fixture/home"
export AS_REAL_BINARY="$as_test_project/bin/auto-sidecar"
# Only launchctl is mocked; plist serialization, validation, atomic moves and rollback are real.
export PATH="$as_fixture/tools:$PATH"
touch "$AS_TEST_HOME/Library/Application Support/AutoSidecar/config.plist"
"$as_fixture/project/install.sh" "$as_fixture/project/bin/auto-sidecar" >/dev/null
cp "$AS_TEST_HOME/Library/Application Support/AutoSidecar/auto-sidecar" "$as_fixture/expected-binary"
cp "$AS_TEST_HOME/Library/LaunchAgents/local.auto-sidecar.plist" "$as_fixture/expected-plist"
print '# distinguish failed update' >> "$as_fixture/project/bin/auto-sidecar"
touch "$AS_TEST_HOME/fail-once"
if "$as_fixture/project/install.sh" "$as_fixture/project/bin/auto-sidecar" >/dev/null 2>&1; then print -u2 'Expected failed bootstrap';exit 1;fi
cmp "$as_fixture/expected-binary" "$AS_TEST_HOME/Library/Application Support/AutoSidecar/auto-sidecar"
cmp "$as_fixture/expected-plist" "$AS_TEST_HOME/Library/LaunchAgents/local.auto-sidecar.plist"
[[ -f "$AS_TEST_HOME/loaded" ]]
[[ -f "$AS_TEST_HOME/Library/Application Support/AutoSidecar/config.plist" ]]
"$as_fixture/project/install.sh" "$as_fixture/project/bin/auto-sidecar" >/dev/null
cmp "$as_fixture/project/bin/auto-sidecar" "$AS_TEST_HOME/Library/Application Support/AutoSidecar/auto-sidecar"
print 'PASS: fresh installation, asynchronous unload, failed-update rollback, restart previous agent, successful update, retained config'
