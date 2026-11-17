#!/bin/ksh
# SWDL FinalScript for the Wireless CarPlay Maps package.
# Runs the real installer from the card root.

VOLUME="${2}"

if [ -z "$VOLUME" ]; then
    if [ -d /net/mmx/fs/sda0 ]; then
        export VOLUME=/net/mmx/fs/sda0
    elif [ -d /net/mmx/fs/sdb0 ]; then
        export VOLUME=/net/mmx/fs/sdb0
    else
        echo "No SD-cards found."
        exit 0
    fi
fi

# Make SD writable for logging
on -f mmx /bin/mount -uw "$VOLUME" 2>/dev/null || true

LOGDIR="$VOLUME/Log"
LOGFILE="$LOGDIR/install_wireless.txt"
mkdir -p "$LOGDIR" 2>/dev/null || true

# FAT32 has no exec bit - make the payload binaries executable before preflight
on -f mmx /bin/chmod -R a+rx "$VOLUME/payload" 2>/dev/null || true

# The card copy first; fall back to the DEVICE copy (staged at
# /mnt/app/.wmaps-manual by a previous install) - the SWDL
# runs this FinalScript twice (pass 1 -> restart -> pass 2) and the card may
# change between the passes.
INSTALLER="$VOLUME/install.sh"
if [ ! -f "$INSTALLER" ] && [ -f /mnt/app/.wmaps-manual/install.sh ]; then
    INSTALLER=/mnt/app/.wmaps-manual/install.sh
    echo "card copy missing - using the device copy: $INSTALLER"
fi
echo "Running Wireless CarPlay Maps install.sh from $INSTALLER"

on -f mmx /bin/ksh "$INSTALLER" > "$LOGFILE" 2>&1
RC=$?

echo "install.sh exited with rc=$RC"
cat "$LOGFILE" 2>/dev/null || true

# Make SD readonly again
on -f mmx /bin/mount -ur "$VOLUME" 2>/dev/null || true

echo "Done."
touch /tmp/SWDLScript.Result 2>/dev/null || true
exit "$RC"
