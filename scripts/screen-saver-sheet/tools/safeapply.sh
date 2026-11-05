#!/bin/zsh
# safeapply.sh <store> [seconds]: puts a copy of macOS's wallpaper store in place and restarts WallpaperAgent,
# which reads it as it starts, as Safelight's screen saver does. Should the agent not be able to read it
# ("Unable to read Index", after which it uses its defaults, desktop and all), the backup is put back at
# once. Back the store up to $BACKUP first (default: build/screen-saver-sheet/Index.plist), right before
# each test, and put it back with this script when done. Needs a log stream of the agent in $LOG:
#   /usr/bin/log stream --style compact --level debug --predicate 'process == "WallpaperAgent"' > $LOG
set -u
STORE="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
BACKUP=${BACKUP:-build/screen-saver-sheet/Index.plist}
LOG=${LOG:-build/screen-saver-sheet/agent.log}
n=$(wc -l < "$LOG")
cp "$1" "$STORE"; killall -9 WallpaperAgent; echo "applied $1 at $(date +%T)"
for i in {1..20}; do
    sleep 0.2
    if tail -n +$((n + 1)) "$LOG" | grep -q 'Unable to read Index'; then
        cp "$BACKUP" "$STORE"; killall -9 WallpaperAgent
        echo "the agent couldn't read it, so the backup is back:"; tail -n +$((n + 1)) "$LOG" | grep 'Unable to read Index' | head -2
        exit 1
    fi
done
sleep ${2:-3}
tail -n +$((n + 1)) "$LOG" | grep -E 'Initialize screen saver wallpaper for module' | grep BEGIN | tail -1
