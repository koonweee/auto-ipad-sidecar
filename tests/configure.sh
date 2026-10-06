#!/bin/zsh
set -eu
cd "${0:A:h:h}"
as_fixture=$(mktemp -d)
trap 'rm -rf "$as_fixture"' EXIT
as_config="$as_fixture/config.plist"
cat > "$as_config" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>version</key><integer>1</integer><key>usbSerial</key><string>TEST-USB</string>
<key>sidecarIdentifier</key><string>TEST-SID</string>
<key>display</key><dict><key>width</key><integer>1920</integer><key>height</key><integer>1080</integer><key>refreshRate</key><integer>60</integer><key>hiDPI</key><true/></dict>
</dict></plist>
PLIST
./bin/auto-sidecar config validate --config "$as_config"
printf '3\n20\n40\n4\nunchanged\nfalse\n1\n2\n5\ny\n' | ./bin/auto-sidecar configure --config "$as_config" > "$as_fixture/output"
[[ $(plutil -extract dock.ipadOnly.size raw -o - "$as_config") == 20 ]]
[[ $(plutil -extract dock.ipadOnly.magnification raw -o - "$as_config") == 40 ]]
[[ $(plutil -extract dock.withOtherDisplays.magnification raw -o - "$as_config") == false ]]
[[ $(plutil -extract withOtherDisplays raw -o - "$as_config") == mirror ]]
[[ $(plutil -extract usbSerial raw -o - "$as_config") == TEST-USB ]]
cp "$as_config" "$as_fixture/before-cancel"
if printf '1\n3\n6\n' | ./bin/auto-sidecar configure --config "$as_config" >/dev/null; then exit 1; fi
cmp "$as_config" "$as_fixture/before-cancel"
printf '3\nunchanged\nunchanged\n4\nunchanged\nunchanged\n5\ny\n' | ./bin/auto-sidecar configure --config "$as_config" >/dev/null
if plutil -extract dock xml1 -o - "$as_config" >/dev/null 2>&1; then exit 1; fi
print 'not a plist' > "$as_config"
if ./bin/auto-sidecar config validate --config "$as_config" >/dev/null 2>&1; then exit 1; fi
print 'PASS: interactive preferences, partial Dock profiles, removal, pairing preservation, cancelled save, manual validation'
