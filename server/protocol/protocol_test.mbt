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
    encode_welcome("c1", Normal, 0, "server"),
    encode_mode(Insert, 7, "alex", "c1"),
    encode_roster([{ id: "c1", user: "alex", host: "thinkpad" }]),
    encode_ping(),
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
    encode_state(VisualBlock, 3, "alex", [
      { id: "c1", user: "alex", host: "thinkpad" },
    ]),
  )
  guard json is Object(fields) else { fail("state did not parse") }
  assert_eq(fields.get("mode"), Some(Json::string("b")))
  assert_eq(fields.get("label"), Some(Json::string("V-BLOCK")))
  assert_eq(fields.get("seq"), Some(Json::number(3)))
}
