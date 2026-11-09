#!/bin/bash
# Runs inside the Debian build container (see build-deb.sh).
set -euo pipefail

owner=$1
version=0.1.1

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  fpc fp-units-misc fp-units-fcl lcl-qt5 lcl-units lcl-nogui \
  libqt5pas-dev libdbus-1-dev dpkg-dev binutils ca-certificates >/dev/null

# build from a private copy so the read-only source mount stays clean
build=/build
rm -rf "$build"
mkdir -p "$build"
cp -a /src/tiepick.lpr /src/tiepick.lpi /src/tp*.pas "$build"/
cd "$build"
# Debian's lazbuild wants the IDE sources, so call fpc directly with the
# prebuilt LCL (Qt5) units instead.
lcl=$(ls -d /usr/lib/lazarus/[0-9]* | head -1)
mkdir -p units
fpc -O2 -dLCL -dLCLqt5 \
  -Fu"$lcl/lcl/units/x86_64-linux/qt5" \
  -Fu"$lcl/lcl/units/x86_64-linux" \
  -Fu"$lcl/components/lazutils/lib/x86_64-linux" \
  -FUunits -otiepick tiepick.lpr >build.log 2>&1 || { tail -40 build.log; exit 1; }
strip --strip-unneeded tiepick

# runtime library dependencies, as Debian package names
echo "--- linked libraries:"
ldd tiepick | awk '/=>/ {print "  " $1}'

pkg=/pkg/tiepick_${version}_amd64
rm -rf "$pkg"
install -Dm755 tiepick "$pkg/usr/bin/tiepick"
install -Dm755 /src/packaging/tiepick-enable "$pkg/usr/bin/tiepick-enable"

install -Dm644 /dev/stdin \
  "$pkg/usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.tiepick.service" <<'EOF'
[D-BUS Service]
Name=org.freedesktop.impl.portal.desktop.tiepick
Exec=/usr/bin/tiepick
EOF

install -Dm644 /dev/stdin "$pkg/usr/share/xdg-desktop-portal/portals/tiepick.portal" <<'EOF'
[portal]
DBusName=org.freedesktop.impl.portal.desktop.tiepick
Interfaces=org.freedesktop.impl.portal.FileChooser
UseIn=LXQt;KDE;XFCE;GNOME;MATE;X-Cinnamon;Budgie;Deepin;LXDE;niri;sway;i3
EOF

install -Dm644 /src/README.md "$pkg/usr/share/doc/tiepick/README.md"
install -Dm644 /dev/stdin "$pkg/usr/share/doc/tiepick/copyright" <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: tiepick
Source: https://github.com/zead73/tiepick

Files: *
Copyright: 2026 Zead
License: MIT
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 .
 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.
 .
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
EOF

size=$(du -sk "$pkg/usr" | cut -f1)
mkdir -p "$pkg/DEBIAN"
cat > "$pkg/DEBIAN/control" <<EOF
Package: tiepick
Version: $version
Section: utils
Priority: optional
Architecture: amd64
Installed-Size: $size
Depends: libqt5pas1, libdbus-1-3, xdg-desktop-portal
Recommends: fonts-jetbrains-mono
Maintainer: Zead <17590961+zead73@users.noreply.github.com>
Homepage: https://github.com/zead73/tiepick
Description: Far-style keyboard-driven file picker for xdg-desktop-portal
 A single-pane, Far Manager style Open/Save dialog that plugs into
 xdg-desktop-portal as a FileChooser backend, so apps that use the desktop
 portal (browsers, Electron and Flatpak apps) show it instead of the toolkit
 dialog. Run "tiepick-enable" once to make the portal prefer it.
EOF

dpkg-deb --root-owner-group --build "$pkg" /out/tiepick_${version}_amd64.deb >/dev/null
chown "$owner" /out/tiepick_${version}_amd64.deb
echo "built /out/tiepick_${version}_amd64.deb"
