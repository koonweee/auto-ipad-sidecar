#!/bin/zsh
# Internal helper embedded in the executable; receives the source binary as $1.
set -eu
as_binary="$1"
as_base="$HOME/Library/Application Support/AutoSidecar"
as_logs="$HOME/Library/Logs/AutoSidecar"
as_plist="$HOME/Library/LaunchAgents/local.auto-sidecar.plist"
as_domain="gui/$(id -u)"
as_job="$as_domain/local.auto-sidecar"
"$as_binary" doctor >/dev/null
mkdir -p "$as_base" "$as_logs" "${as_plist:h}"
as_staging=$(mktemp -d "$as_base/.install.XXXXXX")
as_loaded=0
as_changed=0
if launchctl print "$as_job" >/dev/null 2>&1; then as_loaded=1; fi
[[ ! -f "$as_base/auto-sidecar" ]] || cp "$as_base/auto-sidecar" "$as_staging/old-binary"
[[ ! -f "$as_plist" ]] || cp "$as_plist" "$as_staging/old-plist"
rollback() {
  as_result=$?
  trap - EXIT
  if (( as_result != 0 && as_changed )); then
    launchctl bootout "$as_job" >/dev/null 2>&1 || true
    if [[ -f "$as_staging/old-binary" ]]; then mv -f "$as_staging/old-binary" "$as_base/auto-sidecar"; else rm -f "$as_base/auto-sidecar"; fi
    if [[ -f "$as_staging/old-plist" ]]; then mv -f "$as_staging/old-plist" "$as_plist"; else rm -f "$as_plist"; fi
    if (( as_loaded )); then launchctl bootstrap "$as_domain" "$as_plist" || print -u2 'Could not restart previous version; see logs.'; fi
    print -u2 'Installation failed; previous installed files restored.'
  fi
  rm -rf "$as_staging"
  exit "$as_result"
}
trap rollback EXIT
trap 'exit 130' INT TERM
cp "$as_binary" "$as_staging/new-binary"
"$as_binary" write-launchagent "$as_base/auto-sidecar" "$as_staging/new-plist" "$as_logs"
plutil -lint "$as_staging/new-plist"
if (( as_loaded )); then launchctl bootout "$as_job"; fi
as_changed=1
mv -f "$as_staging/new-binary" "$as_base/auto-sidecar"
mv -f "$as_staging/new-plist" "$as_plist"
launchctl bootstrap "$as_domain" "$as_plist"
launchctl print "$as_job" >/dev/null
print
print 'AutoSidecar is installed and running.'
print 'It will start automatically each time you log in to this Mac.'
print 'Connect your enrolled iPad by USB to start Sidecar.'
print
print 'To remove the automation (keep your pairing and logs):'
printf '  "%s/auto-sidecar" uninstall\n' "$as_base"
print 'To also delete your pairing and logs:'
printf '  "%s/auto-sidecar" uninstall --purge\n' "$as_base"
print
printf 'Logs: %s\n' "$as_logs"
