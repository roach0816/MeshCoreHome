# Features

A tour of everything MeshCore Home does. The [README](../README.md#what-it-does) has the summary.

- [Messaging](#messaging)
- [Contacts](#contacts)
- [Repeater and room server administration](#repeater-and-room-server-administration)
- [Your radio's settings](#your-radios-settings)
- [Bot](#bot)
- [Map](#map)
- [Settings and administration](#settings-and-administration)
- [Reliability](#reliability)
- [API](#api)

## Messaging

- **Channels and direct messages** with unread counts, favorites, search, paginated history, a date
  badge per day, a "new messages" divider, per-conversation drafts, and a UTF-8 byte budget in the
  composer. The composer has a built-in emoji picker that draws emoji with the system emoji font.
- **Honest delivery states:** *Queued → Sending → Sent by radio / Delivered / Not confirmed delivered
  / Outcome uncertain / Failed / Expired*. Sends are idempotent, and an interrupted send is never
  re-sent automatically.
- **Add channel** (the **+** next to the search box) offers the same choices as the MeshCore app:
  create a private channel, join a private channel, join Public, join a hashtag channel, or scan a QR
  code. Hashtag and new private channels come with their key, a QR code, and a
  `meshcore://channel/add` link to share. A channel can have a **region scope**: messages you send on
  it only flood through repeaters serving that region. Scanning with the live camera needs HTTPS;
  over plain HTTP you can scan a photo instead.
- **Message menu** (right-click or long-press a message):
  - **Message details:** when it was sent and received, hops, path hash size, SNR and RSSI.
  - **Sender info:** the sender's contact. For channels this is matched by name, which isn't verified.
  - **View message paths:** the route of every copy your radio heard, with the repeaters named from
    your contacts. Paths are recorded from the radio's packet log while MeshCore Home is connected.
  - **Copy text**, **Block sender**, and **Delete** (removes the message from the archive only).
- **Conversation menu** (right-click or long-press a conversation): info, mark as read, favorite, mute
  or unmute, and delete or clear history.
- **One star per person:** starring a direct-message conversation and favouriting the contact are the
  same thing (the radio's favourite flag), so the sidebar, Contacts and the bot always agree. Channels
  have their own star.
- **Notification sounds:** a chime for new incoming messages while the app is open in a browser tab:
  *All messages*, *Direct messages only*, or *Off*, with per-conversation overrides.
- **Read state** is shared across browsers and only moves forward.

## Contacts

A compact, searchable list (name, device type, last heard) with type and status filters, sorting in
either direction, favorites first, and pagination. The list updates by itself as the radio hears
adverts. Click a person to open your conversation with them, or a repeater or room server to manage
it. Right-click or long-press a contact for:

- **Details**.
- **Share:** copy a `meshcore://` contact link, or re-broadcast the advert to nearby nodes.
- **Set path / Reset path:** choose the repeater route, or go back to flooding.
- **Favorite:** sets the radio's favourite flag, so the radio won't overwrite the contact when its
  contact list is full.
- **Block:** an app-side block. MeshCore radios can't block traffic, so the blocked contact's DMs, and
  channel messages under their name, are archived but hidden, never unread, and silent. Unblocking
  restores them.
- **Remove contact:** removes it from the radio. The archive keeps the conversation.
- **Remote manage** (repeaters and room servers), below.

**Blocked** and **Removed from radio** are different: *Blocked* is MeshCore Home's own setting (the
contact stays on the radio), while *Removed from radio* means the contact is no longer in the radio's
contact list (removed by you, by another app, or dropped by the radio when its list was full).

## Repeater and room server administration

**Remote manage** logs in to a repeater or room server with its admin or guest password, then offers:

- **Status:** battery (percentage and voltage), uptime, signal, noise floor, packet and airtime
  counters.
- **Command line:** any MeshCore CLI command, with quick commands and history.
- **Settings:** name, radio settings (with the region presets), transmit power, owner info, adverts and
  advert intervals, position (with a map picker), clock, access list, admin and guest passwords,
  regions, routing, repeat limits, telemetry, neighbours, reboot, and version. **Change identity key**
  gives the node a new key with a public-key prefix you choose.

To save airtime, nothing is fetched until you tap a refresh icon; the page shows what was fetched last
and when. Passwords and keys are never stored or logged.

## Your radio's settings

**Settings → Configure node settings** changes the connected radio's own configuration:

- **Identity:** name, location (with "use this device's location" and a map picker), and whether
  adverts share the location.
- **LoRa radio:** MeshCore's region presets (kept up to date from MeshCore) or custom frequency,
  bandwidth, spreading factor and coding rate; TX power; client repeat.
- **Channels:** add, rename, remove, or set a region scope. Keys can be hashtag-derived, the Public
  key, a generated random key (shown once), or entered by hand. Private keys are never displayed
  afterwards.
- **Contacts and routing:** auto-add contacts, extra ACKs, path hash size, and default flood scope.
- **Other:** telemetry permissions, firmware variables, advanced timing, adverts, clock sync, and
  reboot.

Values are checked against the firmware's own limits before anything is sent. Factory reset and
private-key export/import are deliberately left out; use official MeshCore tools for those.

## Bot

**Settings → Bot** (off by default) lets you query your home node from another radio by direct
message:

- `/info`: the node's name, MeshCore Home version, time online, radio settings and contact count.
- `/ping`: how your message arrived (SNR, RSSI, hops or direct route).
- `/weather`: outdoor temperature, humidity, wind, 24-hour rain and air quality from an Ecowitt
  weather station (e.g. a WS90 through a GW1100/GW2000/GW3000 gateway) on your network. MeshCore Home
  reads the gateway's local live data directly, without the Ecowitt cloud. Set the gateway's address
  in Settings and use **Test station** to preview the reply.
- `/help`: the list of commands.

It answers favourite contacts only, unless you allow every contact. Channels are never answered, and
blocked contacts are ignored. Replies are rate-limited to save airtime (quick follow-up commands are
answered in turn), and commands older than 15 minutes are ignored.

## Map

Shows the companions, repeaters, room servers and sensors heard by the gateway at the positions they
advertise (sharing a position is optional in MeshCore), filterable by type and by when each node was
last heard. Built with [Leaflet](https://leafletjs.com) and [OpenStreetMap](https://www.openstreetmap.org)
tiles by default; see [Configuration](configuration.md#map-tiles-and-privacy) for privacy and
self-hosted tiles.

## Settings and administration

- **Radio connection:** MeshCore TCP, the Raspberry Pi radio HAT (native installs), Simulated (sample
  traffic, no hardware), or None. Switch at any time.
- **Account** (click your name, bottom left): change your username and password, sign out, and
  see **signed-in devices** (browsers and apps), with sign-out for any of them or all at once.
- **API keys:** see [API](#api).
- **Backup & restore:** see [Backup and restore](backup-restore.md).
- **Network & HTTPS** (native installs): see [HTTPS](install-native.md#https).
- **Software updates:** release notes and one-click updates on native installs, and the radio
  firmware check.
- **Maintenance pause/resume**, device information, collection gaps, JSON export, and deleting
  simulated data.
- Light and dark themes. Layouts for phone, tablet, and desktop.

## Reliability

- **Durable receive pipeline:** the server fetches one message from the radio, commits it to the
  database, and only then fetches the next. Collection gaps (outages, pauses, restarts) are recorded
  and shown in Settings.
- **One radio owner:** a PostgreSQL advisory lock makes sure exactly one process owns the radio.
- **Realtime:** an authenticated WebSocket pushes changes; the app falls back to REST resyncs if that
  connection drops.

## API

**Settings → API keys** lets other services and scripts read messages, send them, and follow events
live, using `Authorization: Bearer <key>`. A key can be *read only* or *read & write* and can expire.
Keys are shown once and stored only as a fingerprint. Account, network, update, backup and radio
settings stay limited to the web interface. See the [API guide](API.md); the running app also serves
an interactive reference at `/api/docs`.
