#!/bin/sh
# Wireless CarPlay Maps for MU1447 (SEAT G11, AID10.5 / cluster 790)
# MANUAL SSH INSTALLER - no SWDL, no ESD, no metainfo, no GEM entry.
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

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
STAGE=${STAGE:-$SELF_DIR/payload}

LSDBASE=/mnt/app/eso/hmi/lsd
ROOT=/mnt/app/carplaymaps
# The baseline must live OUTSIDE the tree it snapshots: it copies the whole
# carplaymaps runtime, and a backup inside it would recurse into itself.
BAK=/mnt/app/.carplaymaps-first-baseline
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

say() { echo "### $*"; }
die() { echo "CPMAP_MANUAL_FAIL=$1"; exit 1; }
ok()  { echo "CPMAP_OK=$1"; }

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

for t in awk cat chmod cp grep ls mkdir mount mv rm sh slay sync; do
    command -v "$t" >/dev/null 2>&1 || die REQUIRED_TOOL_MISSING_$t
done

# The payload must be complete before anything on the unit changes.
for f in \
    "$STAGE/common/install-carplay-maps.sh" \
    "$STAGE/common/merge-wireless.sh" \
    "$STAGE/profiles/$MU/$CLUSTER/core.so" \
    "$STAGE/profiles/$MU/$CLUSTER/VCMenu.jar" \
    "$STAGE/profiles/$MU/$CLUSTER/VCMirrorRate.jar" \
    "$STAGE/profiles/$MU/$CLUSTER/CarPlayClusterControls.jar" \
    "$STAGE/wireless/profiles/$PROFILE/wcp_receiver" \
    "$STAGE/wireless/profiles/$PROFILE/wireless-entry" \
    "$STAGE/wireless/profiles/$PROFILE/wireless-receiver-exec" \
    "$STAGE/wireless/profiles/$PROFILE/libomonob-wireless-maps.so" \
    "$STAGE/wireless/common/ota/wcp_autostart.sh" \
    "$STAGE/wireless/common/ota/libbtwcp.so" \
    "$STAGE/wireless/common/ota/btstack_wrap.sh" \
    "$STAGE/wireless/common/jars/CarPlayWireless-CP-55915411.jar" \
    "$STAGE/wireless/common/jars/CarPlayWireless-SI-55915411.jar" \
    "$STAGE/wireless/common/jars/CarPlayWireless-Touch-55915411.jar" \
    "$STAGE/wireless/common/jars/WirelessMapsBootstrap.jar" \
  ; do
    [ -s "$f" ] || die PAYLOAD_MISSING_${f##*/}
done
ok PREFLIGHT

# --------------------------------------------------------- mounts + children ---
say "remount read-write"
for p in /mnt/app /mnt/ota /mnt/system /mnt/persist; do
    mount -uw "$p" 2>/dev/null || true
done

# Only project-owned processes. Shared ESO services are left to the reboot.
say "stopping project children (if any)"
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

# ----------------------------------------------- first baseline (idempotent) ---
# Snapshot only what this installer touches. A second run reuses the very first
# snapshot, so an update can never launder a modified original into "stock".
# Each file is mirrored at $BAK/files<absolute path>; the manifest is one
# "STATE path" line each - no ids, so no printf is needed.
TRACKED="
/mnt/app/eso/bin/apps/dio_manager
/mnt/app/eso/bin/apps/btstack
/mnt/app/eso/bin/apps/connectionmanager
/mnt/app/eso/hmi/lsd/lsd.sh
/mnt/app/eso/hmi/lsd/config/bundles.properties
/mnt/app/eso/hmi/lsd/jars/VCMenu.jar
/mnt/app/eso/hmi/lsd/jars/VCMirrorRate.jar
/mnt/app/eso/hmi/lsd/jars/CarPlayClusterControls.jar
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

if [ -s "$BAK/MANIFEST" ]; then
    say "first baseline already present -> reusing $BAK"
else
    say "creating first baseline in $BAK"
    rm -rf "$BAK.new"
    mkdir -p "$BAK.new/files"
    : > "$BAK.new/MANIFEST"
    for p in $TRACKED; do
        if [ -e "$p" ]; then
            mkdir -p "$BAK.new/files${p%/*}" || die BASELINE_MKDIR_FAILED_$p
            cp -p "$p" "$BAK.new/files$p"    || die BASELINE_COPY_FAILED_$p
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
    mv "$BAK.new" "$BAK" || die BASELINE_COMMIT_FAILED
    ok BASELINE_CREATED
fi

# --------------------------------------------------- carplay VC (wired half) ---
# The project's own installer, which already supports MU1447:790.
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
# leaves the live JSON untouched.
say "patching production config"
cp -f "$SI_DIR/connectivity.json" "$S_TMP/connectivity.prev"    || die CONFIG_BACKUP_FAILED
cp -f "$SI_DIR/smartphone_integrator.json" "$S_TMP/si.prev"     || die CONFIG_BACKUP_FAILED
"$STAGE/wireless/config-patch" connectivity "$S_TMP/connectivity.prev" \
    "$S_TMP/connectivity.new" || die CONNECTIVITY_PATCH_FAILED
"$STAGE/wireless/config-patch" si "$S_TMP/si.prev" \
    "$S_TMP/si.new"           || die SMARTPHONE_INTEGRATOR_PATCH_FAILED
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
[ -s "$OTA/wcp_receiver" ]     || die VERIFY_WCP_RECEIVER
[ -s "$OTA/libbtwcp.so" ]      || die VERIFY_LIBBTWCP
[ -s "$OTA/btstack_wrap.sh" ]  || die VERIFY_BTSTACK_WRAP
for j in CarPlayWireless-CP-55915411 CarPlayWireless-SI-55915411 \
         CarPlayWireless-Touch-55915411 WirelessMapsBootstrap; do
    [ -s "$JARS/$j.jar" ] || die VERIFY_JAR_$j
done
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
# The project's own installer already wrote $ROOT/VERSION and $ROOT/PROFILE.
sync
say "done"
ok MANUAL_INSTALL_COMPLETE
echo "Restart the unit manually. Nothing was rebooted and no shared ESO service was stopped."
exit 0
