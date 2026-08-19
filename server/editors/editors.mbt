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
  server.run_forever(
    (conn, peer_addr) => handle(hub, conn, peer_addr, verbose~),
    allow_failure=true,
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
  defer hub.leave(client)
  defer conn.close()
  if verbose {
    @logging.log("+ \{client.id} connected from \{peer_addr}")
  }
  // Tell the newcomer what mode it has just been drafted into, and tell
  // everyone else that it has arrived.
  conn.write(hub.welcome_frame(client))
  hub.broadcast_roster()
  let missed_pongs = Ref(0)
  @async.with_task_group(group => {
    // Both helpers are `no_wait`: they run until the group body below
    // returns, and are cancelled with it. The read loop *is* the body, so
    // the connection lives exactly as long as the editor keeps talking.
    group.spawn_bg(() => write_loop(client, conn), no_wait=true)
    group.spawn_bg(
      () => heartbeat(hub, client, conn, missed_pongs),
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
/// Closing the socket is what ends the connection: it makes the read loop --
/// the task group's body -- return, which cancels this task and the writer.
/// TCP would otherwise hold a dead connection open indefinitely.
async fn heartbeat(
  hub : @state.Hub,
  client : @state.Client,
  conn : @socket.Tcp,
  missed_pongs : Ref[Int],
) -> Unit {
  for ;; {
    @async.sleep(PING_INTERVAL_MS)
    if missed_pongs.val >= MAX_MISSED_PONGS {
      conn.close()
      return
    }
    missed_pongs.val += 1
    hub.ping_one(client)
  }
}
