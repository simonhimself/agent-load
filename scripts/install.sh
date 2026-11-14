#!/bin/zsh
# Builds Agent Load and installs it as a regular app in /Applications, then (re)starts it.
#   scripts/install.sh
# Run it again after pulling changes to update the installed copy.
set -euo pipefail
cd "${0:A:h}/.."

scripts/build-app.sh
pkill -TERM -x AgentLoad 2>/dev/null && sleep 1 || true   # quit the running copy, if any
rm -rf "/Applications/Agent Load.app"
ditto "build/Agent Load.app" "/Applications/Agent Load.app"
open "/Applications/Agent Load.app"
echo "Installed /Applications/Agent Load.app"
