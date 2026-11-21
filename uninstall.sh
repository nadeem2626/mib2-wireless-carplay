#!/bin/sh
# Wireless CarPlay Maps for MU1447 - MANUAL SSH UNINSTALL / ROLLBACK
#
# Restores the first baseline written by ./install.sh (the factory bytes).
#
# Order of work - nothing on the unit is touched until every read-only proof passed:
#   1. tool gate + single-run lock
#   2. PROVE the baseline: manifest structure, the six FACTORY files against the
#      frozen cksum constants, and (when present) the per-file CKSUMS record
#   3. stop project processes (identity-checked, TERM only) and confirm they are gone
#   4. remount rw and probe
#   5. STAGE every restore file next to its target (same filesystem) and verify
#      each staged copy against the baseline - the live files are still untouched
#   6. ACTIVATE by atomic rename (never an in-place overwrite, so a running binary
#      such as dio_manager or btstack is replaced safely)
#   7. delete files the installer created, swap the runtime tree back
#   8. clean project state, VERIFY the unit equals the baseline, audit
#
# Safe to re-run: the baseline is never modified, so a partial run can simply be
# repeated. Same QNX ksh limits as install.sh: no date/wc/find/printf/env/tr/cmp,
# no CRLF, no "set -u".

PATH=/proc/boot:/bin:/usr/bin:/usr/sbin:/sbin:/armle/bin:/armle/sbin:/armle/usr/bin:/armle/usr/sbin
export PATH

ROOT=/mnt/app/carplaymaps
# Same location as install.sh: outside the snapshotted tree.
BAK=/mnt/app/.carplaymaps-first-baseline
PERSIST=/mnt/persist
OTA=/mnt/ota
LSDBAK=/mnt/app/eso/hmi/lsd
PRODDIR=/mnt/system/etc/eso/production

# Every flag/state file this project (scripts, receiver, jars, libbtwcp) can create
# in /mnt/persist. One list, used by the clean check, the cleanup and the audit.
PROJECT_FLAGS="btwcp_enable btwcp_present_target btwcp_off btwcp_phonemac \
 wcp_autostart wcp_cp_stage wcp_cp_off wcp_autofront_off wcp_debug \
 wcp_touch_off wcp_touch_inject wcp_si_off wcp_si_addr wcp_hs_off \
 wcp_pfwatch_off wcp_btaudio_release altscreen_smallcard \
 altscreen.conf altscreen.geom v75-wireless-display.conf"

LOCK=/ramdisk/.wmaps-manual.lock
LOCK_OWNED=0
STAGED=/ramdisk/.wmaps-staged-$$
RT_NEW="$ROOT.wmaps-new"
RT_OLD="$ROOT.wmaps-old"
ACTIVATING=0

say() { echo "### $*"; }
ok()  { echo "CPMAP_OK=$1"; }

# Removes every staged-but-not-activated temp file and releases the lock. Called
# by die() and on normal exit, so a failure never leaves *.wmaps-restore litter.
cleanup() {
    if [ -f "$STAGED" ]; then
        while read -r p; do
            [ -n "$p" ] && rm -f "$p.wmaps-restore"
        done < "$STAGED"
        rm -f "$STAGED"
    fi
    [ "$LOCK_OWNED" = 1 ] && rm -rf "$LOCK"
    return 0
}

die() {
    echo "CPMAP_MANUAL_FAIL=$1"
    if [ "$ACTIVATING" = 1 ]; then
        echo "### Restore stopped part-way. The baseline is untouched: fix the cause and run ./uninstall.sh again."
    else
        echo "### Nothing on the unit was changed by this run."
    fi
    cleanup
    exit 1
}

# ------------------------------------------------------------------ tool gate ---
# Every command this script runs must exist BEFORE anything is touched. A missing
# tool surfacing midway would leave a half-restored unit.
for t in awk cat cp grep ls mkdir mount mv rm sleep slay sync pidin kill; do
    command -v "$t" >/dev/null 2>&1 || die REQUIRED_TOOL_MISSING_$t
done

mkdir "$LOCK" 2>/dev/null || die ANOTHER_RUN_ACTIVE_OR_STALE_LOCK_$LOCK
LOCK_OWNED=1

