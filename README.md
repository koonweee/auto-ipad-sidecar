# AutoSidecar

Plug in your iPad to use it as a Mac display. AutoSidecar starts Sidecar on USB
connection and runs automatically after login.

- **At your desk:** add the iPad as an extra screen alongside any other monitor.
- **Without a monitor:** use the iPad as your Mac's desktop, including on a Mac mini.
- **Between setups:** automatically switch between extended and iPad-only use.

## Install

You'll need [Sidecar-compatible devices](https://support.apple.com/en-us/102597),
a USB data cable, and Apple's Command Line Tools (`xcode-select --install`).

In Terminal:

```sh
git clone https://github.com/koonweee/auto-ipad-sidecar.git
cd auto-ipad-sidecar
./auto-sidecar install
```

The installer builds the utility, asks you to select your iPad, and tests the
connection. Confirm the desktop appears on the correct iPad to finish. A physical
monitor makes initial setup easier.

That's it: AutoSidecar starts after each login and connects your enrolled iPad
when you plug it in. `setup` can enroll separately; `install` enables the automation.

## Preferences

```sh
./auto-sidecar configure
```

- **With other displays:** extend (default), mirror, or preserve the existing layout.
- **iPad-only desktop:** adjust resolution and display settings.
- **Dock profiles:** optionally set size and magnification for each setup.
  Dock settings are untouched by default and restored after an active session ends.

Changes apply without restarting; resolution changes wait until the next connection.

### Choosing a resolution

- Lower desktop resolution makes text larger; higher resolution fits more content.
- Keep the aspect ratio of a working native Sidecar resolution to avoid black bars.
  Use its usable display area, which can change with Sidecar's sidebar or Touch Bar.
- Prefer HiDPI for text clarity. More rendered pixels cost more graphics work and
  do not always look sharper after scaling to the iPad.
- Logical dimensions describe workspace size; 1280 × 840 at 2× HiDPI renders
  2560 × 1680 pixels. Enter backing pixels (2560 × 1680 in this example) in
  `configure`; HiDPI requires even dimensions.

## Useful commands

```sh
./auto-sidecar status
./auto-sidecar doctor
./auto-sidecar connect
./auto-sidecar disconnect
./auto-sidecar install           # Update, keeping preferences
./auto-sidecar uninstall         # Remove; keep pairing and logs
./auto-sidecar uninstall --purge # Remove pairing and logs too
```

Outside the project directory, use the installed command:

```sh
"$HOME/Library/Application Support/AutoSidecar/auto-sidecar" configure
```

## Things to know

- Starts **after login**, not at FileVault unlock or the login screen.
- Unplugging USB may leave Sidecar connected over Wi-Fi.
- If connection retries fail, unlock the iPad and reconnect the cable.
- Stopping or uninstalling can end an iPad-only session.
- Uses private macOS APIs; OS updates may break compatibility. Tested on macOS
  27.0.1 / Apple M4. HiDPI output and refresh rates above 60 Hz need further validation.

- **Logs:** `~/Library/Logs/AutoSidecar/events.log`
- **Configuration:** `~/Library/Application Support/AutoSidecar/config.plist`

## Technical notes

- Native, event-driven utility and per-user LaunchAgent; no idle polling.
- USB enrollment identifies one iPad.
- A temporary virtual display supports iPad-only use; macOS handles rendering
  and streaming.
- Optional Dock profiles use System Events and may require Automation permission.
- Use `config show`, `config validate`, and `reload` for manual preference edits.
- Run `./test.sh` for automated tests; hardware behavior requires device testing.

## Dependencies and credits

Uses Apple's system frameworks, SidecarCore, command-line tools and Clang.
No third-party package or helper executable is bundled.

- [SidecarLauncher](https://github.com/Ocasio-J/SidecarLauncher), Jovany Ocasio,
  © 2023 ([MIT](https://github.com/Ocasio-J/SidecarLauncher/blob/main/LICENSE)):
  SidecarCore API reference.
- [Fuzzy-Team/virtual-monitor-helper](https://github.com/Fuzzy-Team/virtual-monitor-helper):
  virtual-display API declaration reference.
