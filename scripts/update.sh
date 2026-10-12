#!/bin/zsh
# Pulls the latest Bluey from upstream (origin/main), rebuilds the Mac app and restarts it.
# Commit or stash your local changes first if a merge conflict would lose work.
set -uo pipefail
cd "$(dirname "$0")/.."

git fetch origin
if git merge origin/main; then
    ./scripts/build-mac.sh
    pkill -x GooglyMac 2>/dev/null
    sleep 1
    open "build/Bluey.app"
    echo "Bluey updated and relaunched."
    echo "The iPhone app doesn't auto-update: rebuild it in Xcode (or ask whoever deploys it for you)."
else
    echo "Merge stopped with conflicts — resolve them, then run ./scripts/build-mac.sh yourself."
fi
