# PWebDAV

PWebDAV is a macOS menu bar WebDAV server built with Swift, SwiftUI, and SwiftNIO. It exposes multiple local folders as virtual WebDAV directories with account-based permissions.

## Features

- Menu bar only app with no Dock icon
- Start, stop, and restart the WebDAV service from the menu bar or settings window
- Configurable HTTP port, default `5005`
- Multiple shared folders mapped as virtual root directories
- Basic Auth accounts
- Per-account, per-directory permissions: no access, read only, or read/write
- Optional auto-start of the WebDAV service when the app launches
- English and Simplified Chinese interface language support
- Built-in request and service logs
- Browser-friendly HTTP directory listing
- WebDAV support for `OPTIONS`, `PROPFIND`, `GET`, `HEAD`, `PUT`, `DELETE`, `MKCOL`, `MOVE`, and `COPY`

## Development

Run the development build:

```bash
swift run PWebDAV
```

The app appears in the macOS menu bar. Open Settings from the menu bar icon, add at least one account and one shared directory, then start the service.

## Build The App Bundle

```bash
chmod +x Scripts/build-app.sh
Scripts/build-app.sh
open build/PWebDAV.app
```

The generated `.app` uses `Sources/PWebDAV/Resources/AppIcon.icns` as its app icon and sets `LSUIElement` so the app stays in the menu bar without showing a Dock icon.

## Release Builds

GitHub Actions builds release artifacts for both Apple Silicon and Intel Macs:

- `PWebDAV-arm64.zip`
- `PWebDAV-x86_64.zip`

Push a version tag to publish a GitHub Release:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The release workflow can also be started manually from the Actions tab with a release tag.

## Connect From Finder

Start the WebDAV service, then in Finder choose:

```text
Go -> Connect to Server...
http://localhost:5005
```

If the bind address is `0.0.0.0`, other devices on the same network can connect using your Mac's LAN IP:

```text
http://<your-mac-ip>:5005
```

## Authentication

PWebDAV requires at least one enabled account before it exposes content. If no account is enabled, HTTP/WebDAV requests are rejected.

New accounts are created with the default password:

```text
password
```

Change the password from the Accounts tab before using the service on a network you do not fully trust.

## Current Limitations

- Full WebDAV `LOCK` / `UNLOCK` support is not implemented yet.
- File upload and download currently use in-memory buffering; large-file streaming should be added before heavy production use.
- Passwords are currently stored as salted SHA-256 digests in the settings file. Keychain storage is recommended for a production release.
- The app bundle build works, but Developer ID signing and notarization still need to be added for distribution.

## License

PWebDAV is released under the BSD 3-Clause License. See [LICENSE](LICENSE).

## Suggested Next Steps

1. Add Developer ID signing and notarization.
2. Move password storage to Keychain.
3. Replace in-memory file transfers with SwiftNIO streaming.
4. Add minimal compatible `LOCK` / `UNLOCK` support.
5. Add HTTPS support and a clear LAN IP display.
