#!/bin/sh
# Installs Coucou from the tarball for the current user only — no root, nothing
# outside your home directory.
#
#   ./install.sh              install (or update)
#   ./install.sh --uninstall  remove what install.sh put in place
#
# Your settings (~/.config/coucou), your keys (in the system keyring) and your
# Claude Code hooks are left alone either way: remove the hooks from Coucou's
# Settings window before uninstalling if you no longer want them.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
data=${XDG_DATA_HOME:-$HOME/.local/share}
lib="$HOME/.local/lib/coucou"
bin="$HOME/.local/bin"
apps="$data/applications"
icons="$data/icons/hicolor"

if [ "${1:-}" = "--uninstall" ]; then
  rm -rf "$lib"
  rm -f "$bin/coucou" "$apps/coucou.desktop"
  for size in 32x32 128x128 256x256 512x512; do
    rm -f "$icons/$size/apps/coucou.png"
  done
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$apps" || true
  echo "Coucou removed. Settings are still in ${XDG_CONFIG_HOME:-$HOME/.config}/coucou."
  exit 0
fi

mkdir -p "$lib" "$bin" "$apps"
install -m 755 "$here/coucou" "$lib/coucou"
install -m 755 "$here/coucou-hook" "$lib/coucou-hook"
ln -sf "$lib/coucou" "$bin/coucou"

for size in 32x32 128x128 256x256 512x512; do
  if [ -f "$here/icons/$size.png" ]; then
    mkdir -p "$icons/$size/apps"
    install -m 644 "$here/icons/$size.png" "$icons/$size/apps/coucou.png"
  fi
done

# The desktop entry points at the real binary, so it works even when
# ~/.local/bin is not on PATH.
sed "s|^Exec=.*|Exec=$lib/coucou|" "$here/coucou.desktop" > "$apps/coucou.desktop"
chmod 644 "$apps/coucou.desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$apps" || true

echo "Coucou installed in $lib."
echo "Start it from your applications menu, or run: $bin/coucou"
