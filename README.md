# MIB2 Wireless CarPlay — MHI2

Wireless CarPlay for the MIB2 SEAT P4709 harman head unit, with the CarPlay map card
rendered in the instrument cluster.

Installs as an SWDL software-update card, or manually over SSH.

---

## Firmware

Built and validated against exactly this software train:

MHI2_ER_SEG11_P4709_MU1447

## Compatibility

Do not install this on AUDI , VW or SKODA firmwares MU1367, MU1433 or MU1440. They are different
firmware trains with different HMI class layouts.

---

## Features

- **Wireless CarPlay.** The phone connects over the unit's own WLAN hotspot; no
  cable. Bluetooth pairing is bridged so the phone treats it as a normal
  CarPlay session stable and smooth.
- **CarPlay map card in the instrument cluster**, at the cluster's native
  1010 × 376 with the correct safe area for seat clusters.
- **Navigation guidance data Card** on the cluster card (manoeuvre, distance,
  street).
- **Touch on the main screen** is forwarded to the phone with the correct
  scale.
- **Runtime switches** under `/mnt/persist` to turn individual parts off without
  uninstalling (see *Running it*).

The wired CarPlay path is untouched: the stock `dio_manager` is preserved at
`/mnt/app/carplaymaps/stock_first/dio_manager.real` and used as the real binary
behind a wrapper.

---

## Installation

### Route A — SWDL software update (no shell needed)

1. Format an SD card as **FAT32**.
2. Copy the **contents of this repository** to the card root, so the card looks
   exactly like this:

   ```
   <card>/metainfo2.txt
   <card>/install.sh
   <card>/uninstall.sh
   <card>/final/finalScript.sh
   <card>/final/hashes.txt
   <card>/final/wireless.ver
   <card>/payload/...
   ```

   `metainfo2.txt` must sit at the root, next to `install.sh`, `final/` and
   `payload/`. Do not nest everything inside an extra folder.
3. Insert the card into the unit.
4. Open the software-update / SWDL menu and start the update. The updater lists
   **Nadeem Wireless Carplay V1.0**.
5. The updater runs the package, restarts the unit, then runs it a second time to
   finalise. This two-pass behaviour is normal — let both passes finish.
6. Restart the unit once more before connecting a phone.

The updater writes its log to `Log/install_wireless.txt` on the card. If the
card is refused before anything runs, that log will not exist at all; that means
the metainfo/checksum chain rejected the card, not that the installer failed.

### Route B — manual over SSH

You need SSH access to the unit as `root`. `<unit>` below is its IP address.

**1. Create the staging folder on the unit and copy the tree into it.**

From the folder that contains this repository:

```sh
ssh root@<unit> 'mkdir -p /mnt/app/.wmaps-manual'
scp -r metainfo2.txt install.sh uninstall.sh final payload     root@<unit>:/mnt/app/.wmaps-manual/
```

`final/` and `metainfo2.txt` are only used by the SWDL route, but copying them
keeps both routes identical and costs nothing.

**2. Check what landed.**

```sh
ssh root@<unit> 'ls -l /mnt/app/.wmaps-manual'
```

You should see `install.sh`, `uninstall.sh`, `final/`, `payload/` (and
`metainfo2.txt`). If `payload/` is missing, the installer stops at
`CPMAP_MANUAL_FAIL=PAYLOAD_MISSING_...` without touching anything.

**3. Run the installer.**

```sh
ssh root@<unit> 'cd /mnt/app/.wmaps-manual && sh install.sh'
```

It prints one `CPMAP_OK=<step>` line per phase. On the first failure it prints
`CPMAP_MANUAL_FAIL=<reason>` and exits; every check runs before the first write,
so a failed check leaves the unit untouched.

**4. Restart the unit** before connecting a phone.

**Uninstalling over SSH** uses the same staged folder:

```sh
ssh root@<unit> 'cd /mnt/app/.wmaps-manual && sh uninstall.sh'
ssh root@<unit> 'shutdown -r'
```

