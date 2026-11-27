# First-time pairing (required once per phone)

The wireless link reuses the phone that is already paired with the unit over
Bluetooth. A fresh install will not connect a phone that was never paired, so
do this **once** after the installer finishes and the unit has restarted:

1. **Pair the phone over Bluetooth** in the unit's phone menu
   (*Phone → Search for devices*). Let the unit see the phone and accept it.
2. **Enable the unit's WLAN hotspot** in the network settings if it is off.
   The HMI switches it on automatically later, but it must exist once.
3. **Connect the phone with a USB cable** and start wired CarPlay. Let it
   reach the CarPlay screen — this writes the CarPlay record the wireless
   path reads afterwards.
4. **Disconnect the cable.**
5. **Restart the unit** from its own menu, or power-cycle through the ignition.

After that restart the receiver starts by itself and the phone connects over
Wi-Fi without a cable. A second phone must go through the same sequence once.

If the phone never connects, check that `/mnt/persist/wcp_autostart` exists
and read `/dev/shmem/wcp_autostart.log` (see [operation](operation.md)).
