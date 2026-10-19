#!/bin/bash
# One step update: build, then install with the macOS password dialog (no Terminal sudo needed).
# Run as your normal user: ./update.sh
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
osascript -e "do shell script \"cd '$PWD' && SUDO_USER='$(id -un)' ./install.sh 2>&1\" with administrator privileges"
cmp -s build/Lidswitch.app/Contents/MacOS/Lidswitch /Applications/Lidswitch.app/Contents/MacOS/Lidswitch \
    && pgrep -qf /Applications/Lidswitch.app/Contents/MacOS/Lidswitch \
    && echo "updated and running" || { echo "update did not take, see output above" >&2; exit 1; }
