#!/usr/bin/env bash
# Installs NetMeter for the current user (no root): copies the app to ~/.local/opt/netmeter, adds a launcher to the
# applications menu and, if you answer y, starts it with your desktop session.
#
# Run it from the unpacked folder:       ./install.sh
# Or download and install in one step:   curl -fsSL https://raw.githubusercontent.com/RamtinGhiami/NetMeter/main/scripts/install-linux.sh | bash
set -euo pipefail

REPO="RamtinGhiami/NetMeter"
DEST="${HOME}/.local/opt/netmeter"
APPS="${HOME}/.local/share/applications"
AUTOSTART="${HOME}/.config/autostart"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SRC=""
if [ -x "$HERE/netmeter" ]; then
  SRC="$HERE"
else
  echo "Downloading the latest NetMeter for Linux..."
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  URL="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep -o 'https://[^"]*linux-x64\.tar\.gz' | head -1)"
  [ -n "$URL" ] || { echo "No Linux build found in the latest release."; exit 1; }
  curl -fSL "$URL" -o "$TMP/netmeter.tar.gz"
  tar -xzf "$TMP/netmeter.tar.gz" -C "$TMP"
  SRC="$TMP/netmeter"
fi

mkdir -p "$DEST" "$APPS"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -r "$SRC"/. "$DEST"/
chmod +x "$DEST/netmeter"

ICON="$DEST/data/flutter_assets/assets/icon.png"
cat > "$APPS/netmeter.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=NetMeter
Comment=Home network usage monitor
Exec=$DEST/netmeter
Icon=$ICON
Terminal=false
Categories=Network;Monitor;
EOF

read -r -p "Start NetMeter with your desktop session? [y/N] " ans < /dev/tty || ans="n"
if [ "${ans:-n}" = "y" ] || [ "${ans:-n}" = "Y" ]; then
  mkdir -p "$AUTOSTART"
  sed "s|Exec=$DEST/netmeter|Exec=$DEST/netmeter --minimized|" "$APPS/netmeter.desktop" > "$AUTOSTART/netmeter.desktop"
  echo "Autostart enabled."
fi

echo "Installed to $DEST. Start it from the applications menu (NetMeter)."
echo "To remove it: rm -rf '$DEST' '$APPS/netmeter.desktop' '$AUTOSTART/netmeter.desktop'"
