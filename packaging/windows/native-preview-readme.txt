Mimi Remote Windows native preview

This unsigned development preview does not install or replace your existing service.
Extract the complete archive before launching MimiRemote.exe. The .NET and Windows App
SDK runtimes are included. Keep all DLL files and the licenses folder together.

An existing, configured Mimi Remote computer service is required for live operations.
The service and this preview must support the same CLI/API features. An older service
may reject the new relay command; the app displays that error in the current page.
Use MimiRemote.exe --debug-seed-ui for a preview that does not change service settings.

Closing the client does not stop the computer service. A new tray icon is suppressed
while the previously installed Mimi Remote tray is still running.

This preview is not an installer or an automatic update. Keep your existing installation.
The complete first-install, upgrade and rollback flows are tracked separately.

Source: https://github.com/gaixianggeng/mimi-remote
See manifest.json for the exact source commit and SHA-256 hashes.
See LICENSE, NOTICE.md, THIRD_PARTY_NOTICES.md and licenses/ for applicable terms.
