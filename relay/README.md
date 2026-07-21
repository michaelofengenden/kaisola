# Kaisola Link relay

Kaisola Link is an account-scoped, opaque WebSocket rendezvous for the macOS
and iPhone apps. It never terminates the companion Noise channel and never
stores terminal output. Both clients request a one-time 60-second ticket with a
current Firebase ID token, then the Durable Object forwards bounded binary
frames between the selected Mac and device.

Production: `https://kaisola-link.michaelofengend.workers.dev`

## Deploy

1. `cd relay && npm install`
2. Create a 32-byte-or-longer random secret and store it with
   `npx wrangler secret put ACCOUNT_KEY_SECRET`.
3. `npm test && npm run check && npm run deploy`
4. Put the resulting HTTPS Workers URL in the desktop and iPhone public config
   as `relayUrl`. The apps convert only the server-returned ticket URL to WSS.

The Worker calls the existing Firebase `session` function for revocation-aware
account verification. Relay-purpose verification skips the ordinary profile
read/write, keeping reconnects off the Firestore billing path. WebSocket
attachments contain routing metadata only.
Ticket records are consumed once; expired records are removed opportunistically.

The Durable Object uses Cloudflare's hibernation WebSocket API. There are no
timers, outbound sockets, transcript writes, or plaintext protocol parsing in
the room.

## Operational bounds

- 2 MiB per opaque relay message and 4 MiB maximum buffered output per peer.
- At most 8 desktop sockets, 16 phone sockets, and 64 active tickets per account.
- Tickets are random, stored only as SHA-256 digests, consumed transactionally,
  and expire after 60 seconds.
- Account room names are HMAC-derived from the verified Firebase UID; the UID
  and ID token are not used as Durable Object names or WebSocket parameters.
- Replacing a desktop connection reattaches waiting phones. Commands remain
  receipt-driven by the companion protocol and are never retried by the relay.

Cloudflare can observe account-room routing, connection timing, and ciphertext
sizes. It cannot decrypt the Noise channel. A real-device release gate should
exercise Wi-Fi/cellular switching, Worker/desktop reconnect, device revocation,
slow consumers, and bounded replay before declaring remote-anywhere complete.
