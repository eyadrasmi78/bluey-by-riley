#!/bin/zsh
# Pulls the latest Bluey from upstream (origin/main), rebuilds the Mac app and restarts it.
# Shows what is coming and asks first; only fast-forwards, so it never rewrites your own commits.
set -uo pipefail
cd "$(dirname "$0")/.."

EXPECTED="https://github.com/rbrown101010/bluey-by-riley"
ORIGIN=$(git remote get-url origin 2>/dev/null || true)
if [[ "${ORIGIN%.git}" != "$EXPECTED" ]]; then
    echo "origin is '$ORIGIN', not $EXPECTED. Refusing to update from an unexpected source."
    exit 1
fi

git fetch origin
if [[ -z "$(git log --oneline HEAD..origin/main)" ]]; then
    echo "Already up to date."
    exit 0
fi
echo "Incoming changes from upstream (this code will be built and run on your Mac):"
git log --oneline HEAD..origin/main
echo
read -q "?Apply these? [y/N] " || { echo; echo "Cancelled."; exit 1; }
echo
if git merge --ff-only origin/main; then
    ./scripts/build-mac.sh
    pkill -x GooglyMac 2>/dev/null
    sleep 1
    open "build/Bluey.app"
    echo "Bluey updated and relaunched."
    echo "The iPhone app doesn't auto-update: rebuild it in Xcode (or ask whoever deploys it for you)."
else
    echo "Can't fast-forward (your branch has its own commits). Merge origin/main yourself after reviewing it."
fi
