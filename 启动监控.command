#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
if [[ ! -x 'build/Codex Monitor.app/Contents/MacOS/CodexMonitor' ]]; then
  /bin/zsh ./build.sh
fi
open 'build/Codex Monitor.app'
