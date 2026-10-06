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

Phase 2, first step: connect and sign in, conversations (search, filters, swipe to mark read or
favourite), threads (day headers, delivery states, earlier messages, sending) and live updates.
Tested in the iOS Simulator only.
