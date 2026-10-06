#!/bin/zsh
set -eu
if (( $# > 1 )) || [[ ${1:-} != '' && ${1:-} != '--purge' ]]; then
  print -u2 'Usage: auto-sidecar uninstall [--purge]'; exit 1
fi
as_base="$HOME/Library/Application Support/AutoSidecar"
launchctl bootout "gui/$(id -u)/local.auto-sidecar" 2>/dev/null || true
# Restore any outstanding optional Dock changes before deleting the recovery tool.
if [[ -f "$as_base/dock-restoration.plist" ]]; then
  "$as_base/auto-sidecar" dock-restore || {
    print -u2 'Dock restoration is incomplete. Keeping the binary and restoration record; retry after allowing Automation.'
    exit 1
  }
fi
rm -f "$HOME/Library/LaunchAgents/local.auto-sidecar.plist" "$as_base/auto-sidecar" "$as_base/runtime-config.plist" "$as_base/reload-request.plist" "$as_base/reload-result.plist"
if [[ ${1:-} == '--purge' ]]; then
  rm -f "$as_base/config.plist"
  rm -rf "$HOME/Library/Logs/AutoSidecar"
fi
rmdir "$as_base" 2>/dev/null || true
print 'Automation removed. Without --purge, pairing and logs are retained.'
print 'Removing the watcher can end a headless Sidecar session because it owns the virtual display.'
