# PWebDAV

PWebDAV is a macOS menu bar WebDAV server built with Swift, SwiftUI, and SwiftNIO. It exposes multiple local folders as virtual WebDAV directories with account-based permissions.

## Features

- Menu bar only app with no Dock icon
- Start, stop, and restart the WebDAV service from the menu bar or settings window
- Configurable HTTP/HTTPS port, default `5005`
- Optional HTTPS/TLS using PEM certificate and private key files
- Configurable upload size limit, enabled by default at 100 MB
- Multiple shared folders mapped as virtual root directories
- Basic Auth accounts
- Per-account, per-directory permissions: no access, read only, or read/write
- Per-share hidden file protection for dot-prefixed files and directories such as `.git`, `.env`, and `.DS_Store`
- Optional auto-start of the WebDAV service when the app launches
- English and Simplified Chinese interface language support
- Built-in request and service logs
- Browser-friendly HTTP directory listing
- WebDAV support for `OPTIONS`, `PROPFIND`, `GET`, `HEAD`, `PUT`, `DELETE`, `MKCOL`, `MOVE`, `COPY`, `LOCK`, and `UNLOCK`

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
git tag v0.2.0
git push origin v0.2.0
```

The release workflow can also be started manually from the Actions tab with a release tag.

## Connect From Finder

Start the WebDAV service, then in Finder choose:

```text
Go -> Connect to Server...
http://localhost:5005
```

The default bind address is local-only. If the bind address is changed to `0.0.0.0`, other devices on the same network can connect using your Mac's LAN IP:

```text
http://<your-mac-ip>:5005
```

## Authentication

PWebDAV requires at least one enabled account before it exposes content. If no account is enabled, HTTP/WebDAV requests are rejected.

New accounts are created disabled and without a password. Set a password before enabling the account.

PWebDAV uses Basic Auth. Plain HTTP sends credentials and file contents without encryption. Enable HTTPS/TLS with a PEM certificate and private key before exposing the service to a network you do not fully trust.

## Current Limitations

- WebDAV locks are stored in memory and are cleared when the service restarts.
- Upload requests are limited by the configured MB setting when upload limiting is enabled.
- Plain HTTP downloads use SwiftNIO `FileRegion`; HTTPS downloads use chunked NIO reads because `FileRegion` cannot pass through TLS.
- Passwords are currently stored as salted SHA-256 digests in the settings file. Keychain storage is recommended for a production release.
- The app bundle build works, but Developer ID signing and notarization still need to be added for distribution.

## License

PWebDAV is released under the BSD 3-Clause License. See [LICENSE](LICENSE).

## Suggested Next Steps

1. Add Developer ID signing and notarization.
2. Move password storage to Keychain.
3. Move TLS certificate and password material to Keychain.
4. Add Range request support for large downloads.
5. Add a clear LAN IP display.
