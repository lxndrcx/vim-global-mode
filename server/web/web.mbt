///|
/// The most dashboards we will hold at once. The editor listener has always
/// been capped; this side was not, and `subscribe_dashboard` grows a map.
const MAX_DASHBOARDS : Int = 64

///|
/// Serve the dashboard: a page showing the global mode, who set it, and who is
/// currently subject to it, updated live over a WebSocket.
pub async fn serve(
  hub : @state.Hub,
  addr : @socket.Addr,
  verbose? : Bool = false,
) -> Unit {
  let server = @http.Server(addr)
  @logging.log("global mode: dashboard on http://\{addr}")
  server.run_forever(
    (request, _body, conn) => route(hub, request, conn, verbose~),
    allow_failure=true,
    max_connections=MAX_DASHBOARDS,
  )
}

///|
async fn route(
  hub : @state.Hub,
  request : @http.Request,
  conn : @http.ServerConnection,
  verbose~ : Bool,
) -> Unit {
  // HEAD is answered like GET without a body: browsers, proxies and uptime
  // monitors all issue it, and 405 for a page that plainly exists is wrong.
  let body_wanted = match request.meth {
    Get => true
    Head => false
    _ => {
      conn.send_response(405, "Method Not Allowed")
      conn.end_response()
      return
    }
  }
  // Query strings are irrelevant here, but a browser may still send one.
  let path = match request.path.find("?") {
    Some(i) => request.path[:i].to_owned()
    None => request.path
  }
  match path {
    "/" => {
      conn.send_response(200, "OK", extra_headers={
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store",
        "x-content-type-options": "nosniff",
      })
      if body_wanted {
        conn.write(dashboard_html)
      }
      conn.end_response()
    }
    "/api/state" => {
      conn.send_response(200, "OK", extra_headers={
        "content-type": "application/json",
        "cache-control": "no-store",
        "x-content-type-options": "nosniff",
      })
      if body_wanted {
        conn.write(hub.state_json())
      }
      conn.end_response()
    }
    "/ws" => watch(hub, request, conn, verbose~)
    _ => {
      conn.send_response(404, "Not Found")
      conn.end_response()
    }
  }
}

///|
/// Hold a WebSocket open and push a state snapshot on every change.
///
/// The dashboard is strictly a spectator: inbound frames are read only so the
/// connection notices a close, and are otherwise ignored. Nobody gets to
/// change the global mode from a browser.
async fn watch(
  hub : @state.Hub,
  request : @http.Request,
  conn : @http.ServerConnection,
  verbose~ : Bool,
) -> Unit {
  let ws = @websocket.Conn::from_http_server(request, conn)
  defer ws.close()
  let dashboard = hub.subscribe_dashboard()
  defer hub.unsubscribe_dashboard(dashboard)
  if verbose {
    @logging.log("+ dashboard \{dashboard.id} watching")
  }
  // Send the current state at once, so the page is never briefly blank.
  ws.send_text(hub.state_json())
  @async.with_task_group(group => {
    // The sender is `no_wait`, so it is cancelled once the body below
    // returns. The body reads: it ends when the browser goes away.
    group.spawn_bg(no_wait=true, () => {
      for ;; {
        ws.send_text(dashboard.outbox.get())
      }
    })
    for ;; {
      ws.recv() |> ignore
    }
  })
  if verbose {
    @logging.log("- dashboard \{dashboard.id} closed")
  }
}
