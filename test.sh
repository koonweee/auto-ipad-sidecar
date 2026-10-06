#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p bin
/usr/bin/clang -Wall -Wextra -Werror -fobjc-arc -framework Foundation tests/tests.m src/Config.m -o bin/tests
./bin/tests
/usr/bin/clang -Wall -Wextra -Werror -fobjc-arc -framework Foundation tests/dock-tests.m src/Dock.m src/Config.m -o bin/dock-tests
./bin/dock-tests
/bin/zsh -n build.sh auto-sidecar scripts/install.sh scripts/uninstall.sh test.sh
./build.sh
./bin/auto-sidecar --help
./tests/installer.sh
./tests/configure.sh
