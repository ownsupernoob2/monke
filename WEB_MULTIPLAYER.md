# Browser Multiplayer (Web) for Monke

This project currently uses:
- EOS P2P (desktop)
- ENet fallback (desktop)

Those are **not enough for browser multiplayer**. Browsers need WebRTC/WebSocket transports.

## Recommended architecture

Use **WebRTC data channels** for game traffic + a lightweight **WebSocket signaling server** for offer/answer/ICE exchange.

- Signaling server (included template): `web/signaling-server/server.js`
- Configure URL in game settings: `GameSettings.webrtc_signal_url`

## Why multiplayer fails in browser today

- Browser cannot host ENet sockets.
- EOS native path is desktop-focused in this project flow.
- `GameLobby` does not yet create a `WebRTCMultiplayerPeer` path.

## What is included now

- Signaling server template using Node + `ws`.
- Existing project setting key: `webrtc_signal_url`.
- Native opt-in key: `force_webrtc_on_native` (false by default).
- Existing web guardrails in lobby/connect code.

## What still needs to be implemented in Godot (next code step)

In `multiplayer/lobby.gd`, add a full web branch:

1. Create signaling client (`WebSocketPeer`) and connect to `webrtc_signal_url`.
2. Host flow:
   - generate room code
   - join signaling room as host
   - create `WebRTCMultiplayerPeer` server mode
   - on each new peer, create `WebRTCPeerConnection`, add to multiplayer peer, create/send offers
3. Join flow:
   - join signaling room with room code
   - create `WebRTCMultiplayerPeer` client mode
   - process incoming offers, return answers, forward ICE candidates
4. Poll:
   - signaling socket + each RTC connection every frame/timer tick
5. Keep existing EOS/ENet for non-web builds.

## Minimal signaling protocol used by template

Client -> server:
- `{ "type": "join", "room": "ABC123", "peer_id": "42" }`
- `{ "type": "signal", "to": "17", "data": { ...offer/answer/ice... } }`

Server -> client:
- `{ "type": "joined", "room": "ABC123", "peer_id": "42" }`
- `{ "type": "room_peers", "room": "ABC123", "you": "42", "peers": ["42", "17"] }`
- `{ "type": "signal", "room": "ABC123", "from": "17", "data": { ... } }`

## Run signaling server

```bash
cd web/signaling-server
npm install
npm start
```

Default endpoint:
- `ws://localhost:8787`

## Deployment notes

- For production use **WSS** (TLS), not plain WS.
- Add STUN/TURN config for NAT traversal reliability.
- Keep host-authoritative logic (already used by current codebase).

## Next implementation target

If you want, the next patch can directly implement the WebRTC branch in `multiplayer/lobby.gd` using this signaling protocol, while preserving desktop EOS/ENet paths unchanged.

## PC compatibility

- Browser build: always uses WebRTC path.
- Native PC build: still EOS/ENet by default.
- To make native PC use the same WebRTC rooms as browser, set:
   - `GameSettings.webrtc_signal_url = "wss://your-signal-server"`
   - `GameSettings.force_webrtc_on_native = true`