`uninstall.sh` reads the baseline at `/mnt/app/.carplaymaps-first-baseline/`, so
the staging folder must still exist (`scp` it again if you deleted it). If the
baseline is gone, the script stops at `CPMAP_MANUAL_FAIL=NO_FIRST_BASELINE`
instead of guessing.

If the unit does not answer on SSH after the install, use route A to reinstall
or connect over serial — the installer never changes SSH, passwords or keys.

Both routes run the same `install.sh`; the SWDL route just calls it for you.
`install.sh` sets its own `PATH`, so it works from the updater's minimal
environment and from an SSH login shell alike.

---

## First-time pairing (required once)

The wireless link reuses the phone that is already paired with the unit over
Bluetooth. A fresh install will not connect a phone that was never paired, so do
this **once** after the installer finishes and the unit has restarted:

1. **Pair the phone over Bluetooth** in the unit's own phone menu
   (*Phone - Search for devices*). Let the unit see the phone and accept it.
2. **Enable the unit's WLAN hotspot** in the network settings if it is off.
   The HMI switches it on automatically later, but it must exist once.
3. **Connect the phone with a USB cable** and start wired CarPlay. Let it reach
   the CarPlay screen - this is what writes the CarPlay record the wireless path
   reads afterwards.
4. **Disconnect the cable.**
5. **Restart the unit** from the unit's own menu, or power-cycle through the
   ignition.

After that restart the receiver starts by itself and the phone connects over
Wi-Fi without a cable. Steps 1-3 are needed once per phone; a second phone must
go through the same sequence once.

If the phone never connects, check that `/mnt/persist/wcp_autostart` exists and
read `/dev/shmem/wcp_autostart.log`.

---

## Running it

After the reboot the receiver starts by itself. The stock WLAN hotspot must be
on — the HMI switches it on automatically if it is off.

Runtime controls, if something needs restarting without a reboot:

```sh
sh /dev/shmem/wcp_ctl.sh status
sh /dev/shmem/wcp_ctl.sh start
sh /dev/shmem/wcp_ctl.sh stop
sh /mnt/ota/wcp_pf.sh on|off|check
```

Logs:

```
/dev/shmem/wcp_autostart.log
/dev/shmem/wcp.log
/dev/shmem/wcp_video.log
```

### Switches

Presence of a file enables the behaviour; delete it to disable. All live under
`/mnt/persist` and survive a reboot.

| file | effect when present |
|---|---|
| `wcp_autostart` | start the receiver at boot (installed on) |
| `btwcp_enable` | arm the Bluetooth wrapper (installed on) |
| `btwcp_off` | wireless off - unit behaves like factory Bluetooth |
| `wcp_cp_off` | keep the wired CarPlay stage instead of switching to wireless |
| `wcp_hs_off` | do not auto-request the stock WLAN hotspot |
| `wcp_si_off` | do not intercept phone selection |
| `wcp_touch_off` | do not take over touch injection |

---

## Rollback

**Over SSH**, from the staged folder:

```sh
ssh root@<unit> 'cd /mnt/app/.wmaps-manual && sh uninstall.sh'
```

Then restart the unit. If you deleted the staging folder, either copy it again
or run `sh /mnt/app/.wmaps-manual/uninstall.sh` from a shell on the unit.

**With an SD card**, put `uninstall.sh` on a FAT32 card and run it through the
SWDL menu the same way as the installer - the metainfo2 chain is identical.

`uninstall.sh` validates the whole baseline before restoring a single file, then:

- restores every tracked file byte for byte,
- deletes the files the installer created (the factory had none),
- restores the `carplaymaps/` runtime tree wholesale,
- clears the persist switches and removes the wireless engine from `/mnt/ota`.

Restart the unit afterwards to return the HMI to its factory classpath.

The baseline stays at `/mnt/app/.carplaymaps-first-baseline/` for inspection;
delete it yourself once you are satisfied. If it is missing, the script stops at
`CPMAP_MANUAL_FAIL=NO_FIRST_BASELINE` rather than guessing.

---

Original wireless engine and Altscreen maps for : **omonob** https://github.com/omonob/VW-MHI2-Wireless-Carplay-Maps
