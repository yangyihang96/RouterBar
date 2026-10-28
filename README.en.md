# RouterBar

[简体中文](README.md) | English

An unofficial native macOS menu bar app for ASUS routers, running stock Asuswrt or Asuswrt-Merlin. The sidebar is built from the connected router's own web menu, with the same names and order as its web interface. Every page is native SwiftUI / AppKit; no web view is embedded.

- **Menu bar**: internet status, whole-router download and upload speed, online devices, CPU and memory.
- **Devices**: 21 device categories, card and list views, per-device traffic, device history and offline alerts.
- **Settings**: native pages that mirror the web tabs one to one. Field types and ranges follow the firmware's own validation rules; changes are listed before saving and read back afterwards.
- **Read-only by default**: firmware that has not been checked stays read-only, and every change to the router asks for confirmation.

> **What has been tested**: on real hardware, only an RT-BE88U on Asuswrt-Merlin 3006.102.5, and only read-only. Writes have been tested against simulated routers, not yet on a real one. Other models are supported by reading each router's own menu and firmware details, not by testing every model.

The interface is in Simplified Chinese only.

## Screenshots

<img src="docs/screenshots/menu-panel.png" width="420" alt="Menu bar panel">

![Network map overview](docs/screenshots/overview.png)

![Connected devices, dark mode](docs/screenshots/clients-dark.png)

![Firewall settings on 3004.388 firmware: current values only](docs/screenshots/settings-readonly.png)

The screenshots are rendered from the app's built-in sample data, not a real network.

## Which routers

After connecting, the app reads the model, firmware branch, stock or Merlin, and the radio bands. It then runs the router's own `state.js` and `menuTree.js` with JavaScriptCore in a child process that can be stopped at any time (no network, file or DOM access; stopped after 4 s, 1 MB of output or 512 MB of memory), and applies the web interface's `showMenuTree` rules to get the menus, tabs and names this router actually shows. Tabs the web interface hides for the model or current settings are hidden too. Menus and model details are cached locally so the next launch can show them right away.

Writes depend on the firmware:

| Firmware | Writes |
| --- | --- |
| 3.0.0.6.102 (3006) | Settings and feature pages can save; professional wireless settings only on RT-BE88U |
| 3.0.0.4 branches 384 / 386 / 388 | Settings show current values only. The five maintenance actions that work the same on every branch remain: firmware upload, config restore, factory reset, reboot, network diagnostics |
| Older or unrecognised versions | Fully read-only |

Nothing is written until the app has identified the model and firmware and read the router's menu in the current session. After a firmware update it identifies the router again before allowing writes. Tri-band and quad-band routers get one wireless tab per actual band.

## Features

- **Overview and menu bar**: internet status, whole-router traffic, device count, CPU, memory, uptime. Traffic comes from the router's INTERNET counters, not this Mac's speed.
- **Devices**: filter by category, search, card and list views; rename a device or pause and resume its internet access.
- **Device history and offline alerts**: records the online and offline changes seen while the app runs, kept for 30 days; a watched device that stays offline for 3 minutes triggers a notification.
- **Network health**: WAN status, ping and DNS lookup from the router, weak signals, memory, storage and temperature. It shows the evidence and never changes settings.
- **Wi-Fi and networks**: SSID, security, guest networks, isolation and the Wi-Fi 7 mode switch. Wireless security is checked as a whole against the 3006 web rules: WPA3 requires protected management frames, and 6 GHz allows WPA3 only.
- **Settings**: 59 sections and 650 fields covering wireless, LAN / DHCP, WAN / DNS, IPv6, port forwarding, routing, firewall, VPN, QoS and system settings, with a native time zone and daylight saving picker.
- **VPN**: OpenVPN client and server, WireGuard, PPTP / L2TP and VPN Fusion.
- **More native pages**: AiMesh nodes, AiCloud, Open NAT, Game Boost, Dual WAN, Parental Controls, AiDisk, the network setup wizard and more.
- **Firmware and maintenance**: check for and download Asuswrt-Merlin releases, or pick a local firmware file; SHA-256 check, upload progress, waiting for the reboot and reading the version back. Config backup and restore, reboot.
- **Read-only information**: system info, traffic monitor, AiProtection logs, Traffic Analyzer, system log, DHCP leases, routing table, connection log.
- **Network tools**: ping, traceroute, DNS lookup and netstat run on the router.

## Getting started

