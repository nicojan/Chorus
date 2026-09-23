#!/bin/zsh
# Installs the memory sampler as a LaunchAgent so it survives sleep and reboot.
# Idempotent: re-running replaces the loaded agent with the current plist.
set -e
REPO=${0:A:h:h}
LABEL=com.nicojan.chorus-mem-sampler
DEST=$HOME/Library/LaunchAgents/$LABEL.plist
mkdir -p $HOME/Library/LaunchAgents
sed -e "s|REPO_PATH|$REPO|g" -e "s|HOME_PATH|$HOME|g" \
    $REPO/scripts/$LABEL.plist > $DEST
launchctl bootout gui/$UID/$LABEL 2>/dev/null || true
launchctl bootstrap gui/$UID $DEST
print "loaded $LABEL — samples land in $HOME/Library/Logs/chorus-mem.csv"
print "remove with: launchctl bootout gui/$UID/$LABEL && rm $DEST"
