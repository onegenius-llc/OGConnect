# OGConnect

View and control a single Mac window from an iPad, over your local network.

OGConnect is two apps:

- **OGConnect** — the iPad app. Pick a Mac, pick a window, and use it.
- **OGConnect Server** — a menu bar app for the Mac that shares its windows and applies your input.

Unlike full-screen remote desktop, OGConnect streams one window at a time, so the window fills the iPad instead of a shrunken copy of your whole desktop.

> [!WARNING]
> **This is alpha software.** It is provided with **no warranty of any kind**, it has not had a security review, and it is intended **only for use on a local network you trust**. Do not expose it to the internet. See [Security](#security) before you run it.

## What it does

- Lists the Mac's open windows with live thumbnails, and streams the one you choose as H.264 video.
- Mouse and keyboard control, by touch, on-screen keyboard, or a hardware keyboard, mouse or trackpad attached to the iPad.
- A drop-down of the Mac app's full menu bar, so menus are reachable without the Mac's menu bar on screen.
- Launches any app installed on the Mac.
- Opens the Mac's menu bar items (the icons at the top right of the screen).
- Unlocks a locked Mac by typing your Mac password for you.
- Keeps the Mac awake while a device is connected.
- Saved connections, with the connection password stored in the iPad's keychain.

### Touch controls

| On the iPad | On the Mac |
|---|---|
| Tap / double-tap | Click / double-click |
| Two-finger tap | Right-click |
| One-finger drag | Move the pointer |
| Long-press, then drag | Click and drag |
| Two-finger drag | Scroll |

The keyboard button shows the on-screen keyboard with an extra row for esc, tab, the modifier keys and the arrows. A modifier stays on for the next key or click.

## Requirements

- A Mac running macOS 14 or later, and an iPad running iPadOS 17 or later.
- Xcode, and an Apple developer account (a free one works) to sign the apps.
- Both devices on the same local network.

It has been built with Xcode 26 and used on macOS 26 and iPadOS 26. Earlier versions within the requirements above are untested.

## Building

There are no prebuilt downloads; you build both apps yourself.

### First, set your own signing identity

The project is checked in with the author's Apple development team and bundle identifiers, so it will not sign on your machine until you change them:

| Setting | Checked-in value | Change it to |
|---|---|---|
| Development team | `34WADR9GR4` | Your own team ID |
| iPad app bundle identifier | `com.onegenius.ogconnect` | An identifier you own, e.g. `com.example.ogconnect` |
| Mac server bundle identifier | `com.onegenius.ogconnect.server` | e.g. `com.example.ogconnect.server` |

Do this in whichever of the two ways below you use to build.

### Option A: open the Xcode project

1. Open `OGConnect.xcodeproj` in Xcode.
2. Select the project in the navigator. For each of the two targets, **OGConnect** and **OGConnectServer**, open **Signing & Capabilities**, choose your **Team**, and change the **Bundle Identifier**.
3. Choose the **OGConnectServer** scheme with **My Mac** as the destination and run it.
4. Choose the **OGConnect** scheme with your iPad as the destination and run it.

### Option B: generate the project with XcodeGen

The Xcode project is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen). Use this route if you plan to add files or change build settings, because regenerating replaces any edits made in Xcode.

1. Install XcodeGen:

   ```bash
   brew install xcodegen
   ```

2. Edit `project.yml`: set `DEVELOPMENT_TEAM` to your team ID, and change `bundleIdPrefix` and both `PRODUCT_BUNDLE_IDENTIFIER` values.
3. Generate the project:

   ```bash
   xcodegen generate
   ```

4. Open `OGConnect.xcodeproj` and run the two schemes as in Option A, steps 3 and 4.

### Installing the server in Applications

Running from Xcode is fine for trying it out. To install the server as a normal app:

```bash
xcodebuild -project OGConnect.xcodeproj -scheme OGConnectServer -configuration Release -derivedDataPath build build
```

```bash
ditto build/Build/Products/Release/OGConnectServer.app /Applications/OGConnectServer.app
```

## Setting up

### On the Mac

1. Open **OGConnect Server**. It has no Dock icon; look for its icon in the menu bar.
2. Grant the two permissions it asks for, in **System Settings › Privacy & Security**:
   - **Screen Recording**, to see and stream windows. Quit and reopen the server after granting this one.
   - **Accessibility**, to click, type, read menus and unlock the Mac. Without it the iPad can watch but not control.
3. Click the menu bar icon. The panel shows this Mac's address, the port (5959 by default) and the connection password, which is generated randomly on first launch. You can change the password and port there.

The **Keep Mac awake** setting in the same panel controls when the server stops the display sleeping. macOS locks the screen when the display sleeps, and a locked Mac has no windows to share.

### On the iPad

1. Open **OGConnect** and add a connection with the Mac's address and port.
2. Tap the connection and enter the password from the server's panel.
3. Allow local network access when iPadOS asks.
4. Tap a window to open it.

## Security

Read this before running the server.

- **Local network only.** The server listens on a TCP port on every network interface. Do not forward that port through your router or otherwise expose it to the internet.
- **The password is the only protection.** Anyone on your network who has it gets full control of your Mac's mouse and keyboard and can see any window. Choose a strong one.
- **The connection is encrypted** with TLS using a key derived from that password. This design has not been independently reviewed, and a weak password can be guessed offline by someone who captures a connection attempt.
- **The unlock feature sends your Mac account password** from the iPad to the server over that connection, and the server types it into the lock screen. It is not stored on either device.
- **The server is not sandboxed** and holds Screen Recording and Accessibility permission, which together are enough to see and do anything you can.
- **No warranty.** This is alpha software. You run it at your own risk.

## Known limitations

- Windows that are minimised, or on a desktop Space that isn't showing, are not listed.
- A menu or popover that extends past the edge of its window is cut off in the window view. Use the menu drop-down for the app's main menus.
- Menu bar items are shown in a fixed 880 × 660 point area at the top of the screen; a taller or wider drop-down is cut off.
- Only the main display's menu bar items are listed, and macOS does not always provide a name for them.
- The app list covers `/Applications`, `/System/Applications` and `~/Applications`, one folder deep.
- Some keyboard shortcuts are taken by iPadOS before the app sees them, such as ⌘Tab, ⌘Space and ⌘H.
- The server does not start at login.

## Project layout

| Path | Contents |
|---|---|
| `OGConnect/` | The iPad app |
| `OGConnectServer/` | The Mac server |
| `Shared/` | The wire protocol and connection code used by both |
| `Tools/make-icons.swift` | Draws both app icons; run with `swift Tools/make-icons.swift` |
| `project.yml` | The XcodeGen project definition |

## License

Copyright (C) 2026 Ronald Miller

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

The full license text is in [LICENSE](LICENSE).
