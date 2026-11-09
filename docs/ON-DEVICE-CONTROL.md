# On-device control

The experimental **On-device control** route connects the app to a separately signed local UI automation runner based on [iCTRL](https://github.com/OpenMinis/iCTRL). While the runner is active, screenshots and input stay on the same iPhone through `127.0.0.1:8200`. Model requests use the phone's normal internet connection, including cellular data. Runtime operation does not require Wi-Fi, a VPN, ESP32 or an attached computer.

## Preparation and use

Install both the main app and the local runner with valid signing, enable Developer Mode, and prepare a matching Developer Disk Image through Xcode. The runner requires the image's test automation services. Select **Settings → Phone control → On-device control**. Device tasks automatically open the installed runner when needed; opening the app or returning to it does not start automation by itself. The Connect button remains available for manual verification. Approve the pairing request on the phone when requested. The screenshot and tap verification controls use this same route.

The main app stores its runner credential in the device-only Keychain. This pairing is separate from the CoreDevice system pairing used by VPN and ESP32 routes. Changing routes preserves the system pairing file but invalidates the current control session and its observation/action grants.

The runner runs during device tasks and stops after the final task releases control, including Muse tasks. A new task performs a fresh readiness check and launches it again when needed. A disconnected task cannot restart its interrupted automation session; begin a new task after an emergency volume-button stop. iOS displays its automation notice during the active session. Automatic launch needs an unlocked device and may require returning to the main app if iOS blocks background app opening. System passcode/automation prompts still require the user. Free provisioning still expires and requires renewal. A phone reboot removes the mounted developer image; preparing services again may require Xcode. This implementation does not establish a computer-free cold start after reboot.

## Implementation

`PhoneControlServices` adapts the authenticated iCTRL v1 protocol to the existing control coordinator and bridge. Screenshots, normalized tap and drag coordinates, text entry, Home, app enumeration and app launch share the app's operation ownership and authorization gates. App launch arguments are currently unsupported on this route and fail before a request is sent.

The Louis runner build is restricted to IPv4 loopback and disables nearby discovery. Pairing requires phone approval. A one-shot approval environment setting is available upstream for explicitly authorized setup; normal operation does not enable it. Credentials and screenshots are not written to diagnostic logs.

Runner extensions bind each observation to a runner session, display orientation and point bounds. A coordinate action with a changed display token is rejected before dispatch. Mutating RPC failures are reported as an unknown result and are never automatically replayed; obtain a new observation before deciding what to do next.

The runner is an external, separately installed component. Its source, license and notices must be retained when redistributing a modified build. The source snapshot used here is Apache-2.0 licensed and includes its own third-party notices. Use the repository’s [build and installation instructions](SETUP.md) and [source provenance](../local-control/UPSTREAM.md). The runner remains a separate app.

## Validation boundary

Physical acceptance must verify cellular connectivity and actual input separately from a successful localhost handshake. The opt-in debug fixture uses the production bridge to take a screenshot, tap an app-local counter, press Home, take a background screenshot and reopen the main app. A host USB timeline can establish that these actions occurred after disconnecting the computer. This controlled fixture does not establish long-running background reliability, reboot recovery or completion of arbitrary model tasks.
