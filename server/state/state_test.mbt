///|
/// Drain a client's outbox without blocking, so tests can assert on exactly
/// what a given editor would have received.
fn drain(client : Client) -> Array[String] {
  let frames = []
  for ;; {
    let next = client.outbox.try_get() catch { _ => None }
    guard next is Some(frame) else { break }
    frames.push(frame)
  }
  frames
}

///|
fn mode_frames(client : Client) -> Array[String] {
  drain(client).filter(f => f.contains("\"t\":\"mode\""))
}

///|
test "a mode change reaches every peer except its originator" {
  let hub = Hub::new()
  let alex = hub.join("alex", "thinkpad")
  let sam = hub.join("sam", "desktop")
  let kim = hub.join("kim", "laptop")
  assert_true(hub.set_mode(alex, Insert))
  assert_eq(mode_frames(alex).length(), 0)
  assert_eq(mode_frames(sam).length(), 1)
  assert_eq(mode_frames(kim).length(), 1)
}

///|
test "the broadcast frame names the mode and who is to blame" {
  let hub = Hub::new()
  let alex = hub.join("alex", "thinkpad")
  let sam = hub.join("sam", "desktop")
  hub.set_mode(alex, Insert) |> ignore
  let frames = mode_frames(sam)
  assert_eq(frames.length(), 1)
  let json = @json.parse(frames[0].trim(chars="\n").to_owned())
  guard json is Object(fields) else { fail("frame did not parse") }
  assert_eq(fields.get("mode"), Some(Json::string("i")))
  assert_eq(fields.get("by"), Some(Json::string("alex")))
  assert_eq(fields.get("by_id"), Some(Json::string(alex.id)))
  assert_eq(fields.get("seq"), Some(Json::number(1)))
}

///|
test "seq advances by exactly one per real change" {
  let hub = Hub::new()
  let alex = hub.join("alex", "thinkpad")
  assert_eq(hub.seq, 0)
  hub.set_mode(alex, Insert) |> ignore
  assert_eq(hub.seq, 1)
  hub.set_mode(alex, Normal) |> ignore
  assert_eq(hub.seq, 2)
  hub.set_mode(alex, Visual) |> ignore
  assert_eq(hub.seq, 3)
}

///|
test "re-reporting the current mode is a no-op" {
  // This is the second line of defence against a ping-pong storm: if a
  // client's loop guard ever fails and it echoes back the mode it was just
  // forced into, the server refuses to count it.
  let hub = Hub::new()
  let alex = hub.join("alex", "thinkpad")
  let sam = hub.join("sam", "desktop")
  assert_true(hub.set_mode(alex, Insert))
  drain(sam) |> ignore
  assert_false(hub.set_mode(sam, Insert))
  assert_false(hub.set_mode(alex, Insert))
  assert_eq(hub.seq, 1)
  // And critically, no further traffic was generated.
  assert_eq(mode_frames(sam).length(), 0)
}

///|
test "a slow client drops old frames instead of stalling the hub" {
  let hub = Hub::new()
  let alex = hub.join("alex", "thinkpad")
  let sam = hub.join("sam", "desktop")
  // Sam never reads. Push far more than the outbox can hold.
  for i in 0..<500 {
    hub.set_mode(alex, if i % 2 == 0 { Insert } else { Normal }) |> ignore
  }
  // The hub kept going and stayed correct...
  assert_eq(hub.seq, 500)
  assert_eq(hub.mode, Normal)
  // ...and Sam's backlog is bounded, holding only the most recent frames.
  let backlog = drain(sam)
  assert_true(backlog.length() <= 64)
  assert_true(backlog.length() > 0)
}

///|
test "leaving removes a client from the roster" {
  let hub = Hub::new()
  let alex = hub.join("alex", "thinkpad")
  let sam = hub.join("sam", "desktop")
  assert_eq(hub.peers().length(), 2)
  hub.leave(sam)
  assert_eq(hub.peers().length(), 1)
  assert_eq(hub.peers()[0].user, "alex")
  // A departed client no longer receives anything, and pushing to it is safe.
  hub.set_mode(alex, Insert) |> ignore
  assert_eq(hub.seq, 1)
}