# Identity-checked process stop. A pid file alone proves nothing: only a live pid
# whose pidin line matches one of the expected names gets TERM (never KILL).
# A process that ignores TERM, or is stuck in a driver call, must NOT block the
# restore: every restored file is replaced by an atomic rename, which is safe while
# the old file is still running (install.sh does the same to the running btstack and
# dio_manager), and the unit is restarted afterwards anyway. It is reported instead.
STILL_RUNNING=0
is_zombie() { pidin -p "$1" 2>/dev/null | grep -q ZOMBIE; }
stop_pid() {   # $1 = pid file, $2 = space-separated expected names
    [ -f "$1" ] || return 0
    P=$(cat "$1" 2>/dev/null)
    case "$P" in ''|*[!0-9]*) rm -f "$1"; return 0 ;; esac
    if kill -0 "$P" 2>/dev/null; then
        info=$(pidin -p "$P" 2>/dev/null)
        match=0
        for nm in $2; do
            echo "$info" | grep -q "$nm" && match=1
        done
        if [ "$match" = 1 ]; then
            kill "$P" 2>/dev/null
            i=0
            while [ "$i" -lt 8 ] && kill -0 "$P" 2>/dev/null && ! is_zombie "$P"; do
                sleep 1
                i=$((i+1))
            done
            # an exited process that is only waiting to be reaped counts as stopped
            if kill -0 "$P" 2>/dev/null && ! is_zombie "$P"; then
                STILL_RUNNING=$((STILL_RUNNING+1))
                say "WARNING: pid $P ($2) ignored TERM and is still running - continuing"
            fi
        fi
    fi
    rm -f "$1"
}

# ---------------------------------------------------------------- file fingerprint ---
# Prints "<token> <size>" for a file. The token is the cksum CRC when the unit has
# cksum (then the frozen FACTORY constants below are compared exactly), else the
# digest of md5sum/sha1sum/sha256sum/sum, else "-" (size-only). The size always
# comes from ls -ln, the same way this project already reads sizes.
FSUM_MODE=size
for t in cksum md5sum sha1sum sha256sum sum; do
    if command -v "$t" >/dev/null 2>&1; then FSUM_MODE=$t; break; fi
done
fsize() { ls -ln "$1" 2>/dev/null | awk '{print $5}'; }
fsum() {
    case "$FSUM_MODE" in
        cksum) cksum "$1" 2>/dev/null | awk '{print $1" "$2}' ;;
        size)  s=$(fsize "$1"); [ -n "$s" ] && echo "- $s" ;;
        *)     t=$($FSUM_MODE "$1" 2>/dev/null | awk '{print $1}'); s=$(fsize "$1")
               [ -n "$t" ] && [ -n "$s" ] && echo "$t $s" ;;
    esac
}
# Frozen factory constants are cksum values. With any other tool only the exact
# size can be compared, and a marker scan (text_is_clean) backs it up.
factory_match() {   # $1 = found "<tok> <size>", $2 = expected "<cksum> <size>"
    if [ "$FSUM_MODE" = cksum ]; then [ "$1" = "$2" ]; else [ "${1##* }" = "${2##* }" ]; fi
}
text_is_clean() {   # no project marker inside a factory text file
    ! grep -q -e carplaymaps -e btstack_wrap -e CarPlayWireless- -e OMONOB_WMAPS "$1" 2>/dev/null
}
if [ "$FSUM_MODE" != cksum ]; then
    say "NOTICE: this unit has no cksum (fingerprint mode: $FSUM_MODE)."
    say "        factory proof = exact size + marker scan; copy checks compare $FSUM_MODE/size."
fi

cksum_of() { fsum "$1"; }   # kept name used below

# ------------------------------------------------------------ preconditions ---
[ -s "$BAK/MANIFEST" ]             || die NO_FIRST_BASELINE
[ ! -e /dev/ipod0 ]                || die DISCONNECT_CARPLAY_FIRST
[ ! -e /dev/shmem/wcp_cp_session ] || die DISCONNECT_CARPLAY_FIRST
[ ! -L "$ROOT" ]                   || die RUNTIME_IS_SYMLINK

