# tiepick

A keyboard-driven, Far Manager–style file picker for Linux, written in
Free Pascal / Lazarus. It plugs into `xdg-desktop-portal` as a **FileChooser
backend**, so the "Open file" / "Save as" dialogs of apps that use the desktop
portal (browsers, Electron and Flatpak apps, …) show a single blue file panel
instead of the toolkit's default dialog.

```
┌ Save as ───────────── /home/user/Documents ──────────────────────┐
│               Name                │   Size    │    Modified      │
│ ..                                │ <UP--DIR> │                  │
│ Archived                          │   <DIR>   │ 2026-10-31 06:55 │
│ notes.md                          │  3.2 KiB  │ 2026-10-22 04:55 │
│ report.pdf                        │  1.1 MiB  │ 2026-09-26 15:41 │
└───────────────────────────────────┴───────────┴──────────────────┘
 notes.txt
 F2 Places  F7 MkDir  F10 Save  Tab Filter  ^H Hidden  Esc Cancel
```

It is a picker only: one pane, no copy/move/delete. It is not a general file
manager.

## Status

Tested on Arch Linux, LXQt on X11, with Vivaldi (Open and Save as). Other
apps that use the portal should work but have not been tried. See
[Limitations](#limitations).

## Keys

| Key | Action |
| --- | --- |
| Up / Down / PgUp / PgDn | Move the highlight |
| Home or Left / End | First / last entry (when the edit line is empty) |
| Enter | Open the highlighted folder; accept a highlighted file |
| Backspace | Parent folder (when the edit line is empty) |
| *typing* | Goes to the edit line at the bottom (like Far's command line) |
| Enter (with text) | Open a typed path, or accept a typed file / save name |
| Insert, Space | Mark / unmark and move down (multi-select dialogs only) |
| Ctrl+A | Mark all (multi-select dialogs only) |
| Tab | Cycle the file-type filter |
| F2 | Places: home, `/`, mounted drives, GTK bookmarks |
| F7 | Make a new folder |
| F10 | Accept (Open, Save, or "Save here" for folder dialogs) |
| Ctrl+H | Show / hide hidden files |
| Esc | Clear the edit line, then cancel |

In **Save** dialogs the edit line starts with the suggested filename. If you
move the highlight onto a folder, Enter opens it and the name is kept; if you
don't touch the highlight (or you type in the edit line), Enter saves. F10
always saves with the current name in the current folder.

In **open-file** dialogs, typing jumps to the first entry starting with the
typed text.

## Requirements

- Free Pascal and Lazarus with the **Qt5** widgetset (`lazbuild`, `qt5pas`)
- `libdbus-1`
- `xdg-desktop-portal`
- The *JetBrains Mono* font is requested. If it is missing Qt falls back to
  another font, but the columns look best in a monospace face.

On Arch: `pacman -S lazarus-qt5 qt5pas dbus xdg-desktop-portal`
(verify the names with `pacman -Ss`).

## Build

```sh
lazbuild --ws=qt5 tiepick.lpi
```

## Install

Everything lives in your home directory; no root is needed.

```sh
install -Dm755 tiepick ~/.local/bin/tiepick
mkdir -p ~/.local/share/dbus-1/services ~/.local/share/xdg-desktop-portal/portals
```

Create `~/.local/share/dbus-1/services/org.freedesktop.impl.portal.desktop.tiepick.service`
(use your real home directory in `Exec`):

```ini
[D-BUS Service]
Name=org.freedesktop.impl.portal.desktop.tiepick
Exec=/home/YOU/.local/bin/tiepick
```

Create `~/.local/share/xdg-desktop-portal/portals/tiepick.portal`:

```ini
[portal]
DBusName=org.freedesktop.impl.portal.desktop.tiepick
Interfaces=org.freedesktop.impl.portal.FileChooser
UseIn=LXQt;KDE;niri
```

`UseIn` must contain your `$XDG_CURRENT_DESKTOP`; add it if it isn't listed.

Then tell the portal to prefer it, in
`~/.config/xdg-desktop-portal/<desktop>-portals.conf` (for example
`lxqt-portals.conf`, with the desktop name in lower case):

```ini
[preferred]
org.freedesktop.impl.portal.FileChooser=tiepick;gtk;*
```

Keep another backend (`gtk`, `kde`, …) after `tiepick` so file dialogs still
work if the picker fails to start. Restart the portal:

```sh
systemctl --user restart xdg-desktop-portal
```

D-Bus starts `tiepick` on demand and it exits after 10 idle minutes. To
redeploy after a rebuild: `pkill -x tiepick; install -m755 tiepick ~/.local/bin/`.

Whether an app uses the portal at all depends on the app and its toolkit (GTK
apps need `GTK_USE_PORTAL=1`, for example). Check that before blaming tiepick.

## Debian package

`packaging/build-deb.sh [release]` builds a `.deb` inside a `debian:<release>`
container (default `trixie`; needs docker), so the binary links against that
release's libraries. The result lands in `packaging/out/`.

```sh
packaging/build-deb.sh trixie
sudo apt install ./packaging/out/tiepick_0.1.1_amd64.deb
tiepick-enable          # once, as your normal user
```

The package installs the binary, the D-Bus service file and the portal file
system-wide. It deliberately does not touch your home directory: `tiepick-enable`
adds `tiepick` to the front of your `FileChooser` preference in
`~/.config/xdg-desktop-portal/<desktop>-portals.conf` (creating it if needed,
and keeping a backup), then restarts the portal. `tiepick-enable --undo`
restores the previous config. Log out and back in if an app was already open.

Only `amd64` is built. The build script has been run for `trixie` only.

## Testing without an app

Call the backend directly (`OpenFile`, `SaveFile` and `SaveFiles` are
implemented):

```sh
gdbus call --session --timeout 300 \
  --dest org.freedesktop.impl.portal.desktop.tiepick \
  --object-path /org/freedesktop/portal/desktop \
  --method org.freedesktop.impl.portal.FileChooser.SaveFile \
  /req/1 test.app '' 'Test' "{'current_name': <'x.txt'>}"
```

Set `TIEPICK_DEBUG=1` to log each parsed request to stderr.

`gdbus` sent garbage bytes for `b'/path'` byte-string literals in testing. For
`current_folder`, pass an explicit array instead:
`<@ay [byte 0x2f, byte 0x74, …, byte 0x00]>`.

## Limitations

- It does not remember the last folder; the calling app chooses the start.
- Filters match glob patterns only. MIME-type-only filters are ignored, and an
  "All files" entry is always added.
- The dialog is not attached to the calling app's window (`parent_window` is
  ignored).
- `SaveFiles` (save several files into one folder) is implemented but untested.
- Single pane only; no previews or thumbnails.
- It has only been run on X11.

## Layout

| File | Purpose |
| --- | --- |
| `tpdbus.pas` | D-Bus service: parses requests, sends portal replies |
| `tppicker.pas` | The Far-style panel and key handling |
| `tpmain.pas` | Hidden main form: polls the bus, runs a picker per request |
| `tiepick.lpr`, `tiepick.lpi` | Lazarus program and project |

## License

MIT, see [LICENSE](LICENSE).
