///|
test "every mode round-trips through the wire format" {
  let all : Array[Mode] = [
    Normal,
    Insert,
    Visual,
    VisualLine,
    VisualBlock,
    Replace,
    Cmdline,
    Terminal,
  ]
  for mode in all {
    assert_eq(Mode::of_wire(mode.to_wire()), Some(mode))
  }
}

///|
test "unknown modes are rejected rather than coerced" {
  // Neovim's operator-pending and transitional modes must never appear here:
  // the plugin drops them, and the server refuses them if a client misbehaves.
  for bad in ["no", "niI", "s", "S", "Rv", "cv", "", "x", "N"] {
    assert_eq(Mode::of_wire(bad), None)
  }
}

///|
test "decoding a hello" {
  let line =
    #|{"t":"hello","user":"alex","host":"thinkpad","nvim":"0.11.0"}
  assert_eq(
    decode_client(line),
    Some(Hello(user="alex", host="thinkpad", nvim="0.11.0")),
  )
}

///|
test "hello tolerates missing fields" {
  let line =
    #|{"t":"hello"}
  assert_eq(decode_client(line), Some(Hello(user="anon", host="?", nvim="?")))
}

///|
test "decoding a mode change" {
  let line =
    #|{"t":"mode","mode":"i"}
  assert_eq(decode_client(line), Some(SetMode(mode=Insert)))
}

///|
test "garbage does not decode" {
  let junk = [
    "",
    "not json at all",
    "{}",
    "[]",
    "null",
    (
      #|{"t":"mode"}
    ),
    (
      #|{"t":"mode","mode":"no"}
    ),
    (
      #|{"t":"mode","mode":42}
    ),
    (
      #|{"t":"nonsense"}
    ),
    (
      #|{"mode":"i"}
    ),
  ]
  for line in junk {
    assert_eq(decode_client(line), None)
  }
}

///|
test "encoded frames are single newline-terminated lines" {
  let frames = [
    encode_welcome("c1", Normal, 0L, "server"),
    encode_mode(Insert, 7L, "alex", "c1"),
    encode_roster([{ id: "c1", user: "alex", host: "thinkpad" }]),
    encode_ping(Normal, 0L, "server"),
  ]
  for frame in frames {
    assert_true(frame.has_suffix("\n"))
    // Exactly one newline: the framing depends on it.
    assert_eq(frame.split("\n").count(), 2)
  }
}

///|
test "user-supplied names cannot break out of the JSON frame" {
  // A user called `","t":"evil` must not be able to forge fields.
  let frame = encode_roster([
    { id: "c1", user: "\",\"t\":\"evil", host: "a\nb" },
  ])
  assert_eq(frame.split("\n").count(), 2)
  let parsed = @json.parse(frame.trim(chars="\n").to_owned())
  guard parsed is Object(fields) else { fail("roster did not parse") }
  assert_eq(fields.get("t"), Some(Json::string("roster")))
}

///|
test "state snapshot carries the human-readable label" {
  let json = @json.parse(
    encode_state(VisualBlock, 3L, "alex", [
      { id: "c1", user: "alex", host: "thinkpad" },
    ]),
  )
  guard json is Object(fields) else { fail("state did not parse") }
  assert_eq(fields.get("mode"), Some(Json::string("b")))
  assert_eq(fields.get("label"), Some(Json::string("V-BLOCK")))
  assert_eq(fields.get("seq"), Some(Json::number(3)))
}

///|
test "a name that cannot be encoded as UTF-8 is rejected" {
  // JSON may legally carry an unpaired surrogate. MoonBit strings are UTF-16,
  // so such a name parses fine and then aborts the *process* when it is encoded
  // for the next broadcast — one frame took the whole server down for everyone.
  let lone_high =
    #|{"t":"hello","user":"\ud800","host":"h","nvim":"0"}
  assert_eq(
    decode_client(lone_high),
    Some(Hello(user="anon", host="h", nvim="0")),
  )
  let lone_low =
    #|{"t":"hello","user":"a","host":"\udc00","nvim":"0"}
  assert_eq(decode_client(lone_low), Some(Hello(user="a", host="?", nvim="0")))
  let reversed =
    #|{"t":"hello","user":"\udc00\ud800","host":"h","nvim":"0"}
  assert_eq(
    decode_client(reversed),
    Some(Hello(user="anon", host="h", nvim="0")),
  )
}

///|
test "a properly paired surrogate is still accepted" {
  // Rejecting lone surrogates must not reject legitimate astral characters.
  let emoji =
    #|{"t":"hello","user":"😀","host":"h","nvim":"0"}
  guard decode_client(emoji) is Some(Hello(user~, ..)) else {
    fail("a valid surrogate pair was rejected")
  }
  assert_eq(user.char_length(), 1)
}

///|
test "over-long fields are rejected rather than stored" {
  // They would otherwise be copied into every roster frame and state snapshot.
  let long = "L".repeat(500)
  let line = "{\"t\":\"hello\",\"user\":\"\{long}\",\"host\":\"h\",\"nvim\":\"0\"}"
  assert_eq(decode_client(line), Some(Hello(user="anon", host="h", nvim="0")))
  // A name at the limit is kept.
  let ok = "L".repeat(64)
  let line2 = "{\"t\":\"hello\",\"user\":\"\{ok}\",\"host\":\"h\",\"nvim\":\"0\"}"
  assert_eq(decode_client(line2), Some(Hello(user=ok, host="h", nvim="0")))
}
