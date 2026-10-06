#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p bin
/usr/bin/xxd -i scripts/install.sh > bin/InstallScripts.h
/usr/bin/xxd -i scripts/uninstall.sh >> bin/InstallScripts.h
/usr/bin/clang -Wall -Wextra -Werror -fobjc-arc -framework Foundation -framework AppKit -framework CoreGraphics -framework IOKit src/auto-sidecar.m src/Config.m src/Dock.m -o bin/auto-sidecar
