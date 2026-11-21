#!/bin/sh
# Wireless CarPlay Maps for MU1447 (SEAT G11, AID10.5 / cluster 790)
#
# Runs ON the head unit. Copies the payload into the live filesystems and writes
# a first-baseline backup so ./uninstall.sh can put the unit back as it was.
#
# Nothing here reboots the unit and nothing stops a shared ESO service.
#
# QNX ksh limits honoured throughout (see the package's own wcp_ctl.sh note):
#   no date, wc, find, printf, env, tr, cmp.  Every external command this script
#   runs is checked by the gate below and exists in the MU1447 dump.
#   No CRLF, no "set -u".
#
# PATH is set here, not inherited. SWDL runs this via `on -f mmx /bin/ksh` with a
# minimal PATH (/bin:/usr/bin), where awk and dirname do not resolve - both live
# under /armle on this unit. An SSH login shell happens to have the full PATH,
# which is why the same script worked there and failed from the card.
PATH=/proc/boot:/bin:/usr/bin:/usr/sbin:/sbin:/armle/bin:/armle/sbin:/armle/usr/bin:/armle/usr/sbin
export PATH

# Helpers are defined first so that EVERY failure - even the earliest - goes
# through die(), which also releases the lock and removes the temp dir.
LOCK=/ramdisk/.wmaps-manual.lock
LOCK_OWNED=0
CHANGED=0
S_TMP=

say() { echo "### $*"; }
die() {
    echo "CPMAP_MANUAL_FAIL=$1"
    if [ "$CHANGED" = 1 ]; then
        echo "### The unit may be PARTIALLY installed. Run ./uninstall.sh to restore the factory baseline."
    else
        echo "### Nothing on the unit was changed by this run."
    fi
    [ -n "$S_TMP" ] && rm -rf "$S_TMP"
    [ "$LOCK_OWNED" = 1 ] && rm -rf "$LOCK"
    exit 1
}
ok()  { echo "CPMAP_OK=$1"; }

command -v dirname >/dev/null 2>&1 || die REQUIRED_TOOL_MISSING_dirname
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
STAGE=${STAGE:-$SELF_DIR/payload}

# ---- MODE SWITCH: ONE marker file decides, nothing else. An empty file named
# "uninstall" next to this script hands the whole run to uninstall.sh; without it
# this script installs. "uninstall.txt" is accepted as the same marker, because
# Windows often adds the .txt extension without telling you. No script ever
# creates, renames or removes the marker, so
# every lap of a multi-lap SWDL run takes the same branch (a second uninstall lap
# finds the unit already clean and writes nothing).
if [ -e "$SELF_DIR/uninstall" ] || [ -e "$SELF_DIR/uninstall.txt" ]; then
    say "MODE: UNINSTALL (marker file 'uninstall' or 'uninstall.txt' found next to install.sh)"
    # Never fall through to an install when the user asked for an uninstall.
    [ -f "$SELF_DIR/uninstall.sh" ] || die UNINSTALL_MARKER_PRESENT_BUT_NO_UNINSTALL_SH
    exec sh "$SELF_DIR/uninstall.sh" || die UNINSTALL_EXEC_FAILED
fi
say "MODE: INSTALL"

LSDBASE=/mnt/app/eso/hmi/lsd
ROOT=/mnt/app/carplaymaps
# The baseline must live OUTSIDE the tree it snapshots: it copies the whole
# carplaymaps runtime, and a backup inside it would recurse into itself.
BAK=/mnt/app/.carplaymaps-first-baseline
BASE=$BAK
JARS=$LSDBASE/jars
LSD=$LSDBASE/lsd.sh
BUNDLES=$LSDBASE/config/bundles.properties
SI_DIR=/mnt/system/etc/eso/production
OTA=/mnt/ota
PERSIST=/mnt/persist
APP=/mnt/app

PROFILE=AID10.5-17PM
MU=MU1447
CLUSTER=790

# ---------------------------------------------------------------- preflight ---
say "preflight"
[ -s /ifs/lsd.jxe ] || die NO_LSD_JXE
[ -d "$APP" ]       || die NO_MNT_APP
[ -s "$LSD" ]       || die NO_LSD_SH
[ -s "$BUNDLES" ]   || die NO_BUNDLES
[ -d "$SI_DIR" ]    || die NO_PRODUCTION_DIR

# Exact-firmware gate: lsd.jxe size identifies MU1447 in this family.
set -- $(ls -ln /ifs/lsd.jxe)
JXE_SIZE=$5
[ "$JXE_SIZE" = "55712574" ] || die UNSUPPORTED_JXE_SIZE_$JXE_SIZE

# A live CarPlay/iAP session would be torn mid-write.
[ ! -e /dev/ipod0 ]                || die DISCONNECT_CARPLAY_FIRST
[ ! -e /dev/shmem/wcp_cp_session ] || die DISCONNECT_CARPLAY_FIRST

