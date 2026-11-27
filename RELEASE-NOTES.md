# Release notes — text for the first pre-release

Suggested release title: **MIB2 Wireless CarPlay v1.0-pre — first pre-release**
(mark it as a pre-release in the GitHub release options)

Body to paste:

---

Native wireless Apple CarPlay for MIB2 (MHI2) harman head units, with
navigation maps in the instrument cluster — over wired and wireless.

## What's new

- **Touch fixed** — works cleanly alongside the factory interface and the
  car's own functions.
- **Installer reworked** — safer checks, cleaner install and uninstall.
- **VW support added** — first VW train: `MHI2_ER_VWG13_K4525_MU1367`.

## Supported firmware

| Brand | Firmware train | Cluster map |
|---|---|---|
| SEAT | `MHI2_ER_SEG11_P4709_MU1447` | 1010 × 376 |
| VW | `MHI2_ER_VWG13_K4525_MU1367` | 800 × 480 (12.3-inch, 791) |

**Warning:** only these two trains are supported. Every other firmware —
including AUDI and SKODA MU1433 / MU1440 and any other VW or SEAT build —
uses different HMI class layouts. Do not install on it.

## Install

1. Download the package attached to this release.
2. **SD card:** copy the package contents to a FAT32 card root and run the
   update from the unit's software-update (SWDL) menu.
   **Or over SSH:** stage the same tree on the unit and run `install.sh`.
3. Pair each phone once: Bluetooth pairing → WLAN hotspot on → one wired
   CarPlay session → restart.

Full guides are in the repo: `docs/installation.md`, `docs/pairing.md`,
`docs/operation.md`, `docs/rollback.md`.

## Status

First pre-release — tested on the developer's own units and shared for early
adopters. Feedback and bug reports via Issues.

## Credits

Original wireless engine and Altscreen maps scripts by
[omonob](https://github.com/omonob/VW-MHI2-Wireless-Carplay-Maps).
