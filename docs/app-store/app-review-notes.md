# App Review Notes — Mimi Remote 1.2.1

Mimi Remote is a native developer-tool client for a computer owned by, or explicitly authorized for use by, the user.

Version 1.2.1 updates the Simplified Chinese App Store name to Mimi Remote and replaces the Simplified Chinese screenshots. This metadata update does not add feature code; the selected build is built from the current main branch.

The iOS app does not execute downloaded code, provide arbitrary shell access, provide AI models or subscriptions, operate a VPN, relay traffic, or host project data. Code execution occurs only on the configured host. The developer does not operate a service that receives prompts, source code, credentials, or model-provider traffic.

The GitHub link on the Connection screen points to this project's public Release page and a free, signed and notarized macOS companion app. The iOS app only opens or shares the URL. It does not download, install, or execute the macOS binary on iOS, and no purchase or subscription is offered. App Review can use the manual Endpoint below without installing the macOS companion app.

## Resolution of the previous China mainland issue

- Public App Store metadata uses neutral feature descriptions. Current screenshots show recognizable Runtime names and icons only where they appear in the real App UI, so users can identify the compatible host-side CLI they selected.
- Mimi Remote is an independent third-party client and does not claim affiliation with or endorsement by OpenAI, Anthropic, or other Runtime providers.
- The iOS app has no ChatGPT/OpenAI sign-in, API-key field, model subscription, hosted model endpoint, or purchase flow.
- Voice input defaults to Codex transcription, which sends a recording directly to the user's configured host and uses their own host-side Codex session. Users may instead select live on-device transcription; the Mimi Remote developer never receives recordings in either mode.
- Compatible command-line developer runtimes are installed, configured, and authenticated by the user on the host computer. Mimi Remote does not provide or resell access to those tools.

## Review credentials

Use the isolated review environment below. These credentials are created only for App Review and can access only a disposable sample repository.

- Endpoint: `<REVIEW_HTTPS_ENDPOINT>`
- Access token: `<REVIEW_ACCESS_TOKEN>`
- Environment availability: `<START_DATE_UTC>` through `<END_DATE_UTC>`

Please use manual connection because normal QR tickets expire after 10 minutes and are not suitable for a long-lived review environment. A QR ticket can be reused only during that window.

## Review steps

1. Launch Mimi Remote.
2. Choose manual connection on the Connection screen.
3. Enter the Endpoint and Access token above, then connect.
4. Open the `Mimi Review Sample` workspace.
5. Open the prepared session, or create a new coding session.
6. Send a prompt such as `Summarize this sample project without changing files.`
7. Open the Changes or Inspector area to review the sample Git status and diff.
8. Optional: request a small README edit and review the approval UI before accepting or declining it.
9. Open Settings → Legal & Support to view the Privacy Policy, Terms of Use, and Support pages.
10. Open Settings → Language to switch between English and Simplified Chinese without restarting the app.

## Network and security model

- The review Endpoint uses HTTPS. Mimi Remote also supports private local/Tailscale HTTP addresses, but blocks public cleartext HTTP in the app.
- The access token is stored in the iOS Keychain.
- The host gateway restricts projects to configured roots and exposes an allowlisted protocol surface. It does not expose a general-purpose remote shell.
- The developer does not collect analytics, project content, prompts, credentials, or usage telemetry.

## Permissions

- Camera: scanning a pairing QR code, or taking a photo the user explicitly chooses to attach to a message. Captured photos are not saved to the photo library.
- Microphone and speech recognition: optional user-initiated dictation.
- Local network: connecting to a user-configured host.

Manual endpoint entry and keyboard input remain available if camera, microphone, or speech permissions are declined.

Review contact:

- Name: `<REVIEW_CONTACT_NAME>`
- Email: `gaixg94@gmail.com`
- Phone: `<REVIEW_CONTACT_PHONE>`
