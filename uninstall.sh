#!/bin/sh
# Wireless CarPlay Maps for MU1447 - MANUAL SSH UNINSTALL / ROLLBACK
#
# Restores the first baseline written by ./install.sh. Validates the whole
# manifest before restoring anything, and deletes MISSING-marked targets (the
# installer created them; the factory had none).
#
# Same QNX ksh limits as install.sh: no date/wc/find/printf/env/tr/cmp, no CRLF,
# no "set -u". Commands used: awk cat chmod cp grep ls mkdir mount mv rm sh slay sync.

PATH=/proc/boot:/bin:/usr/bin:/usr/sbin:/sbin:/armle/bin:/armle/sbin:/armle/usr/bin:/armle/usr/sbin
export PATH

SELF_DIR=$(cd "$(dirname "$0")" && pwd)

ROOT=/mnt/app/carplaymaps
# Same location as install.sh: outside the snapshotted tree.
BAK=/mnt/app/.carplaymaps-first-baseline
PERSIST=/mnt/persist

say() { echo "### $*"; }
die() { echo "CPMAP_MANUAL_FAIL=$1"; exit 1; }
ok()  { echo "CPMAP_OK=$1"; }

[ -s "$BAK/MANIFEST" ] || die NO_FIRST_BASELINE
[ ! -e /dev/ipod0 ]    || die DISCONNECT_CARPLAY_FIRST

say "stopping project children"
for n in carplay-cluster-supervisor altscreen-most-bridge carplay-pairing-helper; do
    slay -f "$n" >/dev/null 2>&1 || true
done
for f in /dev/shmem/wcp_receiver.pid /dev/shmem/wcp_video.pid; do
    if [ -f "$f" ]; then
        P=$(cat "$f" 2>/dev/null)
        case "$P" in ''|*[!0-9]*) : ;; *) kill "$P" 2>/dev/null || true ;; esac
        rm -f "$f"
    fi
done
ok STOPPED

say "remount read-write"
for p in /mnt/app /mnt/ota /mnt/system /mnt/persist; do
    mount -uw "$p" 2>/dev/null || true
done

# Validate the whole baseline before restoring a single target.
while read -r state path; do
    case "$state" in
        PRESENT)
            [ -s "$BAK/files$path" ] || die BASELINE_FILE_MISSING_$path ;;
        MISSING)
            case "$path" in /mnt/*) : ;; *) die BAD_MANIFEST_PATH_$path ;; esac ;;
        RUNTIME_PRESENT|RUNTIME_MISSING)
            : ;;
        *)
            die BAD_MANIFEST_STATE_$state ;;
    esac
done < "$BAK/MANIFEST"
ok BASELINE_VALID

say "restoring tracked files"
S_TMP=/ramdisk/.wmaps-restore-$$
mkdir -p "$S_TMP" || die RESTORE_STAGE_FAILED
while read -r state path; do
    case "$state" in
        PRESENT)
            mkdir -p "${path%/*}" || die RESTORE_MKDIR_FAILED_$path
            cp -p "$BAK/files$path" "$S_TMP/restore" || die RESTORE_STAGE_FAILED_$path
            mv -f "$S_TMP/restore" "$path"           || die RESTORE_FAILED_$path ;;
        MISSING)
            rm -f "$path" || die RESTORE_REMOVE_FAILED_$path ;;
    esac
done < "$BAK/MANIFEST"
ok RESTORED_FILES

say "restoring runtime tree"
RT=$(awk '$1=="RUNTIME_PRESENT"{print "yes"} $1=="RUNTIME_MISSING"{print "no"}' "$BAK/MANIFEST")
[ ! -L "$ROOT" ] || die RUNTIME_IS_SYMLINK
rm -rf "$ROOT" || die RUNTIME_REMOVE_FAILED
if [ "$RT" = "yes" ]; then
    [ -d "$BAK/runtime" ] || die RUNTIME_BASELINE_MISSING
    cp -pR "$BAK/runtime" "$ROOT" || die RUNTIME_RESTORE_FAILED
fi
ok RUNTIME_RESTORED

say "cleaning project state"
rm -f "$PERSIST/btwcp_enable" "$PERSIST/btwcp_present_target" \
      "$PERSIST/wcp_autostart" "$PERSIST/wcp_cp_stage" \
      "$PERSIST/v75-wireless-display.conf"
rm -rf "$PERSIST/wcp" "$PERSIST/omonob-phone"
rm -f /dev/shmem/wcp_receiver.pid /dev/shmem/wcp_video.pid 2>/dev/null || true
sync
ok CLEANED

say "done"
ok MANUAL_UNINSTALL_COMPLETE
echo "Restart the unit manually to return the HMI to its factory classpath."
echo "Baseline kept at $BAK for inspection; delete it yourself once satisfied."
exit 0