# FACTORY constants - identical to install.sh, sourced from the clean-unit
# dump. The baseline copies must match these BEFORE any restore runs.
FACTORY_CKSUM_lsd=3139215696;           FACTORY_SIZE_lsd=16155
FACTORY_CKSUM_bundles=4264858563;        FACTORY_SIZE_bundles=13121
FACTORY_CKSUM_connectivity=3506558296;  FACTORY_SIZE_connectivity=8699
FACTORY_CKSUM_si=3242712254;            FACTORY_SIZE_si=7360
FACTORY_CKSUM_dio=2190598061;           FACTORY_SIZE_dio=686481
FACTORY_CKSUM_btstack=3795474524;        FACTORY_SIZE_btstack=1846505

baseline_expect() {     # $1 = short key; prints the expected "<cksum> <size>"
    case "$1" in
        lsd)          echo "$FACTORY_CKSUM_lsd $FACTORY_SIZE_lsd" ;;
        bundles)      echo "$FACTORY_CKSUM_bundles $FACTORY_SIZE_bundles" ;;
        connectivity) echo "$FACTORY_CKSUM_connectivity $FACTORY_SIZE_connectivity" ;;
        si)           echo "$FACTORY_CKSUM_si $FACTORY_SIZE_si" ;;
        dio)          echo "$FACTORY_CKSUM_dio $FACTORY_SIZE_dio" ;;
        btstack)      echo "$FACTORY_CKSUM_btstack $FACTORY_SIZE_btstack" ;;
    esac
}

