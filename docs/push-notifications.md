# Push notifications

MeshHome can send new messages to the MeshHome iPhone and iPad app as push notifications, even when
the app is closed. They show the sender and the message, like Messages does. Push notifications are
**off** until the owner turns them on.

## Turning them on

1. **On the server:** Settings → **Push notifications** → **Allow push notifications**, in the web
   interface or in the app.
2. **On each phone:** in the app, Settings → **Notifications** → **Push notifications**. iOS asks
   for permission. Then choose **Direct messages**, **Channels**, or both. **Send a test
   notification** checks the whole path.

A conversation's own alert setting overrides the phone's choice: a channel set to alert is always
pushed, and a muted conversation never is. Messages from blocked contacts are never pushed, and
neither are your own. When several messages arrive in one conversation, each new notification
replaces the previous one. Signing a phone out, or revoking it under Signed-in devices, stops its
notifications.

## How it works, and what leaves your network

Apple delivers a notification only when it is signed with the app's push key. That key can't be
handed out to every self-hosted server, so notifications go through a small **relay** (a Cloudflare
Worker run for the published app, at `https://push.meshhome.app`; its code is in
[push-relay/](../push-relay/)) that holds the key.

```text
MeshHome server ──(encrypted)──▶ relay ──▶ Apple (APNs) ──▶ phone: decrypts, shows "Kayak: …"
```

- **Encryption:** when a phone signs up, it creates a random 256-bit key and gives it to your
  MeshHome server. The server encrypts each notification's sender, text, conversation and unread
  count with that key (AES-256-GCM). The phone's notification extension decrypts it. If it can't
  (for example after signing out), the notification just says "New message".
- **What the relay and Apple see:** the phone's push token, an unreadable blob, your server's IP
  address and the time. Grouping and the badge are also inside the encrypted part. The relay
  stores nothing and logs no tokens or content.
- **Who can push to a phone:** the phone gets a *ticket* for its push token from the relay and
  gives it only to its own MeshHome server. The relay forwards only pushes that carry the matching
  ticket, and it rate-limits them.
- **When the relay is unavailable:** nothing else is affected. The app and web interface work as
  before, and the phone shows the messages when the app opens.

## The relay's address

The relay only works with the push key of the Apple team that publishes the app, so the app needs
the published relay, `https://push.meshhome.app`. Leave Settings → Push notifications → **Relay
address** as it is. The relay's code is public so anyone can check what it does
([push-relay/](../push-relay/)).

## Troubleshooting

- **The test notification doesn't arrive:** Settings → Notifications in the app shows the last
  error from the relay. Check that notifications for MeshHome are allowed in the iPhone's Settings
  app, and that the server can reach the relay address over the internet.
- **"Push notifications are turned off on your MeshHome server":** the owner hasn't allowed them
  yet (step 1 above).
