# App Review Notes — Mimi Remote

Mimi Remote is a native developer-tool client for a computer owned by, or explicitly authorized for use by, the user.

This submission includes the optional Mimi Managed Connection auto-renewable subscription. The app and computer software remain free and open source. Local-network, Tailscale, and self-hosted Tailcat connections remain free.

The iOS app does not execute downloaded code, provide arbitrary shell access, provide AI models or model subscriptions, or host project data. Code execution occurs only on the configured host. Managed connection uses developer-operated subscription and device authorization services and, when direct connectivity is unavailable, a relay for end-to-end encrypted traffic. The developer cannot read prompts, source code, conversations, or file contents. The control service processes Apple-signed purchase evidence, device identifiers and public keys, dedicated managed authorization credentials, and coarse connection results. It does not receive host access tokens or private keys. Message notifications use a separate developer-operated push service that receives APNs routing data, anonymous tags, and fixed event types. See the Privacy Policy for retention and deletion details.

Self-hosted Tailcat is a separate optional experimental connection, off by default. It first contacts a DERP relay for discovery and the initial handshake, then uses direct connectivity when available; its default public relay is operated by Tailscale. Managed connection uses Tailcat with WireGuard end-to-end encryption and Mimi-operated DERP relays. Relays process IP addresses, public keys, connection times, and traffic volume. Official relays accept only registered and authorized nodes under a valid subscription. The manual endpoint review steps below do not require a subscription.

The GitHub link on the Connection screen points to this project's public Release page and a free, signed and notarized macOS companion app. The iOS app only opens or shares the URL. It does not download, install, or execute the macOS binary on iOS. Subscription purchases use Apple in-app purchase. App Review can use the manual Endpoint below without installing the macOS companion app; testing managed connection itself requires a computer running Mimi.

## Resolution of the previous China mainland issue

- Public App Store metadata uses neutral feature descriptions. Current screenshots show recognizable Runtime names and icons only where they appear in the real App UI, so users can identify the compatible host-side CLI they selected.
- Mimi Remote is an independent third-party client and does not claim affiliation with or endorsement by OpenAI, Anthropic, or other Runtime providers.
- The iOS app has no ChatGPT/OpenAI sign-in, API-key field, model subscription, or hosted model endpoint. Its in-app purchase pays only for Mimi Managed Connection, not model access or usage credits.
- On iOS 26 and later, voice input defaults to live on-device transcription. Existing saved selections are preserved. Users may select Codex transcription, which sends a recording directly to their configured host and uses their own host-side Codex session; older iOS versions use this mode. The Mimi Remote developer never receives recordings in either mode.
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
8. Optional: new sessions default to Full File Access, which does not ask for approval. To see the approval UI, choose Ask for Approval in the composer's permission menu or in Settings → Default permissions, then request a small README edit and accept or decline it.
9. Open Settings → Legal & Support to view the Privacy Policy, Terms of Use, and Support pages.
10. Open Settings → Language to switch between English and Simplified Chinese without restarting the app.

## Subscription and managed connection review

1. Use Apple's Sandbox purchase environment. Open Settings → Mimi Managed Connection. No Mimi account or developer-issued login is required; approve any Apple authentication prompt using the review Sandbox environment.
2. Check the monthly and annual plans, localized prices, billing periods, renewal disclosure, Terms of Use, and Privacy Policy links. Product identifiers: `com.gaixianggeng.mimi.managed.monthly` and `com.gaixianggeng.mimi.managed.annual`. Production prices are ¥9.9 / US$1.99 monthly and ¥68 / US$9.99 annually; other regions use Apple's converted prices. Both plans offer a 7-day trial once per Apple ID within the group. Family Sharing is off; there is no lifetime purchase.
3. Purchase either plan in Sandbox and confirm that the app shows the entitlement and expiry. Sandbox renewal and trial durations are accelerated and do not match production durations. The submitted app and subscription verification service must both support the review Sandbox environment.
4. Tap Restore Purchases on the same page using the same Apple ID. Confirm that the entitlement returns without another purchase. On a new phone or tablet, only entitlements restore; addresses, private keys, and host access tokens do not sync. Reconnect to each computer separately.
5. To test the managed data connection, use a Mac running the Mimi companion app with a sample workspace. Enable Mimi Managed Connection on the computer, display a fresh pairing QR code, and scan it through Connect Computer on the subscription page. Keep the computer awake and both devices online. The manual HTTPS Endpoint above alone does not test this feature.
6. Open the device list on the same subscription page. After pairing, confirm that the computer and mobile device appear, with limits of 3 computers and 5 phones or tablets. Remove a device, confirm its removal, and refresh the list to verify that its slot is released. Pair again to authorize it again. Removal revokes access; it does not erase registration history or delete sample files.
7. Open the system subscription management screen to test cancellation of renewal. Removing a device or uninstalling the app does not cancel the subscription. Expiry or revocation ends managed authorization and also makes current in-app device management unavailable; remove test devices before expiry. Free connection methods remain available.

Managed connection demonstration video: `<MANAGED_CONNECTION_REVIEW_VIDEO_URL>`

The video must show Sandbox purchase, Restore Purchases, computer setup and QR pairing, a connection across different networks, and device-list removal. Replace this placeholder with a reviewer-accessible video before submission. Do not put Sandbox credentials or real endpoints in this repository.

## Network and security model

- The review Endpoint uses HTTPS. Mimi Remote also supports private local/Tailscale HTTP addresses, but blocks public cleartext HTTP in the app.
- The access token is stored in the iOS Keychain.
- The host gateway restricts projects to configured roots and exposes an allowlisted protocol surface. It does not expose a general-purpose remote shell.
- The developer does not receive readable project content, prompts, host access tokens, or private keys. Managed connection collects subscription and device authorization records and coarse connection diagnostics. The relay only forwards end-to-end encrypted content. The Privacy Policy and App Privacy answers describe these services alongside push notifications.

## Permissions

- Camera: scanning a pairing QR code, or taking a photo the user explicitly chooses to attach to a message. Captured photos are not saved to the photo library.
- Microphone and speech recognition: optional user-initiated dictation.
- Local network: connecting to a user-configured host.

Manual endpoint entry and keyboard input remain available if camera, microphone, or speech permissions are declined.

Review contact:

- Name: `<REVIEW_CONTACT_NAME>`
- Email: `gaixg94@gmail.com`
- Phone: `<REVIEW_CONTACT_PHONE>`
