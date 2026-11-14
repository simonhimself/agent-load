#!/bin/zsh
# Runs the Swift Testing unit tests. With only the Command Line Tools installed (no Xcode),
# SwiftPM does not find Testing.framework by itself, so we pass its location explicitly.
set -euo pipefail
cd "${0:A:h}/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L "$@"