for t in awk cat chmod cp grep ls mkdir mount mv rm sh sleep slay sync; do
    command -v "$t" >/dev/null 2>&1 || die REQUIRED_TOOL_MISSING_$t
done
# pidin: identity checks before any kill. cksum: baseline original-bytes
# verification. Both verified present in the MU1447 firmware dump.
for t in pidin kill; do
    command -v "$t" >/dev/null 2>&1 || die REQUIRED_TOOL_MISSING_$t
done
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
# /bin/ksh -n is used below to syntax-check every shell script before it goes live.
[ -x /bin/ksh ] || die REQUIRED_TOOL_MISSING_ksh
# One run at a time (install and uninstall share this lock; /ramdisk is wiped on reboot).
mkdir "$LOCK" 2>/dev/null || die ANOTHER_RUN_ACTIVE_OR_STALE_LOCK_$LOCK
LOCK_OWNED=1

# Identity-checked process stop. A pid file alone proves nothing: after a
# crash the pid may name ANY process. Only kill a live pid whose pidin arg
# line matches the expected name, TERM only (never KILL), and always drop
# the stale pid file afterwards.
stop_pid() {   # $1 = pid file, $2 = expected name in the pidin arg line
    [ -f "$1" ] || return 0
    P=$(cat "$1" 2>/dev/null)
    case "$P" in ''|*[!0-9]*) rm -f "$1"; return 0 ;; esac
    if kill -0 "$P" 2>/dev/null && pidin -p "$P" 2>/dev/null | grep -q "$2"; then
        kill "$P" 2>/dev/null || true
        sleep 1
    fi
    rm -f "$1"
}

