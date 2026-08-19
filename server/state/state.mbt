///|
/// How many frames we are willing to hold for a client that has stopped
/// reading. Past this the oldest are dropped: a stalled editor should fall
/// behind and then catch up, never stall the broadcast for everyone else.
const OUTBOX_DEPTH : Int = 64

///|
/// One connected editor.
pub struct Client {
  id : String
  mut user : String
  mut host : String
  /// Frames waiting to go out. The connection's writer task is the only
  /// consumer, so nothing else ever touches the socket for output.
  outbox : @aqueue.Queue[String]
}

///|
/// A dashboard browser watching over a WebSocket.
pub struct Dashboard {
  id : Int
  outbox : @aqueue.Queue[String]
}

///|
/// The single global mode, and everyone subject to it.
///
/// The async runtime is single-threaded, so this needs no locking: every
/// mutation below runs to completion before another task observes it.
pub struct Hub {
  mut mode : @protocol.Mode
  mut seq : Int64
  mut by : String
  clients : Map[String, Client]
  dashboards : Map[Int, Dashboard]
  mut next_client_id : Int
  mut next_dashboard_id : Int
}

///|
pub fn Hub::new() -> Hub {
  {
    mode: Normal,
    seq: 0L,
    by: "nobody",
    clients: {},
    dashboards: {},
    next_client_id: 0,
    next_dashboard_id: 0,
  }
}

///|
/// Register a new editor. The caller must pair this with `leave`.
pub fn Hub::join(self : Hub, user : String, host : String) -> Client {
  self.next_client_id += 1
  let client = {
    id: "c\{self.next_client_id}",
    user,
    host,
    outbox: @aqueue.Queue(kind=DiscardOldest(OUTBOX_DEPTH)),
  }
  self.clients[client.id] = client
  client
}

///|
pub fn Hub::leave(self : Hub, client : Client) -> Unit {
  self.clients.remove(client.id)
  client.outbox.close()
  self.broadcast_roster()
}

///|
/// Identify a client that said hello after connecting.
pub fn Hub::identify(
  self : Hub,
  client : Client,
  user : String,
  host : String,
) -> Unit {
  client.user = user
  client.host = host
  self.broadcast_roster()
}

///|
pub fn Hub::subscribe_dashboard(self : Hub) -> Dashboard {
  self.next_dashboard_id += 1
  let dashboard = {
    id: self.next_dashboard_id,
    outbox: @aqueue.Queue(kind=DiscardOldest(OUTBOX_DEPTH)),
  }
  self.dashboards[dashboard.id] = dashboard
  dashboard
}

///|
pub fn Hub::unsubscribe_dashboard(self : Hub, dashboard : Dashboard) -> Unit {
  self.dashboards.remove(dashboard.id)
  dashboard.outbox.close()
}

///|
/// Apply a mode change requested by `client` and fan it out.
///
/// Returns true if the global mode actually moved. A request for the mode we
/// are already in is a no-op that does *not* bump `seq` — this is what keeps
/// one keypress worth exactly one increment even when every other editor
/// dutifully reports the mode it was just forced into.
pub fn Hub::set_mode(
  self : Hub,
  client : Client,
  mode : @protocol.Mode,
) -> Bool {
  if self.mode == mode {
    return false
  }
  self.mode = mode
  self.seq += 1
  self.by = client.user
  let frame = @protocol.encode_mode(mode, self.seq, client.user, client.id)
  // Everyone except the originator: it is already in this mode, and echoing
  // would invite a ping-pong loop.
  for id, peer in self.clients {
    if id != client.id {
      send(peer.outbox, frame)
    }
  }
  self.push_state()
  true
}

///|
/// The frame a client receives immediately on connecting.
pub fn Hub::welcome_frame(self : Hub, client : Client) -> String {
  @protocol.encode_welcome(client.id, self.mode, self.seq, self.by)
}

///|
/// A full state snapshot, for the dashboard and `GET /api/state`.
pub fn Hub::state_json(self : Hub) -> String {
  @protocol.encode_state(self.mode, self.seq, self.by, self.peers())
}

///|
pub fn Hub::peers(self : Hub) -> Array[@protocol.Peer] {
  let peers : Array[@protocol.Peer] = []
  for _, client in self.clients {
    peers.push({ id: client.id, user: client.user, host: client.host })
  }
  peers
}

///|
pub fn Hub::broadcast_roster(self : Hub) -> Unit {
  let frame = @protocol.encode_roster(self.peers())
  for _, client in self.clients {
    send(client.outbox, frame)
  }
  self.push_state()
}

///|
/// Push the current state to every watching dashboard.
pub fn Hub::push_state(self : Hub) -> Unit {
  if self.dashboards.is_empty() {
    return
  }
  let snapshot = self.state_json()
  for _, dashboard in self.dashboards {
    send(dashboard.outbox, snapshot)
  }
}

///|
/// Ask one editor to prove it is still there.
pub fn Hub::ping_one(self : Hub, client : Client) -> Unit {
  send(client.outbox, @protocol.encode_ping(self.mode, self.seq, self.by))
}

///|
/// Enqueue without ever blocking or raising.
///
/// `try_put` does NOT honour `DiscardOldest` — it just returns false when the
/// queue is full (the async `put` is the one that discards, and this is called
/// from synchronous code). Taking that at face value would silently invert the
/// policy into discard-*newest*, which is the worst possible choice here: the
/// frame dropped would be the newest one, so a client that fell behind would be
/// left displaying a stale mode forever, with no resync to correct it.
///
/// So drop the oldest frame explicitly and retry. A closed queue — a client
/// that disconnected mid-broadcast — is expected, not exceptional.
fn send(outbox : @aqueue.Queue[String], frame : String) -> Unit {
  try {
    if !outbox.try_put(frame) {
      outbox.try_get() |> ignore
      outbox.try_put(frame) |> ignore
    }
  } catch {
    _ => ()
  }
}
