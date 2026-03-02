# Setting Up Epic Online Services (EOS) for Monke

EOS lets players join each other across the internet **without port forwarding**.  
Players share a room code — no IP addresses needed.  
The service is **completely free**.

---

## Step 1 — Download the godot-eos plugin

1. Go to: https://github.com/3ddelano/epic-online-services-godot/releases/latest  
2. Download **`epic-online-services-godot-windows-<hash>.zip`** (the Windows build, ~14 MB).
3. Extract the zip.  Inside you'll find an `addons/` folder.
4. Copy the entire `addons/` folder into `res://` (i.e. `c:\Users\ahmed\monke\`).  
   After this you should have:  
   ```
   c:\Users\ahmed\monke\addons\epic-online-services-godot\
   ```

---

## Step 2 — Enable the plugin in Godot

1. Open the project in Godot 4.6.1.
2. **Project → Project Settings → Plugins**
3. Find **"Epic Online Services"** → click **Enable**.
4. Restart the editor when prompted.

---

## Step 3 — Register your game on the Epic Dev Portal (free)

1. Go to https://dev.epicgames.com/portal and sign in (free Epic account).
2. Click **"Create Product"** → give it any name (e.g. "Monke").
3. In your new product, go to **Product Settings** and note:
   - **Product ID**
4. Go to your sandbox (default sandbox is created automatically):
   - Note the **Sandbox ID**
   - Note the **Deployment ID**
5. Go to **Clients** → **Add New Client**:
   - Client Policy: choose **"Peer-to-peer"** (or create a custom policy allowing P2P + lobbies).
   - Note the **Client ID** and **Client Secret**.

---

## Step 4 — Fill in your credentials

Open `res://multiplayer/eos_bootstrap.gd` and fill in the five constants:

```gdscript
const PRODUCT_ID    : String = "YOUR_PRODUCT_ID"
const SANDBOX_ID    : String = "YOUR_SANDBOX_ID"
const DEPLOYMENT_ID : String = "YOUR_DEPLOYMENT_ID"
const CLIENT_ID     : String = "YOUR_CLIENT_ID"
const CLIENT_SECRET : String = "YOUR_CLIENT_SECRET"
```

---

## Step 5 — Play!

- Run the game.  On the connect screen, click **Host Game**.
- The lobby room will show a **Room code** (big string from EOS).
- Copy and paste that code to the other player.
- Other player opens game → Connect screen → pastes code → clicks **Join Game**.
- No port forwarding needed.  NAT traversal is handled by Epic's servers.

---

## Fallback behaviour (if plugin not installed / credentials not filled)

The game automatically falls back to the old **ENet / direct-IP** mode:

- Connect screen shows the IP field instead of the code field.
- Lobby room shows LAN + WAN IP as before.
- This means local / LAN play still works even without EOS configured.

---

## Notes

- The lobby code (the EOS `lobby_id`) is a long hex string. Share it via Discord / chat.
- Anonymous device-id logins are used — players do **not** need an Epic account.
- Each device is identified by a hardware fingerprint stored locally.
- Lobbies are destroyed automatically when the host disconnects.
- All existing gameplay (LPS, Banana Frenzy, Tag, spectator, chat, leaderboard) works unchanged — only the connection plumbing changed.