# ---------------------------------------------- 1. manifest structure (read-only) ---
say "validating baseline manifest"
NPRESENT=0
RT=
while read -r state path; do
    case "$state" in
        '') continue ;;
        PRESENT|MISSING)
            case "$path" in
                /mnt/*) : ;;
                *) die BAD_MANIFEST_PATH_$path ;;
            esac
            case "$path" in
                *..*) die BAD_MANIFEST_PATH_$path ;;
            esac
            if [ "$state" = PRESENT ]; then
                [ -s "$BAK/files$path" ] || die BASELINE_FILE_MISSING_$path
                NPRESENT=$((NPRESENT+1))
            fi ;;
        RUNTIME_PRESENT) RT=yes ;;
        RUNTIME_MISSING) RT=no ;;
        *) die BAD_MANIFEST_STATE_$state ;;
    esac
done < "$BAK/MANIFEST"
[ -n "$RT" ] || die BAD_MANIFEST_NO_RUNTIME_STATE
if [ "$RT" = yes ]; then
    for f in core.so wireless-entry VERSION; do
        [ -s "$BAK/runtime/$f" ] || die BASELINE_RUNTIME_INCOMPLETE_$f
    done
fi
ok BASELINE_VALID

# ---------------------------------------- 2. original-bytes proof (read-only) ---
# Every FACTORY file must still hold the factory bytes inside the baseline, or the
# whole uninstall refuses. A restore from a non-original baseline would be
# worthless - that is the one thing this script may never do.
say "verifying baseline still holds factory bytes"
for pair in \
    "lsd:/mnt/app/eso/hmi/lsd/lsd.sh" \
    "bundles:/mnt/app/eso/hmi/lsd/config/bundles.properties" \
    "connectivity:/mnt/system/etc/eso/production/connectivity.json" \
    "si:/mnt/system/etc/eso/production/smartphone_integrator.json" \
    "dio:/mnt/app/eso/bin/apps/dio_manager" \
    "btstack:/mnt/app/eso/bin/apps/btstack" \
  ; do
    key=${pair%%:*}; path=${pair#*:}
    if [ ! -s "$BAK/files$path" ]; then
        say "baseline copy of $path is missing"
        die BASELINE_NOT_FACTORY_MISSING_$key
    fi
    found=$(cksum_of "$BAK/files$path")
    expect=$(baseline_expect "$key")
    if ! factory_match "$found" "$expect"; then
        say "baseline $path is not the factory original"
        say "expected cksum/size: $expect"
        say "found    $FSUM_MODE/size: $found"
        die BASELINE_NOT_FACTORY_$key
    fi
    if [ "$FSUM_MODE" != cksum ]; then
        case "$key" in
            lsd|bundles|connectivity|si)
                text_is_clean "$BAK/files$path" || die BASELINE_NOT_FACTORY_MARKERS_$key ;;
        esac
    fi
done
ok BASELINE_VERIFIED_ORIGINAL

# Per-file integrity record written by install.sh at snapshot time. It covers the
# files that have no frozen factory constant (connectionmanager, jars, ...).
if [ -s "$BAK/CKSUMS" ]; then
    REC_MODE=$(cat "$BAK/FSUM_MODE" 2>/dev/null)
    [ -n "$REC_MODE" ] || REC_MODE=cksum
    while read -r ck sz path; do
        [ -n "$path" ] || continue
        found=$(cksum_of "$BAK/files$path")
        if [ "$REC_MODE" = "$FSUM_MODE" ]; then
            [ "$found" = "$ck $sz" ] || die BASELINE_FILE_CORRUPT_$path
        else
            [ "${found##* }" = "$sz" ] || die BASELINE_FILE_CORRUPT_$path   # tool differs: size only
        fi
    done < "$BAK/CKSUMS"
    ok BASELINE_CKSUMS_VERIFIED
else
    say "NOTE: this baseline has no CKSUMS record (older installer); only the six factory files are proven"
fi

# ------------------------------------------------- already clean? (read-only) ---
# A second SWDL lap (or any repeated run) finds the unit already restored. Then there
# is nothing to do and NOTHING is written: no needless flash writes, no power-cut
# window. The baseline was proven above, so "equals the baseline" is a real claim.
say "checking whether the unit is already at the baseline"
DIRTY=0
while read -r state path; do
    case "$state" in
        PRESENT)
            [ "$(cksum_of "$path")" = "$(cksum_of "$BAK/files$path")" ] || DIRTY=$((DIRTY+1)) ;;
        MISSING)
            [ ! -e "$path" ] || DIRTY=$((DIRTY+1)) ;;
    esac
    [ "$DIRTY" = 0 ] || break
done < "$BAK/MANIFEST"
# runtime tree: a "no runtime" baseline needs ROOT gone; a restored runtime tree
# cannot be compared cheaply, so that case always takes the (idempotent) full path.
[ "$RT" = no ]            || DIRTY=$((DIRTY+1))
[ ! -e "$ROOT" ]          || DIRTY=$((DIRTY+1))
[ ! -e "$RT_NEW" ]        || DIRTY=$((DIRTY+1))
[ ! -e "$RT_OLD" ]        || DIRTY=$((DIRTY+1))
for f in $PROJECT_FLAGS; do
    [ ! -e "$PERSIST/$f" ] || DIRTY=$((DIRTY+1))
done
[ ! -e "$PERSIST/wcp" ]          || DIRTY=$((DIRTY+1))
[ ! -e "$PERSIST/omonob-phone" ] || DIRTY=$((DIRTY+1))
if [ "$DIRTY" = 0 ]; then
    say "unit already equals the baseline - nothing to do, nothing written"
    cleanup
    ok ALREADY_CLEAN
    exit 0
fi

# ------------------------------------------------------------ 3. stop processes ---
say "stopping project children"
for n in carplay-cluster-supervisor altscreen-most-bridge carplay-pairing-helper; do
    slay -f "$n" >/dev/null 2>&1 || true
done
stop_pid /dev/shmem/wcp_receiver.pid "wcp_receiver wireless-receiver-exec"
stop_pid /dev/shmem/wcp_video.pid    "wcp_video wireless-video-exec"
stop_pid /dev/shmem/wcp_pfwatch.pid  "wcp_pfwatch"
stop_pid /ramdisk/omonob-791-input.pid "wireless-entry"
ok STOPPED
if [ "$STILL_RUNNING" -gt 0 ]; then
    say "NOTE: $STILL_RUNNING process(es) still running; the files are replaced safely and the restart ends them"
fi

# ------------------------------------------------------------ 4. remount + probe ---
say "remount read-write"
for p in /mnt/app /mnt/ota /mnt/system /mnt/persist; do
    mount -uw "$p" 2>/dev/null || true
done
# Probe for real before the first write: a silent RO mount must surface HERE.
for p in /mnt/app /mnt/ota /mnt/system /mnt/persist; do
    if ! ( : > "$p/.wmaps-rwprobe" ) 2>/dev/null; then
        die REMOUNT_RW_FAILED_$p
    fi
    rm -f "$p/.wmaps-rwprobe"
done
ok REMOUNTED

# --------------------------------------------------------------- 5. stage all ---
# Each file is copied NEXT TO its target (same filesystem) and checked against the
# baseline. Live files are not touched yet; any failure removes the temp copies.
say "staging restore set ($NPRESENT files)"
: > "$STAGED" || die STAGE_LIST_FAILED
while read -r state path; do
    [ "$state" = PRESENT ] || continue
    mkdir -p "${path%/*}" || die RESTORE_MKDIR_FAILED_$path
    echo "$path" >> "$STAGED"       # listed first, so die() also cleans a half-written copy
    cp -p "$BAK/files$path" "$path.wmaps-restore" || die RESTORE_PREP_FAILED_$path
    want=$(cksum_of "$BAK/files$path")
    got=$(cksum_of "$path.wmaps-restore")
    [ -n "$got" ] && [ "$got" = "$want" ] || die RESTORE_STAGE_CORRUPT_$path
done < "$BAK/MANIFEST"
ok STAGED

# ------------------------------------------------------------- 6. activate ---
say "activating restore"
ACTIVATING=1
RESTORED_SO_FAR=0
while read -r path; do
    [ -n "$path" ] || continue
    mv -f "$path.wmaps-restore" "$path" \
        || die RESTORE_FAILED_AFTER_${RESTORED_SO_FAR}_AT_$path
    RESTORED_SO_FAR=$((RESTORED_SO_FAR+1))
done < "$STAGED"
rm -f "$STAGED"
# Delete every MISSING target (files the installer created; factory had none).
while read -r state path; do
    case "$state" in
        MISSING) rm -f "$path" || die RESTORE_REMOVE_FAILED_$path ;;
    esac
done < "$BAK/MANIFEST"
ok RESTORED_FILES
say "restored $RESTORED_SO_FAR files"

# --------------------------------------------------------- 7. runtime tree ---
# The new tree is built on the SAME filesystem, then swapped in with renames; the
# old tree is deleted only after the swap succeeded, and is put back if it fails.
say "restoring runtime tree"
if [ "$RT" = yes ]; then
    rm -rf "$RT_NEW" "$RT_OLD"
    cp -pR "$BAK/runtime" "$RT_NEW" || { rm -rf "$RT_NEW"; die RUNTIME_STAGE_FAILED; }
    for f in core.so wireless-entry VERSION; do
        [ -s "$RT_NEW/$f" ] || { rm -rf "$RT_NEW"; die RUNTIME_STAGE_INCOMPLETE_$f; }
    done
    if [ -e "$ROOT" ]; then
        mv "$ROOT" "$RT_OLD" || { rm -rf "$RT_NEW"; die RUNTIME_SWAP_FAILED; }
    fi
    if ! mv "$RT_NEW" "$ROOT"; then
        [ -e "$RT_OLD" ] && mv "$RT_OLD" "$ROOT"
        rm -rf "$RT_NEW"
        die RUNTIME_RESTORE_FAILED_PREVIOUS_TREE_PUT_BACK
    fi
    rm -rf "$RT_OLD"
else
    rm -rf "$ROOT" || die RUNTIME_REMOVE_FAILED
fi
ok RUNTIME_RESTORED

# ----------------------------------------------------- 8. project state + audit ---
say "cleaning project state"
for f in $PROJECT_FLAGS; do
    rm -f "$PERSIST/$f"
done
rm -rf "$PERSIST/wcp" "$PERSIST/omonob-phone"
rm -f /dev/shmem/wcp_receiver.pid /dev/shmem/wcp_video.pid \
      /dev/shmem/wcp_pfwatch.pid /dev/shmem/wcp_pfwatch.log \
      /dev/shmem/wcp_pf.src /dev/shmem/wcp_pf.conf /dev/shmem/wcp_pf.nat \
      /dev/shmem/wcp_chansync.log /dev/shmem/wcp_chan_stable \
      /dev/shmem/wcp.log /dev/shmem/wcp_video.log /dev/shmem/wcp_cp.log \
      /dev/shmem/wcp_autostart.log /dev/shmem/btwcp.present \
      /dev/shmem/wcp_cp_fg /dev/shmem/wcp_cp_touch_owner /dev/shmem/wcp_cp_oem \
      /dev/shmem/wcp_cp_front_req /dev/shmem/wcp_touch_fg \
      /dev/shmem/wcp_touch_hmi.log /dev/shmem/wcp_hs_req 2>/dev/null || true
rm -f /ramdisk/omonob-791-input.pid /ramdisk/omonob-791-input.log \
      /ramdisk/carplay-dio-manager.pid /ramdisk/carplaymaps-launcher.log \
      /ramdisk/carplaymaps-video.log 2>/dev/null || true
sync
ok CLEANED

# Proof, not hope: every PRESENT file must now equal the baseline byte for byte and
# every MISSING file must be gone.
say "verifying the unit equals the baseline"
BAD=0
while read -r state path; do
    case "$state" in
        PRESENT)
            want=$(cksum_of "$BAK/files$path")
            got=$(cksum_of "$path")
            if [ "$got" != "$want" ]; then
                say "MISMATCH after restore: $path"
                BAD=$((BAD+1))
            fi ;;
        MISSING)
            if [ -e "$path" ]; then
                say "still present after restore: $path"
                BAD=$((BAD+1))
            fi ;;
    esac
done < "$BAK/MANIFEST"
[ "$BAD" = 0 ] || die VERIFY_RESTORE_FAILED_$BAD
ok RESTORE_VERIFIED

# Closing audit: counts that MUST be zero. Reported, never auto-fixed (no surprise
# writes after "done"); they name exactly which reference a step would have missed.
say "closing audit"
WARN=0
n1=$(grep -c '/mnt/app/carplaymaps' "$LSDBAK/lsd.sh" 2>/dev/null)
n2=$(grep -c '/mnt/app/carplaymaps' "$LSDBAK/config/bundles.properties" 2>/dev/null)
n3=$(grep -c '/mnt/app/carplaymaps' "$PRODDIR/connectivity.json" 2>/dev/null)
n4=$(grep -c '/mnt/app/carplaymaps' "$PRODDIR/smartphone_integrator.json" 2>/dev/null)
n5=$(grep -c '/mnt/ota' "$PRODDIR/connectivity.json" 2>/dev/null)
CNT=$((${n1:-0}+${n2:-0}+${n3:-0}+${n4:-0}+${n5:-0}))
if [ "$CNT" -gt 0 ]; then
    say "WARNING: CARPLAYMAPS_REFERENCES=$CNT (lsd=$n1 bundles=$n2 conn=$n3 si=$n4 ota_in_conn=$n5)"
    WARN=$((WARN+1))
else
    say "CARPLAYMAPS_REFERENCES=0"
fi
SW=0
for f in $PROJECT_FLAGS; do
    [ ! -e "$PERSIST/$f" ] || SW=$((SW+1))
done
[ ! -e "$PERSIST/omonob-phone" ] || SW=$((SW+1))
[ ! -e "$PERSIST/wcp" ]          || SW=$((SW+1))
if [ "$SW" -gt 0 ]; then
    say "WARNING: SWITCHES_PRESENT=$SW"
    WARN=$((WARN+1))
else
    say "SWITCHES_PRESENT=0"
fi
OL=0
for f in btstack_wrap.sh libbtwcp.so wcp_autostart.sh wcp_chansync.sh \
         wcp_ctl.sh wcp_pf.sh wcp_pfwatch.sh wcp_receiver wcp_video; do
    [ ! -e "$OTA/$f" ] || OL=$((OL+1))
done
if [ "$OL" -gt 0 ]; then
    say "WARNING: OTA_LEFT=$OL"
    WARN=$((WARN+1))
else
    say "OTA_LEFT=0"
fi
[ ! -e "$RT_NEW" ] && [ ! -e "$RT_OLD" ] || { say "WARNING: leftover runtime swap dir"; WARN=$((WARN+1)); }

cleanup
say "done"
if [ "$WARN" -gt 0 ]; then
    echo "CPMAP_WARN=AUDIT_FINDINGS_$WARN"
    echo "Files are restored and verified, but the audit above reported leftovers."
    echo "Restart the unit manually; the baseline is kept at $BAK."
    exit 2
fi
ok MANUAL_UNINSTALL_COMPLETE
echo "Restart the unit manually to return the HMI to its factory classpath."
echo "Baseline kept at $BAK for inspection; delete it yourself once satisfied."
exit 0
