# Claude Desktop flatpak: upgrade script

`./upgrade.sh` turns the manual process (download .deb, edit manifest, bump
metainfo, build, bundle, install) into one command.

```sh
./upgrade.sh            # upgrade to latest if newer than installed
./upgrade.sh --check    # just compare installed vs latest
./upgrade.sh -f         # rebuild even if up to date
./upgrade.sh -v 5.11492.5 -n   # specific version, build only, don't install
./upgrade.sh -C         # also delete older claude-desktop_* folders
```

It reads the newest amd64 package from Anthropic's apt repo
(`https://downloads.claude.ai/claude-desktop/apt/stable`), verifies the .deb
SHA256 from the repo index, generates `claude-desktop_<ver>_amd64/` from
`template/`, builds with flatpak-builder and installs `com.anthropic.Claude`
for the user. Needs `curl`, `flatpak`, `flatpak-builder` (via
`flatpak-spawn --host` when run inside a sandbox).

Edit `template/` (launcher, manifest, metainfo; `@DEB@`, `@VERSION@`, `@DATE@`
are filled in) to change permissions or packaging for all future versions.
Per-version folders (`claude-desktop_<ver>_amd64/`) are build output and are not
tracked in git.

## Unofficial / not redistributable

This is unofficial packaging, not affiliated with Anthropic. Claude Desktop is
proprietary software; this repo contains only the build recipe and **does not
include the application**. The script downloads the `.deb` straight from
Anthropic's own apt repo and builds a flatpak locally for you. Anthropic's terms
don't grant permission to redistribute the app, so please don't publish the
resulting `.deb` or `.flatpak` bundles.

## Known limitations

Flatpak sandbox limits apply (no host process spawning for local MCP servers or
Claude Code sessions, no VM-backed sandbox, auto-update disabled; re-run
`./upgrade.sh` to update).
