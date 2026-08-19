///|
/// The most editors we will hold at once. A joke plugin does not need more, and
/// leaving it unbounded turns each cheap client connect into O(n) work here.
const MAX_EDITORS : Int = 256

///|
/// How often to ping an idle editor, in milliseconds.
const PING_INTERVAL_MS : Int = 20_000

///|
/// Pings that may go unanswered before we assume the editor is gone. TCP will
/// happily hold a dead connection open forever otherwise.
const MAX_MISSED_PONGS : Int = 2

///|
/// Listen for editors and subject each one to the global mode.
pub async fn serve(
  hub : @state.Hub,
  addr : @socket.Addr,
  verbose? : Bool = false,
) -> Unit {
  let server = @socket.TcpServer(addr, reuse_addr=true)
  @logging.log("global mode: editors may connect on \{addr}")
  // allow_failure keeps one editor's broken pipe from taking down the server.
  // max_connections bounds the damage from a flood: each accept costs a roster
  // broadcast to everyone already connected, so unbounded accepts are both an
  // fd-exhaustion and a CPU-amplification vector.
  server.run_forever(
    (conn, peer_addr) => handle(hub, conn, peer_addr, verbose~),
    allow_failure=true,
    max_connections=MAX_EDITORS,
  )
}

///|
/// One editor, for as long as it stays connected.
///
/// Three tasks share the connection: a reader, a writer, and a heartbeat. The
/// writer is the only one that sends, so a broadcast never has to wait on a
/// slow socket. `with_task_group` tears down all three the moment any of them
/// finishes, which is what makes disconnect handling a single code path.
async fn handle(
  hub : @state.Hub,
  conn : @socket.Tcp,
  peer_addr : @socket.Addr,
  verbose~ : Bool,
) -> Unit {
  let client = hub.join("anon", "\{peer_addr}")
  // `run_forever` closes the connection itself once this returns and documents
  // that the handler must not; so this only has to give the client back.
  defer hub.leave(client)
  if verbose {
    @logging.log("+ \{client.id} connected from \{peer_addr}")
  }
  // Tell the newcomer what mode it has just been drafted into. Announcing it to
  // everyone else waits for its `hello`, which lands within milliseconds and
  // carries the real name — broadcasting the roster here as well would double
  // the cost of every connect for a listing that is immediately superseded.
  conn.write(hub.welcome_frame(client))
  let missed_pongs = Ref(0)
  @async.with_task_group(group => {
    // Both helpers are `no_wait`: they run until the group body below
    // returns, and are cancelled with it. The read loop *is* the body, so
    // the connection lives exactly as long as the editor keeps talking.
    group.spawn_bg(() => write_loop(client, conn), no_wait=true)
    group.spawn_bg(
      () => heartbeat(hub, client, group, missed_pongs),
      no_wait=true,
    )
    read_loop(hub, client, conn, missed_pongs, verbose~)
  })
  if verbose {
    @logging.log("- \{client.id} (\{client.user}) disconnected")
  }
}

///|
/// Read newline-delimited JSON until the editor goes away.
async fn read_loop(
  hub : @state.Hub,
  client : @state.Client,
  conn : @socket.Tcp,
  missed_pongs : Ref[Int],
  verbose~ : Bool,
) -> Unit {
  while conn.read_until("\n") is Some(line) {
    // Any traffic at all proves the editor is alive.
    missed_pongs.val = 0
    match @protocol.decode_client(line.trim(chars="\r\n").to_owned()) {
      Some(Hello(user~, host~, nvim~)) => {
        if verbose {
          @logging.log("  \{client.id} is \{user}@\{host} (nvim \{nvim})")
        }
        hub.identify(client, user, host)
      }
      Some(SetMode(mode~)) =>
        if hub.set_mode(client, mode) && verbose {
          @logging.log(
            "  \{client.user} made it \{mode.label()} for everyone (seq \{hub.seq})",
          )
        }
      Some(Pong) => ()
      // Unparseable lines are ignored rather than fatal: a stray `nc` poking
      // at the port should not disconnect anybody.
      None => ()
    }
  }
}

///|
/// Drain this client's outbox to its socket. The sole writer.
async fn write_loop(client : @state.Client, conn : @socket.Tcp) -> Unit {
  for ;; {
    conn.write(client.outbox.get())
  }
}

///|
/// Ping an idle editor, and hang up on it after enough silence.
///
/// Ending the task group is what ends the connection. Closing the socket here
/// instead does NOT work: `IoHandle::close` detaches the fd and nulls it, but
/// never wakes a coroutine already parked in `wait_read` — which is exactly
/// where an idle editor's read loop is sitting, and idle editors are the whole
/// population this function targets. The group body would never return, the
/// `defer` would never run, and the client would linger in the roster forever.
/// Returning through the group cancels the parked reader properly.
async fn heartbeat(
  hub : @state.Hub,
  client : @state.Client,
  group : @async.TaskGroup[Unit],
  missed_pongs : Ref[Int],
) -> Unit {
  for ;; {
    @async.sleep(PING_INTERVAL_MS)
    if missed_pongs.val >= MAX_MISSED_PONGS {
      group.return_immediately(())
    }
    missed_pongs.val += 1
    hub.ping_one(client)
  }
}
