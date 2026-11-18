# ADB over Network Toggle

An APatch/KernelSU module that turns TCP ADB (port 5555) on and off. Connections are only accepted on one network interface you choose. IPv4 and IPv6 firewall rules drop all other traffic to the port.

- **Action button.** Toggles TCP ADB. If adbd is already listening without the firewall, or the firewall points at an old interface, the Action button fixes it instead of turning ADB off. If the selected interface isn't available, it turns ADB off.
- **WebUI.** Shows the live status and the `adb connect` address, and lets you choose the interface.
- **Module description.** Shows the status. The module refreshes it after every change and at boot.

## Use cases

- **ADB on untrusted networks.** On public Wi-Fi, hotel networks or mobile data, you can keep using ADB over Tailscale. Port 5555 stays closed to everyone else on the network.
- **ADB for other devices in your tailnet.** Any computer in your tailnet can connect to the phone, wherever both devices are. For example, coding agents such as Claude Code or Codex running on a desktop can install builds, read logs and run tests on the phone while you are away from it.

## Interface selection

The default, **Tailscale (auto)**, finds the Tailscale interface by its address (`fd7a:115c:a1e0::/48`, or `100.64.0.0/10` on a `tun*` interface). Android numbers VPN interfaces `tun0`, `tun1`, … in the order they are created, so the name alone is not reliable.

You can also pick a fixed interface, for example `wlan0` for LAN access. The module saves the choice in `/data/adb/adb_tcp_toggle.conf`.

If Tailscale reconnects on a different `tun` interface while ADB is on, the port stays firewalled to the old interface and can't be reached. The status shows "Unreachable" until you press Action or Re-apply. If Tailscale is off, Action and the WebUI's Disable button turn TCP ADB off.

## Safety

- The module installs the firewall before adbd starts listening, and removes it only after adbd has stopped.
- TCP ADB is session-only. It turns off on reboot, and the module clears `persist.adb.tcp.port`.
- Boot only refreshes the status. It never turns ADB on.
- The module doesn't change `ro.adb.secure`, so devices still need ADB authorization.

Limits:

- In Tailscale mode, every device your Tailscale access controls allow to reach the phone can connect to port 5555. To narrow that down, allow `tcp:5555` only from the computers that need it.
- An authorized ADB key gets a full shell, and root too on a rooted phone. Revoke old authorizations in Developer options.
- Choosing `wlan0` opens the port to everyone on that Wi-Fi network. Don't choose it on public Wi-Fi.
- The module only controls port 5555. Android's Wireless debugging uses its own random port and is not firewalled. Turn it off on public Wi-Fi.
- If something else turns on TCP ADB, for example `adb tcpip 5555`, the port is open on every interface until you press Action. The status then shows "Exposed".

Install the zip from [Releases](https://github.com/D3SOX/adb-tcp-toggle/releases) in APatch or KernelSU. The manager offers later versions as updates.

Connect with `adb connect <address>:5555`.
