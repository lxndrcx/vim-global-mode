///|
/// The eight modes that may exist globally. Neovim's transitional modes
/// (operator-pending, `ni*`) are dropped client-side and never reach the wire,
/// so they deliberately have no representation here. See neovim#22263.
pub(all) enum Mode {
  Normal
  Insert
  Visual
  VisualLine
  VisualBlock
  Replace
  Cmdline
  Terminal
} derive(Eq, Debug, ToJson)

///|
/// Parse a mode as it appears on the wire. Anything unrecognised is rejected
/// rather than coerced, so a buggy client cannot invent a ninth mode.
pub fn Mode::of_wire(s : String) -> Mode? {
  match s {
    "n" => Some(Normal)
    "i" => Some(Insert)
    "v" => Some(Visual)
    "V" => Some(VisualLine)
    "b" => Some(VisualBlock)
    "R" => Some(Replace)
    "c" => Some(Cmdline)
    "t" => Some(Terminal)
    _ => None
  }
}

///|
pub fn Mode::to_wire(self : Mode) -> String {
  match self {
    Normal => "n"
    Insert => "i"
    Visual => "v"
    VisualLine => "V"
    VisualBlock => "b"
    Replace => "R"
    Cmdline => "c"
    Terminal => "t"
  }
}

///|
/// Human-readable name, used by the dashboard.
pub fn Mode::label(self : Mode) -> String {
  match self {
    Normal => "NORMAL"
    Insert => "INSERT"
    Visual => "VISUAL"
    VisualLine => "V-LINE"
    VisualBlock => "V-BLOCK"
    Replace => "REPLACE"
    Cmdline => "COMMAND"
    Terminal => "TERMINAL"
  }
}

///|
/// A message from an editor to the server.
pub(all) enum ClientMsg {
  Hello(user~ : String, host~ : String, nvim~ : String)
  SetMode(mode~ : Mode)
  Pong
} derive(Eq, Debug)

///|
/// Decode one newline-delimited JSON line sent by an editor.
///
/// Returns None for anything malformed, unknown, or carrying an invalid mode.
/// A joke plugin still should not fall over because someone typed netcat at it.
pub fn decode_client(line : String) -> ClientMsg? {
  let json = @json.parse(line) catch { _ => return None }
  guard json is Object(fields) else { return None }
  guard fields.get("t") is Some(String(t)) else { return None }
  match t {
    "hello" => {
      let user = str_field(fields, "user", "anon")
      let host = str_field(fields, "host", "?")
      let nvim = str_field(fields, "nvim", "?")
      Some(Hello(user~, host~, nvim~))
    }
    "mode" => {
      guard fields.get("mode") is Some(String(m)) else { return None }
      guard Mode::of_wire(m) is Some(mode) else { return None }
      Some(SetMode(mode~))
    }
    "pong" => Some(Pong)
    _ => None
  }
}

///|
/// The longest name or hostname we will store. Generous for a username, and it
/// bounds what gets copied into every roster frame and state snapshot.
const MAX_FIELD_UNITS : Int = 64

///|
/// True if this string can be encoded as UTF-8.
///
/// MoonBit strings are sequences of UTF-16 code units, and JSON may legally
/// carry an unpaired surrogate -- `"\ud800"` parses fine. Encoding one calls
/// `abort`, which is a process-level panic rather than a catchable error, so a
/// single `hello` frame carrying such a name took the entire server down for
/// everybody on the first broadcast that touched it. There is nowhere further
/// downstream to defend this, so such a name is refused on the way in and the
/// default is stored instead -- the frame itself is still accepted.
fn is_encodable(s : String) -> Bool {
  let n = s.length()
  let mut i = 0
  while i < n {
    guard s.get(i) is Some(unit) else { return false }
    let c = unit.to_int()
    if c >= 0xD800 && c <= 0xDBFF {
      // A high surrogate is only valid immediately followed by a low one.
      guard i + 1 < n && s.get(i + 1) is Some(next) else { return false }
      let d = next.to_int()
      if d < 0xDC00 || d > 0xDFFF {
        return false
      }
      i += 2
    } else if c >= 0xDC00 && c <= 0xDFFF {
      return false
    } else {
      i += 1
    }
  }
  true
}

///|
/// Read a string field, falling back to `default` if it is missing, too long,
/// or not encodable.
fn str_field(
  fields : Map[String, Json],
  key : String,
  default : String,
) -> String {
  match fields.get(key) {
    Some(String(s)) =>
      if s.length() <= MAX_FIELD_UNITS && is_encodable(s) {
        s
      } else {
        default
      }
    _ => default
  }
}

///|
/// One connected editor, as advertised to other clients and the dashboard.
pub(all) struct Peer {
  id : String
  user : String
  host : String
} derive(Eq, Debug)

///|
fn Peer::to_json(self : Peer) -> Json {
  {
    "id": self.id.to_json(),
    "user": self.user.to_json(),
    "host": self.host.to_json(),
  }
}

///|
/// Encode `welcome`: sent once, immediately after a client connects.
pub fn encode_welcome(
  id : String,
  mode : Mode,
  seq : Int64,
  by : String,
) -> String {
  line({
    "t": "welcome".to_json(),
    "id": id.to_json(),
    "mode": mode.to_wire().to_json(),
    "seq": seq.to_double().to_json(),
    "by": by.to_json(),
  })
}

///|
/// Encode a global mode change. `by_id` lets a client recognise its own change
/// if the server ever echoes one back; today it never does.
pub fn encode_mode(
  mode : Mode,
  seq : Int64,
  by : String,
  by_id : String,
) -> String {
  line({
    "t": "mode".to_json(),
    "mode": mode.to_wire().to_json(),
    "seq": seq.to_double().to_json(),
    "by": by.to_json(),
    "by_id": by_id.to_json(),
  })
}

///|
/// Encode the roster of connected editors.
pub fn encode_roster(peers : Array[Peer]) -> String {
  line({
    "t": "roster".to_json(),
    "clients": Json::array(peers.map(Peer::to_json)),
  })
}

///|
/// Encode a heartbeat.
///
/// It carries the authoritative mode as well, so an editor that has drifted
/// out of step — because a frame was discarded from its outbox, because two
/// changes raced, or because an apply was dropped — is corrected on the next
/// beat instead of staying wrong forever. There is no other resync path.
pub fn encode_ping(mode : Mode, seq : Int64, by : String) -> String {
  line({
    "t": "ping".to_json(),
    "mode": mode.to_wire().to_json(),
    "seq": seq.to_double().to_json(),
    "by": by.to_json(),
  })
}

///|
/// The full server state, as the dashboard and `GET /api/state` want it.
pub fn encode_state(
  mode : Mode,
  seq : Int64,
  by : String,
  peers : Array[Peer],
) -> String {
  Json::object({
    "t": "state".to_json(),
    "mode": mode.to_wire().to_json(),
    "label": mode.label().to_json(),
    "seq": seq.to_double().to_json(),
    "by": by.to_json(),
    "clients": Json::array(peers.map(Peer::to_json)),
  }).stringify()
}

///|
/// Serialise to a single line. The trailing newline *is* the framing, so it is
/// added here rather than at every call site where it could be forgotten.
fn line(fields : Map[String, Json]) -> String {
  Json::object(fields).stringify() + "\n"
}
