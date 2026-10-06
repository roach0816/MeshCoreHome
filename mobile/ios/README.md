# MeshHome for iOS

A native client for a MeshHome server (SwiftUI, iOS 18+). It signs in with the owner's username and
password and talks only to that server, on the home network or over a VPN. See the API guide,
[docs/API.md](../../docs/API.md#9-apps-that-sign-in-as-the-owner).

## Build

```bash
brew install xcodegen
cd mobile/ios
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set your Apple team ID (not committed)
xcodegen generate                                         # creates MeshHome.xcodeproj (not committed)
open MeshHome.xcodeproj
```

## Test

Unit tests run anywhere. The UI test drives the app against a real server with the simulated radio
(see [docs/development.md](../../docs/development.md) for running one locally):

```bash
TEST_RUNNER_MESHHOME_TEST_SERVER=localhost:8080 TEST_RUNNER_MESHHOME_TEST_PASSWORD=<password> \
  xcodebuild -project MeshHome.xcodeproj -scheme MeshHome \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Status

Phase 2 (core messaging), tested in the iOS Simulator only:

- Connect: type the address, scan the pairing QR code (web UI → Account → Signed-in devices → Add a
  phone), or open a `meshhome://pair?url=…` link.
- Conversations: search, filters, swipe or long-press to mark read, favourite, mute, delete or clear.
- Threads: day headers, delivery states, earlier messages, sending, and a message menu (details with
  SNR, hops and paths heard, sender info, block sender, copy, delete).
- Contacts: search, filters, sorting with favourites first, favourite, block, tap to message.
- Live updates over the WebSocket, an in-app sound and haptic for new messages (following the
  server's notification settings), an optional unread count on the app icon, and the last-known data
  cached for reading offline.
- iPhone and iPad layouts, light and dark mode, Dynamic Type.