///|
test "clients get distinct ids" {
  let hub = Hub::new()
  let ids = (0).until(10).map(_ => hub.join("u", "h").id).collect()
  assert_eq(ids.length(), 10)
  let unique = Set::from_array(ids)
  assert_eq(unique.length(), 10)
}

///|
test "a joining client is welcomed with the mode already in force" {
  let hub = Hub::new()
  let alex = hub.join("alex", "thinkpad")
  hub.set_mode(alex, Replace) |> ignore
  let latecomer = hub.join("kim", "laptop")
  let json = @json.parse(
    hub.welcome_frame(latecomer).trim(chars="\n").to_owned(),
  )
  guard json is Object(fields) else { fail("welcome did not parse") }
  assert_eq(fields.get("id"), Some(Json::string(latecomer.id)))
  assert_eq(fields.get("mode"), Some(Json::string("R")))
  assert_eq(fields.get("by"), Some(Json::string("alex")))
  assert_eq(fields.get("seq"), Some(Json::number(1)))
}

///|
test "dashboards receive state on every change" {
  let hub = Hub::new()
  let alex = hub.join("alex", "thinkpad")
  let dashboard = hub.subscribe_dashboard()
  hub.set_mode(alex, Insert) |> ignore
  let frames = []
  for ;; {
    let next = dashboard.outbox.try_get() catch { _ => None }
    guard next is Some(frame) else { break }
    frames.push(frame)
  }
  assert_true(frames.length() >= 1)
  let json = @json.parse(frames[frames.length() - 1])
  guard json is Object(fields) else { fail("state did not parse") }
  assert_eq(fields.get("label"), Some(Json::string("INSERT")))
  assert_eq(fields.get("by"), Some(Json::string("alex")))
}

///|
test "a client that fell behind still ends on the current mode" {
  // `try_put` does not honour DiscardOldest, so a naive `send` silently becomes
  // discard-NEWEST: the frame thrown away is the correcting one, and a stalled
  // client is left displaying a stale mode with nothing to resync it. The last
  // frame a backlogged client holds must be the mode actually in force.
  let hub = Hub::new()
  let alex = hub.join("alex", "thinkpad")
  let sam = hub.join("sam", "desktop")
  for i in 0..<500 {
    hub.set_mode(alex, if i % 2 == 0 { Insert } else { Normal }) |> ignore
  }
  assert_eq(hub.mode, Normal)
  let backlog = drain(sam).filter(f => f.contains("\"t\":\"mode\""))
  assert_true(backlog.length() > 0)
  let last = @json.parse(
    backlog[backlog.length() - 1].trim(chars="\n").to_owned(),
  )
  guard last is Object(fields) else { fail("frame did not parse") }
  assert_eq(fields.get("mode"), Some(Json::string(hub.mode.to_wire())))
  assert_eq(fields.get("seq"), Some(Json::number(hub.seq.to_double())))
}

///|
test "only the first hello on a connection counts" {
  // Every identify fans a fresh roster to everyone connected, so an unthrottled
  // one is an O(n) amplifier: a client repeating `hello` pinned a core with 150
  // idle editors attached.
  let hub = Hub::new()
  let alex = hub.join("anon", "1.2.3.4")
  let sam = hub.join("anon", "5.6.7.8")
  hub.identify(alex, "alex", "thinkpad")
  drain(sam) |> ignore
  for _ in 0..<200 {
    hub.identify(alex, "evil", "elsewhere")
  }
  // The name from the first hello stands, and no further rosters were sent.
  let mine = hub.peers().filter(p => p.id == alex.id)
  assert_eq(mine.length(), 1)
  assert_eq(mine[0].user, "alex")
  assert_eq(drain(sam).length(), 0)
}
