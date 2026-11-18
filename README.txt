ADB over Tailscale Toggle for APatch

- Press the module's Action button in APatch Manager to toggle ADB TCP.
- The module description doubles as a status line, similar to ReZygisk:
    [ADB TCP: ✅ ON, Firewall: ✅ Tailscale-only] 100.x.x.x:5555
    [ADB TCP: ❌ OFF]
    [ADB TCP: ⚠️ ON, Firewall: ❌ INCOMPLETE]
- action.sh refreshes this status after every success or error.
- boot-completed.sh ONLY refreshes the status after reboot. It does not enable ADB,
  start adbd on TCP, or install firewall rules.
- No service.sh or system.prop is included.
- Every Action result stays visible with a 3-second closing countdown.
- ON requires Tailscale on tun0 with a 100.x IPv4 address.
- ON installs IPv4 and IPv6 firewall rules before starting adbd on TCP 5555.
- Only packets entering via tun0 are accepted on TCP 5555.
- OFF disables TCP ADB, restarts adbd, verifies 5555 stopped listening, then removes the firewall.
- ro.adb.secure remains untouched. Keep ADB authorization enabled.

Connect from your computer with:
  adb connect <phone-tailscale-ip>:5555

If APatch Manager is already open when the status changes, refresh/reopen the Modules page
if the description is cached by that Manager build.