# The payload must be complete before anything on the unit changes.
# 49 entries: every file this installer itself copies, every file it hands
# to install-carplay-maps.sh, and every config/flag file it stages.
for f in \
    "$STAGE/common/install-carplay-maps.sh" \
    "$STAGE/common/merge-wireless.sh" \
    "$STAGE/common/dio_manager.wrapper.sh" \
    "$STAGE/common/cpmap-nav-check" \
    "$STAGE/common/altscreen-most-bridge" \
    "$STAGE/common/carplay-cluster-supervisor" \
    "$STAGE/common/libcarplay-security-bridge.so" \
    "$STAGE/common/carplay-pairing-helper" \
    "$STAGE/common/libCarPlayPairingCore.so" \
    "$STAGE/common/cpvc-mirror-canvas-790" \
    "$STAGE/common/libcpvc-mirror-tap.so" \
    "$STAGE/common/libcpvc-dmdt-query.so" \
    "$STAGE/common/libomonob-primary30.so" \
    "$STAGE/common/CarPlayNavigationPatch.jar" \
    "$STAGE/profiles/$MU/$CLUSTER/core.so" \
    "$STAGE/profiles/$MU/$CLUSTER/VCMenu.jar" \
    "$STAGE/profiles/$MU/$CLUSTER/VCMirrorRate.jar" \
    "$STAGE/profiles/$MU/$CLUSTER/CarPlayClusterControls.jar" \
    "$STAGE/wireless/config-patch" \
    "$STAGE/wireless/common/ota/btstack_wrap.sh" \
    "$STAGE/wireless/common/ota/libbtwcp.so" \
    "$STAGE/wireless/common/ota/wcp_autostart.sh" \
    "$STAGE/wireless/common/ota/wcp_chansync.sh" \
    "$STAGE/wireless/common/ota/wcp_ctl.sh" \
    "$STAGE/wireless/common/ota/wcp_pf.sh" \
    "$STAGE/wireless/common/ota/wcp_pfwatch.sh" \
    "$STAGE/wireless/common/ota/wcp_video" \
    "$STAGE/wireless/common/jars/CarPlayWireless-CP-55915411.jar" \
    "$STAGE/wireless/common/jars/CarPlayWireless-SI-55915411.jar" \
    "$STAGE/wireless/common/jars/CarPlayWireless-Touch-55915411.jar" \
    "$STAGE/wireless/common/jars/WirelessMapsBootstrap.jar" \
    "$STAGE/wireless/common/runtime/start-wireless-maps.sh" \
    "$STAGE/wireless/common/runtime/wireless-video-exec" \
    "$STAGE/wireless/common/runtime/wcp_video_stock" \
    "$STAGE/wireless/common/runtime/wcp_video_tap" \
    "$STAGE/wireless/common/runtime/libv75-transport.so" \
    "$STAGE/wireless/common/runtime/libv75-wireless-video-tap.so" \
    "$STAGE/wireless/profiles/$PROFILE/wcp_receiver" \
    "$STAGE/wireless/profiles/$PROFILE/wireless-entry" \
    "$STAGE/wireless/profiles/$PROFILE/wireless-receiver-exec" \
    "$STAGE/wireless/profiles/$PROFILE/libomonob-wireless-maps.so" \
    "$STAGE/wireless/common/config/btwcp_enable" \
    "$STAGE/wireless/common/config/btwcp_present_target" \
    "$STAGE/wireless/common/config/wcp_autostart" \
    "$STAGE/wireless/common/config/wcp_cp_stage" \
    "$STAGE/wireless/profiles/$PROFILE/altscreen.conf" \
    "$STAGE/wireless/profiles/$PROFILE/altscreen.geom" \
    "$STAGE/wireless/profiles/$PROFILE/v75-wireless-display.conf" \
    "$STAGE/wireless/profiles/$PROFILE/cluster-profile" \
  ; do
    [ -s "$f" ] || die PAYLOAD_MISSING_${f##*/}
done
# A syntax error in btstack_wrap.sh would take Bluetooth/WiFi down at boot, so every
# shell script in the payload is parsed here, while the unit is still untouched.
say "syntax-checking payload shell scripts"
for f in \
    "$STAGE/common/install-carplay-maps.sh" \
    "$STAGE/common/merge-wireless.sh" \
    "$STAGE/common/dio_manager.wrapper.sh" \
    "$STAGE/wireless/common/ota/btstack_wrap.sh" \
    "$STAGE/wireless/common/ota/wcp_autostart.sh" \
    "$STAGE/wireless/common/ota/wcp_chansync.sh" \
    "$STAGE/wireless/common/ota/wcp_ctl.sh" \
    "$STAGE/wireless/common/ota/wcp_pf.sh" \
    "$STAGE/wireless/common/ota/wcp_pfwatch.sh" \
    "$STAGE/wireless/common/runtime/start-wireless-maps.sh" \
  ; do
    /bin/ksh -n "$f" >/dev/null 2>&1 || die PAYLOAD_SYNTAX_FAILED_${f##*/}
done
ok PREFLIGHT

# --------------------------------------------------------- mounts + children ---
say "remount read-write"
for p in /mnt/app /mnt/ota /mnt/system /mnt/persist; do
    mount -uw "$p" 2>/dev/null || true
done
# Probe each mount for real before the first write: a silent RO mount would
# otherwise surface as COPY_FAILED halfway through the install.
for p in /mnt/app /mnt/ota /mnt/system /mnt/persist; do
    if ! ( : > "$p/.wmaps-rwprobe" ) 2>/dev/null; then
        die REMOUNT_RW_FAILED_$p
    fi
    rm -f "$p/.wmaps-rwprobe"
done
ok REMOUNTED

# Only project-owned processes. Shared ESO services are left to the reboot.
# Every kill is identity-checked via pidin (stop_pid) - a stale pid file can
# never kill an innocent process.
say "stopping project children (if any)"
for n in carplay-cluster-supervisor altscreen-most-bridge carplay-pairing-helper; do
    slay -f "$n" >/dev/null 2>&1 || true
done
stop_pid /dev/shmem/wcp_receiver.pid wcp_receiver
stop_pid /dev/shmem/wcp_video.pid    wcp_video
stop_pid /dev/shmem/wcp_pfwatch.pid wcp_pfwatch
stop_pid /ramdisk/omonob-791-input.pid wireless-entry
ok STOPPED

# ---------------------------------------------------------- first baseline ---
# THE ONE-BACKUP LAW: the factory baseline is taken ONCE. Later installs
# reuse it after proving it still holds the original bytes, and never
# write into it. This is what keeps a second or third install from
# snapshotting already-modified files as "factory" (which would make the
# restore worthless).
TRACKED="
/mnt/app/eso/bin/apps/dio_manager
/mnt/app/eso/bin/apps/btstack
/mnt/app/eso/bin/apps/connectionmanager
/mnt/app/eso/hmi/lsd/lsd.sh
/mnt/app/eso/hmi/lsd/config/bundles.properties
/mnt/app/eso/hmi/lsd/jars/VCMenu.jar
/mnt/app/eso/hmi/lsd/jars/VCMirrorRate.jar
/mnt/app/eso/hmi/lsd/jars/CarPlayClusterControls.jar
/mnt/app/eso/hmi/lsd/jars/CarPlayNavigationPatch.jar
/mnt/app/eso/hmi/lsd/jars/CarPlayWireless-CP-55915411.jar
/mnt/app/eso/hmi/lsd/jars/CarPlayWireless-SI-55915411.jar
/mnt/app/eso/hmi/lsd/jars/CarPlayWireless-Touch-55915411.jar
/mnt/app/eso/hmi/lsd/jars/WirelessMapsBootstrap.jar
/mnt/ota/btstack_wrap.sh
/mnt/ota/libbtwcp.so
/mnt/ota/wcp_autostart.sh
/mnt/ota/wcp_chansync.sh
/mnt/ota/wcp_ctl.sh
/mnt/ota/wcp_pf.sh
/mnt/ota/wcp_pfwatch.sh
/mnt/ota/wcp_receiver
/mnt/ota/wcp_video
/mnt/persist/btwcp_enable
/mnt/persist/btwcp_present_target
/mnt/persist/wcp_autostart
/mnt/persist/wcp_cp_stage
/mnt/persist/altscreen.conf
/mnt/persist/altscreen.geom
/mnt/persist/v75-wireless-display.conf
/mnt/persist/omonob-phone/cluster-profile
/mnt/system/etc/eso/production/connectivity.json
/mnt/system/etc/eso/production/smartphone_integrator.json
"

# FACTORY constants: cksum + size of the ORIGINAL factory files, computed
# from the clean-unit dump (H:/mhi2-seat-dump). Used ONLY to prove the
# existing baseline still holds original bytes before reuse - never to
# gate any live file.
FACTORY_CKSUM_lsd=3139215696;           FACTORY_SIZE_lsd=16155
FACTORY_CKSUM_bundles=4264858563;        FACTORY_SIZE_bundles=13121
FACTORY_CKSUM_connectivity=3506558296;  FACTORY_SIZE_connectivity=8699
FACTORY_CKSUM_si=3242712254;            FACTORY_SIZE_si=7360
FACTORY_CKSUM_dio=2190598061;           FACTORY_SIZE_dio=686481
FACTORY_CKSUM_btstack=3795474524;        FACTORY_SIZE_btstack=1846505

baseline_cksum_of() {   # $1 = path inside $BASE/files; prints "<token> <size>"
    fsum "$BASE/files$1"
}

baseline_expect() {     # $1 = short key; prints the expected "<cksum> <size>"
    case "$1" in
        lsd)         echo "$FACTORY_CKSUM_lsd $FACTORY_SIZE_lsd" ;;
        bundles)     echo "$FACTORY_CKSUM_bundles $FACTORY_SIZE_bundles" ;;
        connectivity) echo "$FACTORY_CKSUM_connectivity $FACTORY_SIZE_connectivity" ;;
        si)          echo "$FACTORY_CKSUM_si $FACTORY_SIZE_si" ;;
        dio)         echo "$FACTORY_CKSUM_dio $FACTORY_SIZE_dio" ;;
        btstack)     echo "$FACTORY_CKSUM_btstack $FACTORY_SIZE_btstack" ;;
    esac
}

