# Operation — controls, logs, switches

After the reboot the receiver starts by itself. The stock WLAN hotspot must be
on — the HMI switches it on automatically if it is off.

## Runtime controls

```sh
sh /dev/shmem/wcp_ctl.sh status
sh /dev/shmem/wcp_ctl.sh start
sh /dev/shmem/wcp_ctl.sh stop
sh /mnt/ota/wcp_pf.sh on|off|check
```

## Logs

```
/dev/shmem/wcp_autostart.log
/dev/shmem/wcp.log
/dev/shmem/wcp_video.log
```

## Switches

A file present under `/mnt/persist` enables the behaviour; delete it to
disable. All survive a reboot.

| File | Effect when present |
|---|---|
| `wcp_autostart` | Start the receiver at boot (installed on) |
| `btwcp_enable` | Arm the Bluetooth wrapper (installed on) |
| `btwcp_off` | Wireless off — unit behaves like factory Bluetooth |
| `wcp_cp_off` | Keep the wired CarPlay stage instead of switching to wireless |
| `wcp_hs_off` | Do not auto-request the stock WLAN hotspot |
| `wcp_si_off` | Do not intercept phone selection |
| `wcp_touch_off` | Do not take over touch injection |
