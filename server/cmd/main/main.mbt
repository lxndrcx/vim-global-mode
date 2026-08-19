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
      die(message)
      return
    }
  }
  guard parsed is Run(options) else { return }

  // Resolve both addresses before starting anything. `Addr::parse` raises, and
  // letting that escape prints a bare `InvalidAddr` dump for input as ordinary
  // as `--bind localhost` (not a numeric literal) or `--bind ::1` (which has to
  // be written `[::1]`). Doing it here keeps every bad command line on the same
  // plain-sentence path as the other argument errors.
  let editor_addr = @socket.Addr::parse("\{options.bind}:\{options.port}") catch {
    _ => {
      die(bad_address(options.bind))
      return
    }
  }
  let web_addr = if options.web {
    Some(
      @socket.Addr::parse("\{options.bind}:\{options.http_port}") catch {
        _ => {
          die(bad_address(options.bind))
          return
        }
      },
    )
  } else {
    None
  }
  let hub = @state.Hub::new()

  // Binding can still fail — most often because the port is already taken.
  // Report that as a sentence too, rather than announcing one listener and then
  // dying with an OSError while the other is already serving.
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      @editors.serve(hub, editor_addr, verbose=options.verbose)
    })
    if web_addr is Some(addr) {
      group.spawn_bg(() => @web.serve(hub, addr, verbose=options.verbose))
    }
  }) catch {
    error => die("could not start — \{error}")
  }
}

///|
/// libc `exit`. MoonBit's core has no exit primitive, and returning normally
/// from `main` after an error would report success — leaving a supervisor, a
/// shell script or CI unable to tell that the server never started.
extern "C" fn c_exit(code : Int) -> Unit = "exit"

///|
/// Report a fatal problem in one plain sentence and exit non-zero.
fn die(message : String) -> Unit {
  @logging.log("global-mode-server: \{message}")
  c_exit(1)
}

///|
fn bad_address(bind : String) -> String {
  "'\{bind}' is not an address I can bind to — use a numeric address such as 0.0.0.0, 127.0.0.1 or [::1]"
}
