import { WebSocketServer } from 'ws';

const PORT = Number(process.env.PORT || 8787);
const wss = new WebSocketServer({ port: PORT });

/** @type {Map<string, Map<string, import('ws').WebSocket>>} */
const rooms = new Map();

function roomMap(roomCode) {
  if (!rooms.has(roomCode)) rooms.set(roomCode, new Map());
  return rooms.get(roomCode);
}

function broadcastRoomState(roomCode) {
  const peers = roomMap(roomCode);
  const ids = [...peers.keys()];
  for (const [peerId, ws] of peers.entries()) {
    if (ws.readyState !== ws.OPEN) continue;
    ws.send(JSON.stringify({
      type: 'room_peers',
      room: roomCode,
      you: peerId,
      peers: ids,
    }));
  }
}

function safeSend(ws, payload) {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(payload));
}

wss.on('connection', (ws) => {
  let roomCode = '';
  let peerId = '';

  ws.on('message', (buf) => {
    let msg;
    try {
      msg = JSON.parse(buf.toString());
    } catch {
      safeSend(ws, { type: 'error', message: 'invalid_json' });
      return;
    }

    if (msg.type === 'join') {
      roomCode = String(msg.room || '').trim().toUpperCase();
      peerId = String(msg.peer_id || '').trim();
      if (!roomCode || !peerId) {
        safeSend(ws, { type: 'error', message: 'missing_room_or_peer_id' });
        return;
      }

      const peers = roomMap(roomCode);
      peers.set(peerId, ws);
      safeSend(ws, { type: 'joined', room: roomCode, peer_id: peerId });
      broadcastRoomState(roomCode);
      return;
    }

    if (msg.type === 'signal') {
      const to = String(msg.to || '');
      const peers = roomMap(roomCode);
      const target = peers.get(to);
      if (!target) return;
      safeSend(target, {
        type: 'signal',
        room: roomCode,
        from: peerId,
        data: msg.data || {},
      });
      return;
    }
  });

  ws.on('close', () => {
    if (!roomCode || !peerId) return;
    const peers = roomMap(roomCode);
    peers.delete(peerId);
    if (peers.size === 0) {
      rooms.delete(roomCode);
      return;
    }
    broadcastRoomState(roomCode);
  });
});

console.log(`[monke signaling] listening on ws://0.0.0.0:${PORT}`);