1. Build and install (see Building), then open `~/Applications/RouterBar.app`. The app stays in the menu bar when the main window is closed.
2. In Connection Settings, enter the router address (for example `http://192.168.50.1`) and the admin account. On macOS 15 and later, allow local network access when asked.
3. Choose to save the password to sign in from the keychain next time.

HTTPS addresses use the system's certificate validation. If the router's self-signed certificate is not trusted, use the HTTP address on your local network.

## What happens when you change a setting

Edits do not touch the router right away. When you save, the app reads the current values again and lists the variables it will write and what they affect. After submitting, it reads them back and only shows "saved and confirmed" when they match. Firmware upload, reboot, restore and delete actions explain their impact separately.

If the connection drops after a request was sent, or the router answers with a 5xx or something unrecognised, the app shows "result not confirmed" and asks you to reload and check. It does not treat this as a failure and never resends on its own. Actions that need a reboot are checked after the router comes back. Writes are serialised, and routine polling pauses while one is in progress.

## Data and privacy

- The app only connects to the router you enter, plus two public addresses when you use the matching feature: SourceForge when checking for or downloading Merlin firmware (a separate HTTPS session without cookies or router credentials), and an ASUS server for the Open NAT game list, the same one the router's web page uses. When you run a network health check, the router itself pings 1.1.1.1 and looks up example.com.
- No analytics, telemetry or crash reporting.
- The password is stored in the macOS keychain only if you choose to save it. Session cookies live in a separate temporary session; browser cookies are never read.
- Device history is stored only on this Mac, in `~/Library/Application Support/com.yihang.RouterBar/DeviceHistory` (directory mode 0700, files 0600), and contains no passwords or cookies.

## Building

Requires macOS 14 or later. `Package.swift` needs a Swift 6.0 toolchain; the project is currently built and tested with Xcode 27.1 (Swift 6.4). There are no third-party dependencies.

```sh
./script/test.sh                        # run the tests
./script/build_and_run.sh               # build, install to ~/Applications/RouterBar.app and open
./script/build_and_run.sh --build-only  # build only
```

Build caches go to `~/Library/Caches/com.yihang.RouterBar/`, and a copy of the app is zipped to `dist/RouterBar.zip`. Signing picks an Apple Development certificate from your keychain (override with `CODESIGN_IDENTITY`); without one it signs ad hoc, and the keychain will ask again after every update. The app is not notarised, and no prebuilt download is provided.

## Known limitations

- Not every feature of the web interface is covered yet: captive portal, complex port / VLAN binding, all AiMesh pairing and backhaul options, every OpenVPN account and custom directive, USB accounts and folder permissions, and third-party AiCloud linking are incomplete. When a compound rule is not compatible, the app stops saving that item and keeps the original value.
- In the network setup wizard, the DSL, 4G / 5G, AiMesh setup and repeater / bridge scanning branches, and the factory-default state, open the web wizard in a browser.
- No device history is recorded while the app is not running or the Mac is asleep, and none is guessed afterwards.

## Source layout

- `Sources/RouterCore`: router protocol, parsing, menu evaluation, write gating and the settings catalog; no UI.
- `Sources/RouterBar`: SwiftUI / AppKit interface and state.
- `Tests/RouterCoreTests`: 561 tests, including write flows against simulated routers. Set `ROUTERBAR_HELPER` to a built `RouterBar` executable to also run the real child-process limit tests.
- `script/`: build, test and resource generation scripts.

## Third-party content

- `PolicyTexts.json`, `TimeZones.json` and `SettingsCatalog.json` in `Sources/RouterCore/Resources/` are generated from Asuswrt-Merlin 3006.102.5 web files (`CN.dict`, `Advanced_System_Content.asp`, `ajax/tz_db.json` and others) and the router's web pages. They contain form structure and interface text only, never a router's current settings. The policy and interface texts are copyright ASUSTeK Computer Inc. and are included so the app can show the same text as the router's web interface. The generators are in `script/`.
- `HTMLEntities.json` is the named character reference table from the WHATWG HTML standard.
- The app icon was generated with AI; the prompt is in `Assets/ICON-PROMPT.md`.

ASUS, Asuswrt, AiMesh, AiProtection and AiCloud are trademarks of ASUSTeK Computer Inc. This project is not affiliated with or endorsed by ASUS.

## License

[GPL-2.0-only](LICENSE). Some validation logic is ported from the Asuswrt-Merlin web scripts, whose source is released under GPL v2, so this project uses GPL v2 as well.
