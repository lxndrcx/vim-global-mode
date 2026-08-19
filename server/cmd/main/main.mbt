///|
const USAGE : String =
  #|global-mode-server — one modal state, shared by everyone
  #|
  #|Usage: global-mode-server [options]
  #|
  #|Options:
  #|  --bind ADDR        address to listen on (default 0.0.0.0)
  #|  --port PORT        port for editors (default 7777)
  #|  --http-port PORT   port for the web dashboard (default 7778)
  #|  --no-web           do not serve the dashboard
  #|  --verbose          log connections and mode changes
  #|  --help             show this message

///|
/// A bad command line. Carries just the message, so the user sees a plain
/// sentence rather than a wrapped-and-located internal failure.
suberror ArgError {
  ArgError(String)
}

///|
/// Either something to run, or a message already printed and nothing to do.
enum Parsed {
  Run(Options)
  Done
}

///|
struct Options {
  bind : String
  port : Int
  http_port : Int
  web : Bool
  verbose : Bool
}

///|
/// Parse argv. Unknown or malformed flags are fatal rather than ignored: a
/// silently mistyped port would be a confusing thing to debug.
fn parse_args(argv : ArrayView[String]) -> Parsed raise ArgError {
  let mut bind = "0.0.0.0"
  let mut port = 7777
  let mut http_port = 7778
  let mut web = true
  let mut verbose = false
  let mut i = 0
  fn value(flag : String) -> String raise ArgError {
    i += 1
    guard i < argv.length() else { raise ArgError("\{flag} needs a value") }
    argv[i]
  }

  fn int_value(flag : String) -> Int raise ArgError {
    let raw = value(flag)
    let parsed = @string.parse_int(raw) catch { _ => -1 }
    if parsed > 0 && parsed < 65536 {
      parsed
    } else {
      raise ArgError("\{flag} needs a port between 1 and 65535, got '\{raw}'")
    }
  }

  while i < argv.length() {
    match argv[i] {
      "--bind" => bind = value("--bind")
      "--port" => port = int_value("--port")
      "--http-port" => http_port = int_value("--http-port")
      "--no-web" => web = false
      "--verbose" | "-v" => verbose = true
      "--help" | "-h" => {
        println(USAGE)
        return Done
      }
      other => raise ArgError("unknown option '\{other}' (try --help)")
    }
    i += 1
  }
  if web && port == http_port {
    raise ArgError("--port and --http-port must differ (both are \{port})")
  }
  Run({ bind, port, http_port, web, verbose })
}

///|
async fn main {
  // argv[0] is the executable; the flags start after it.
  let argv = @env.args()
  let parsed = parse_args(argv[1:]) catch {
    ArgError(message) => {
      println("global-mode-server: \{message}")
      return
    }
  }
  guard parsed is Run(options) else { return }
  let hub = @state.Hub::new()
  let editor_addr = @socket.Addr::parse("\{options.bind}:\{options.port}")
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      @editors.serve(hub, editor_addr, verbose=options.verbose)
    })
    if options.web {
      let web_addr = @socket.Addr::parse("\{options.bind}:\{options.http_port}")
      group.spawn_bg(() => @web.serve(hub, web_addr, verbose=options.verbose))
    }
  })
}