baseline_must_be_original() {   # no return value; dies hard on any mismatch
    # Paths the first baseline always holds as PRESENT (factory ships them).
    for pair in \
        "lsd:/mnt/app/eso/hmi/lsd/lsd.sh" \
        "bundles:/mnt/app/eso/hmi/lsd/config/bundles.properties" \
        "connectivity:/mnt/system/etc/eso/production/connectivity.json" \
        "si:/mnt/system/etc/eso/production/smartphone_integrator.json" \
        "dio:/mnt/app/eso/bin/apps/dio_manager" \
        "btstack:/mnt/app/eso/bin/apps/btstack" \
      ; do
        key=${pair%%:*}; path=${pair#*:}
        if [ ! -s "$BASE/files$path" ]; then
            say "baseline copy of $path is missing"
            die BASELINE_NOT_FACTORY_MISSING_$key
        fi
        found=$(baseline_cksum_of "$path")
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
                    text_is_clean "$BASE/files$path" || die BASELINE_NOT_FACTORY_MARKERS_$key ;;
            esac
        fi
    done
    ok BASELINE_VERIFIED_ORIGINAL
}

# Per-file integrity record (written at snapshot time) for the files that have no
# frozen factory constant. Baselines made by an older installer have none: skipped.
baseline_cksums_ok() {
    if [ ! -s "$BASE/CKSUMS" ]; then
        say "NOTE: baseline has no CKSUMS record (older installer); only the six factory files are proven"
        return 0
    fi
    REC_MODE=$(cat "$BASE/FSUM_MODE" 2>/dev/null)
    [ -n "$REC_MODE" ] || REC_MODE=cksum
    while read -r ck sz path; do
        [ -n "$path" ] || continue
        found=$(baseline_cksum_of "$path")
        if [ "$REC_MODE" = "$FSUM_MODE" ]; then
            [ "$found" = "$ck $sz" ] || die BASELINE_FILE_CORRUPT_$path
        else
            [ "${found##* }" = "$sz" ] || die BASELINE_FILE_CORRUPT_$path   # tool differs: size only
        fi
    done < "$BASE/CKSUMS"
    ok BASELINE_CKSUMS_VERIFIED
}

if [ -s "$BAK/MANIFEST" ]; then
    BASELINE_MODE=REUSE
else
    BASELINE_MODE=SNAPSHOT
fi

if [ "$BASELINE_MODE" = REUSE ]; then
    # Installs #2, #3, ...: NEVER touch the baseline. Prove it still holds
    # the original factory bytes, then continue as an update over the live
    # (modified) files.
    say "baseline exists at $BAK -> verifying it still holds factory bytes"
    baseline_must_be_original
    baseline_cksums_ok
    say "baseline frozen: no re-snapshot, nothing written into $BAK"
else
    # First install ever. The unit must show ZERO trace of a previous
    # install - otherwise this snapshot would capture modified files as
    # "factory" and poison the only recovery point.
    [ ! -e "$BAK.new" ] || die STALE_BASELINE_STAGING
    for f in btstack_wrap.sh libbtwcp.so wcp_autostart.sh wcp_chansync.sh \
             wcp_ctl.sh wcp_pf.sh wcp_pfwatch.sh wcp_receiver wcp_video; do
        [ ! -e "$OTA/$f" ] || die INSTALL_OVER_DIRTY_STATE_$f
    done
    for f in btwcp_enable btwcp_present_target wcp_autostart wcp_cp_stage \
             altscreen.conf altscreen.geom v75-wireless-display.conf; do
        [ ! -e "$PERSIST/$f" ] || die INSTALL_OVER_DIRTY_STATE_$f
    done
    [ ! -e "$PERSIST/omonob-phone" ] || die INSTALL_OVER_DIRTY_STATE_omonob-phone
    for j in VCMenu VCMirrorRate CarPlayClusterControls \
             CarPlayWireless-CP-55915411 CarPlayNavigationPatch; do
        [ ! -e "/mnt/app/eso/hmi/lsd/jars/$j.jar" ] \
            || die PREVIOUS_INSTALL_PRESENT_JAR_$j
    done
    if grep -q 'OMONOB_WMAPS_WIRELESS_BEGIN\|CarPlayWireless-' "$LSD" 2>/dev/null; then
        die PREVIOUS_INSTALL_PRESENT_LSD
    fi
    if grep -q 'WirelessCarPlayMaps' "$BUNDLES" 2>/dev/null; then
        die PREVIOUS_INSTALL_PRESENT_BUNDLES
    fi
    if grep -q 'btstack_wrap.sh' "$SI_DIR/connectivity.json" 2>/dev/null; then
        die PREVIOUS_INSTALL_PRESENT_CONNECTIVITY
    fi
    DIO_SIZE=$(ls -ln /mnt/app/eso/bin/apps/dio_manager 2>/dev/null | awk '{print $5}')
    [ "$DIO_SIZE" = "686481" ] || {
        say "dio_manager is $DIO_SIZE bytes, factory is 686481"
        die PREVIOUS_INSTALL_PRESENT_RUN_UNINSTALL
    }

    say "creating first baseline in $BAK (unit verified clean)"
    rm -rf "$BAK.new"
    mkdir -p "$BAK.new/files"
    : > "$BAK.new/MANIFEST"
    : > "$BAK.new/CKSUMS"
    echo "$FSUM_MODE" > "$BAK.new/FSUM_MODE"
    for p in $TRACKED; do
        if [ -e "$p" ]; then
            mkdir -p "$BAK.new/files${p%/*}" || die BASELINE_MKDIR_FAILED_$p
            cp -p "$p" "$BAK.new/files$p"    || die BASELINE_COPY_FAILED_$p
            # The copy must be byte-identical to the live file, and its cksum is recorded.
            ck=$(fsum "$BAK.new/files$p")
            live=$(fsum "$p")
            [ -n "$ck" ] && [ "$ck" = "$live" ] || die BASELINE_COPY_CORRUPT_$p
            echo "$ck $p" >> "$BAK.new/CKSUMS"
            echo "PRESENT $p" >> "$BAK.new/MANIFEST"
        else
            echo "MISSING $p" >> "$BAK.new/MANIFEST"
        fi
    done
    # The runtime tree is restored wholesale, not file by file.
    if [ -d "$ROOT" ]; then
        cp -pR "$ROOT" "$BAK.new/runtime" || die BASELINE_RUNTIME_COPY_FAILED
        echo "RUNTIME_PRESENT /mnt/app/carplaymaps" >> "$BAK.new/MANIFEST"
    else
        echo "RUNTIME_MISSING /mnt/app/carplaymaps" >> "$BAK.new/MANIFEST"
    fi
    # THE FIRST INSTALL MUST PROVE THE SNAPSHOT TOO: it is checked against the frozen
    # factory constants before it is committed and before any live file is touched.
    # On a mismatch the staging dir is left in place for inspection, nothing was
    # modified, and the next run stops at STALE_BASELINE_STAGING until you look at it.
    say "verifying the new snapshot BEFORE any live file is touched"
    BASE="$BAK.new"
    baseline_must_be_original
    BASE=$BAK
    mv "$BAK.new" "$BAK" || die BASELINE_COMMIT_FAILED
    sync
    ok BASELINE_CREATED
fi

# --------------------------------------------------- carplay VC (wired half) ---
# The project's own installer, which already supports MU1447:790.
CHANGED=1
say "installing CarPlay Maps VC core"
sh "$STAGE/common/install-carplay-maps.sh" "$STAGE" "$MU" "$CLUSTER" \
    || die CARPLAY_MAPS_INSTALL_FAILED
ok VC_CORE

# ------------------------------------------- copy helper (atomic per target) ---
copy_in() {   # $1=source $2=target $3=mode
    mkdir -p "${2%/*}" || die MKDIR_FAILED_$2
    cp -f "$1" "$2.wmaps-new" || die COPY_FAILED_$2
    chmod "$3" "$2.wmaps-new" || die CHMOD_FAILED_$2
    mv -f "$2.wmaps-new" "$2" || die ACTIVATE_FAILED_$2
}

# ------------------------------------------------ wireless engine in /mnt/ota ---
say "installing wireless engine -> /mnt/ota"
for pair in \
    "wireless/common/ota/btstack_wrap.sh:/mnt/ota/btstack_wrap.sh:755" \
    "wireless/common/ota/libbtwcp.so:/mnt/ota/libbtwcp.so:644" \
    "wireless/common/ota/wcp_autostart.sh:/mnt/ota/wcp_autostart.sh:755" \
    "wireless/common/ota/wcp_chansync.sh:/mnt/ota/wcp_chansync.sh:755" \
    "wireless/common/ota/wcp_ctl.sh:/mnt/ota/wcp_ctl.sh:755" \
    "wireless/common/ota/wcp_pf.sh:/mnt/ota/wcp_pf.sh:755" \
    "wireless/common/ota/wcp_pfwatch.sh:/mnt/ota/wcp_pfwatch.sh:755" \
    "wireless/common/ota/wcp_video:/mnt/ota/wcp_video:755" \
    "wireless/profiles/$PROFILE/wcp_receiver:/mnt/ota/wcp_receiver:755" \
  ; do
    src=${pair%%:*}; rest=${pair#*:}; dst=${rest%%:*}; mode=${rest##*:}
    copy_in "$STAGE/$src" "$dst" "$mode"
done
ok WIRELESS_OTA

# ---------------------------------------------- wireless runtime in carplaymaps ---
say "installing wireless runtime -> $ROOT"
mkdir -p "$ROOT/security_bridge" || die MKDIR_FAILED_CARPLAYMAPS
for pair in \
    "wireless/profiles/$PROFILE/wireless-receiver-exec:/mnt/app/carplaymaps/wireless-receiver-exec:755" \
    "wireless/profiles/$PROFILE/wireless-entry:/mnt/app/carplaymaps/wireless-entry:755" \
    "wireless/profiles/$PROFILE/libomonob-wireless-maps.so:/mnt/app/carplaymaps/libomonob-wireless-maps.so:644" \
    "wireless/common/runtime/start-wireless-maps.sh:/mnt/app/carplaymaps/start-wireless-maps.sh:755" \
    "wireless/common/runtime/wireless-video-exec:/mnt/app/carplaymaps/wireless-video-exec:755" \
    "wireless/common/runtime/wcp_video_stock:/mnt/app/carplaymaps/wcp_video_stock:755" \
    "wireless/common/runtime/wcp_video_tap:/mnt/app/carplaymaps/wcp_video_tap:755" \
    "wireless/common/runtime/libv75-transport.so:/mnt/app/carplaymaps/libv75-transport.so:644" \
    "wireless/common/runtime/libv75-wireless-video-tap.so:/mnt/app/carplaymaps/libv75-wireless-video-tap.so:644" \
  ; do
    src=${pair%%:*}; rest=${pair#*:}; dst=${rest%%:*}; mode=${rest##*:}
    copy_in "$STAGE/$src" "$dst" "$mode"
done
ok WIRELESS_RUNTIME

# ------------------------------------------------------- wireless HMI jars ---
say "installing wireless HMI jars"
for j in CarPlayWireless-CP-55915411 CarPlayWireless-SI-55915411 \
         CarPlayWireless-Touch-55915411 WirelessMapsBootstrap; do
    copy_in "$STAGE/wireless/common/jars/$j.jar" "$JARS/$j.jar" 644
done
ok WIRELESS_JARS

# ------------------------------------------ merge lsd.sh boot classpath entry ---
# merge-wireless.sh is idempotent: the block is delimited, the prepend line is
# rebuilt from scratch, and it exits non-zero on a shape it does not know.
say "merging lsd.sh"
S_TMP=/ramdisk/.wmaps-merge-$$
mkdir -p "$S_TMP" || die MERGE_STAGE_FAILED
sh "$STAGE/common/merge-wireless.sh" lsd "$LSD" "$S_TMP/lsd.sh.new" \
    || die LSD_MERGE_FAILED
[ -s "$S_TMP/lsd.sh.new" ] || die LSD_MERGE_EMPTY
/bin/ksh -n "$S_TMP/lsd.sh.new" >/dev/null 2>&1 || die LSD_SYNTAX_FAILED
chmod 755 "$S_TMP/lsd.sh.new" || die LSD_CHMOD_FAILED
mv -f "$S_TMP/lsd.sh.new" "$LSD" || die LSD_ACTIVATE_FAILED
ok LSD_MERGED

# ----------------------------------- merge bundles.properties late-load slot ---
say "merging bundles.properties"
sh "$STAGE/common/merge-wireless.sh" bundles "$BUNDLES" "$S_TMP/bundles.new" \
    || die BUNDLES_MERGE_FAILED
[ -s "$S_TMP/bundles.new" ] || die BUNDLES_MERGE_EMPTY
mv -f "$S_TMP/bundles.new" "$BUNDLES" || die BUNDLES_ACTIVATE_FAILED
ok BUNDLES_MERGED

# ------------------------------------------- production config JSON patches ---
# config-patch is the project's own tiny ARM editor: it refuses a shape it does
# not recognise instead of rewriting best-effort. Patch copies, so a failure
# leaves the live JSON untouched. On a repeat install (REUSE) the live files
# may already carry our patch - detect our own marker first and skip, because
# config-patch's behaviour on an already-patched shape is not guaranteed.
say "patching production config"
if grep -q 'btstack_wrap.sh' "$SI_DIR/connectivity.json" 2>/dev/null; then
    say "connectivity.json already points at our wrapper -> skip"
    cp -f "$SI_DIR/connectivity.json" "$S_TMP/connectivity.new" \
        || die CONNECTIVITY_BACKUP_FAILED
else
    cp -f "$SI_DIR/connectivity.json" "$S_TMP/connectivity.prev"    || die CONFIG_BACKUP_FAILED
    "$STAGE/wireless/config-patch" connectivity "$S_TMP/connectivity.prev" \
        "$S_TMP/connectivity.new" || die CONNECTIVITY_PATCH_FAILED
fi
if grep -q '/mnt/app/carplaymaps' "$SI_DIR/smartphone_integrator.json" 2>/dev/null; then
    say "smartphone_integrator.json already carries our runtime -> skip"
    cp -f "$SI_DIR/smartphone_integrator.json" "$S_TMP/si.new" \
        || die SI_BACKUP_FAILED
else
    cp -f "$SI_DIR/smartphone_integrator.json" "$S_TMP/si.prev"     || die CONFIG_BACKUP_FAILED
    "$STAGE/wireless/config-patch" si "$S_TMP/si.prev" \
        "$S_TMP/si.new"           || die SMARTPHONE_INTEGRATOR_PATCH_FAILED
fi
[ -s "$S_TMP/connectivity.new" ] || die CONNECTIVITY_PATCH_EMPTY
[ -s "$S_TMP/si.new" ]           || die SI_PATCH_EMPTY
mv -f "$S_TMP/connectivity.new" "$SI_DIR/connectivity.json"    || die CONNECTIVITY_ACTIVATE_FAILED
mv -f "$S_TMP/si.new" "$SI_DIR/smartphone_integrator.json"     || die SI_ACTIVATE_FAILED
ok PRODUCTION_CONFIG

# --------------------------------------------------------- persist switches ---
# The package's own flag files, byte for byte (each is "1\n"; wcp_cp_stage "3\n").
say "writing persist switches"
mkdir -p "$PERSIST/omonob-phone" || die PERSIST_MKDIR_FAILED
for f in btwcp_enable btwcp_present_target wcp_autostart wcp_cp_stage; do
    cp -f "$STAGE/wireless/common/config/$f" "$PERSIST/$f" || die PERSIST_FAILED_$f
done
cp -f "$STAGE/wireless/profiles/$PROFILE/altscreen.conf" \
      "$PERSIST/altscreen.conf"                || die PERSIST_FAILED_ALTS
cp -f "$STAGE/wireless/profiles/$PROFILE/altscreen.geom" \
      "$PERSIST/altscreen.geom"                || die PERSIST_FAILED_GEOM
cp -f "$STAGE/wireless/profiles/$PROFILE/v75-wireless-display.conf" \
      "$PERSIST/v75-wireless-display.conf"     || die PERSIST_FAILED_V75
cp -f "$STAGE/wireless/profiles/$PROFILE/cluster-profile" \
      "$PERSIST/omonob-phone/cluster-profile"  || die PERSIST_FAILED_CLUSTER
chmod 644 "$PERSIST/btwcp_enable" "$PERSIST/btwcp_present_target" \
          "$PERSIST/wcp_autostart" "$PERSIST/wcp_cp_stage" \
          "$PERSIST/altscreen.conf" "$PERSIST/altscreen.geom" \
          "$PERSIST/v75-wireless-display.conf" \
          "$PERSIST/omonob-phone/cluster-profile" || die PERSIST_CHMOD_FAILED
ok PERSIST

# ------------------------------------------------------------------ verify ---
say "verify"
[ -s "$ROOT/wireless-entry" ]  || die VERIFY_WIRELESS_ENTRY
[ -s "$ROOT/wireless-receiver-exec" ] || die VERIFY_WIRELESS_RECEIVER_EXEC
[ -s "$ROOT/wireless-video-exec" ]    || die VERIFY_WIRELESS_VIDEO_EXEC
[ -s "$ROOT/libomonob-wireless-maps.so" ] || die VERIFY_WIRELESS_MAPS_LIB
[ -s "$ROOT/start-wireless-maps.sh" ]     || die VERIFY_START_SCRIPT
[ -s "$ROOT/libv75-transport.so" ]        || die VERIFY_TRANSPORT_LIB
[ -s "$ROOT/libv75-wireless-video-tap.so" ] || die VERIFY_VIDEO_TAP_LIB
[ -s "$ROOT/wcp_video_stock" ]            || die VERIFY_VIDEO_STOCK
[ -s "$ROOT/wcp_video_tap" ]              || die VERIFY_VIDEO_TAP
[ -s "$OTA/wcp_receiver" ]     || die VERIFY_WCP_RECEIVER
[ -s "$OTA/libbtwcp.so" ]      || die VERIFY_LIBBTWCP
[ -s "$OTA/btstack_wrap.sh" ]  || die VERIFY_BTSTACK_WRAP
[ -s "$OTA/wcp_autostart.sh" ] || die VERIFY_WCP_AUTOSTART
[ -s "$OTA/wcp_chansync.sh" ]  || die VERIFY_WCP_CHANSYNC
[ -s "$OTA/wcp_ctl.sh" ]       || die VERIFY_WCP_CTL
[ -s "$OTA/wcp_pf.sh" ]        || die VERIFY_WCP_PF
[ -s "$OTA/wcp_pfwatch.sh" ]   || die VERIFY_WCP_PFWATCH
[ -s "$OTA/wcp_video" ]        || die VERIFY_WCP_VIDEO
for j in CarPlayWireless-CP-55915411 CarPlayWireless-SI-55915411 \
         CarPlayWireless-Touch-55915411 WirelessMapsBootstrap; do
    [ -s "$JARS/$j.jar" ] || die VERIFY_JAR_$j
done
for f in btwcp_enable btwcp_present_target wcp_autostart wcp_cp_stage \
         altscreen.conf altscreen.geom v75-wireless-display.conf; do
    [ -s "$PERSIST/$f" ] || die VERIFY_PERSIST_$f
done
[ -s "$PERSIST/omonob-phone/cluster-profile" ] || die VERIFY_PERSIST_CLUSTER
# The connectivity.json swap must have actually landed: config-patch writes
# the literal /mnt/ota/btstack_wrap.sh into the btstack exec entry.
grep -q 'btstack_wrap.sh' "$SI_DIR/connectivity.json" \
    || die VERIFY_CONNECTIVITY_WRAP
[ -s "$SI_DIR/smartphone_integrator.json" ] || die VERIFY_SI_JSON
# The wireless jars must appear on exactly one active classpath line.
n=$(awk '/^[ \t]*#/{next} /CarPlayWireless-CP-55915411/{c++} END{print c+0}' "$LSD")
[ "$n" = "1" ] || die VERIFY_LSD_CLASSPATH_$n
n=$(awk '/^[ \t]*#/{next} /WirelessCarPlayMaps/{c++} END{print c+0}' "$BUNDLES")
[ "$n" -ge 1 ] || die VERIFY_BUNDLES_SLOT
# The merged VCMenu must be the payload's bytes. QNX grep cannot reliably scan
# class names inside a ZIP, so compare the files with the project's own checker
# (the same tool and call install-carplay-maps.sh already uses for this jar).
"$STAGE/common/cpmap-nav-check" --same "$STAGE/profiles/$MU/$CLUSTER/VCMenu.jar" \
    "$JARS/VCMenu.jar" || die VERIFY_VCMENU_BYTES
[ -s "$ROOT/core.so" ]                      || die VERIFY_CORE
[ -s "$ROOT/stock_first/dio_manager.real" ] || die VERIFY_STOCK_DIO
ok VERIFIED

# ------------------------------------------------------------------- finish ---
rm -rf "$S_TMP"
rm -rf "$LOCK"
# The project's own installer already wrote $ROOT/VERSION and $ROOT/PROFILE.
sync
say "done"
ok INSTALL_COMPLETE
echo "Restart the unit manually. Nothing was rebooted and no shared ESO service was stopped."
exit 0
