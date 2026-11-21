#!/bin/bash
# Launcher for Claude Desktop inside the flatpak sandbox.
#
# zypak-wrapper (from org.electronjs.Electron2.BaseApp) intercepts Chromium's
# sandbox syscalls and redirects them through flatpak's bubblewrap sandbox, so
# we do NOT pass --no-sandbox and we do NOT need the setuid chrome-sandbox.
#
# --ozone-platform-hint=auto: use native Wayland when available, else X11.
exec zypak-wrapper /app/lib/claude-desktop/claude-desktop \
  --ozone-platform-hint=auto \
  "$@"
