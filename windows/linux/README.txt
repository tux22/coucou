Coucou for Linux
================

Mochi lives at the top of your screen: approve Claude Code permissions, watch
your session work, drop a file, chat with Claude, keep an eye on your services.

Install for your user (no root needed):

    ./install.sh

Or run it in place:

    ./coucou

Remove it with `./install.sh --uninstall`.

Needs: WebKitGTK 4.1, GTK 3, libayatana-appindicator3 (tray icon), a Secret
Service keyring (GNOME Keyring, KWallet or KeePassXC) for API keys, and the
GStreamer "good" plugins for Mochi's sounds. On Debian/Ubuntu:

    sudo apt install libwebkit2gtk-4.1-0 libayatana-appindicator3-1 \
      gstreamer1.0-plugins-good gnome-keyring

More: https://github.com/Louis-CFM/coucou/tree/main/windows#linux
