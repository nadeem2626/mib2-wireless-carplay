# Installation

Both routes run the same `install.sh`. Every check runs before the first
write, so a failed check leaves the unit untouched. `install.sh` sets its own
`PATH`, so it works from the updater's minimal environment and from an SSH
login shell alike.

Confirm your firmware first: only `MHI2_ER_SEG11_P4709_MU1447` (SEAT) and
`MHI2_ER_VWG13_K4525_MU1367` (VW) are supported.

---

## Route A — SD card (SWDL, no shell needed)

1. Format an SD card as **FAT32**.
2. Copy the **package contents** to the card root, so the card looks exactly
   like this:

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
   `payload/` — not nested inside an extra folder.
3. Insert the card and open the software-update (SWDL) menu. The updater lists
   **Wireless Carplay V1.0** — start it.
4. The updater runs the package, restarts the unit, then runs it a second
   time to finalise. This two-pass behaviour is normal — let both passes finish.
5. Restart the unit once more before connecting a phone.

The updater logs to `Log/install_wireless.txt` on the card. If there is no log
at all, the metainfo/checksum chain rejected the card before anything ran —
that is not an installer failure.

---

## Route B — manual over SSH

You need SSH access to the unit as `root`. `<unit>` below is its IP address.

**1. Stage the tree on the unit.** From the folder that contains the package:
from sd :
cd /fs/sda0/
sh install.sh
then reboot the unit .
or 
```sh
ssh root@<unit> 'mkdir -p /mnt/app/.wmaps-manual'
scp -r metainfo2.txt install.sh uninstall.sh final payload \
    root@<unit>:/mnt/app/.wmaps-manual/
```

`final/` and `metainfo2.txt` are only used by the SWDL route, but copying them
keeps both routes identical.

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

It prints one `CPMAP_OK=...` line per phase. On the first failure it prints
`CPMAP_MANUAL_FAIL=...` and exits.

**4. Restart the unit** before connecting a phone.

If the unit does not answer on SSH after the install, use Route A to reinstall
or connect over serial — the installer never changes SSH, passwords or keys.

---

Next: [first-time pairing](pairing.md), required once per phone.
