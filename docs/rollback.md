# Rollback — uninstall and factory restore

`uninstall.sh` validates the whole baseline before restoring a single file.

## Over SSH

From the staged folder (see [installation](installation.md)):

```sh
ssh root@<unit> 'cd /mnt/app/.wmaps-manual && sh uninstall.sh'
ssh root@<unit> 'shutdown -r'
```

If you deleted the staging folder, copy it again first, or run
`sh /mnt/app/.wmaps-manual/uninstall.sh` from a shell on the unit.

## With an SD card

Either of these is enough to start the removal through the SWDL menu:

- Download the ready `uninstall` file from the release and copy it to a FAT32
  card, or
- create an empty file named `uninstall` on the card yourself.

That file alone starts the removal.

## What it does

- Restores every tracked file byte for byte.
- Deletes the files the installer created (the factory had none).
- Restores the `carplaymaps/` runtime tree wholesale.
- Clears the persist switches and removes the wireless engine from `/mnt/ota`.

Restart the unit afterwards to return the HMI to its factory classpath.

The baseline stays at `/mnt/app/.carplaymaps-first-baseline/` for inspection;
delete it yourself once you are satisfied. If the baseline is missing, the
script stops at `CPMAP_MANUAL_FAIL=NO_FIRST_BASELINE` rather than guessing.
