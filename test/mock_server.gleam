import gleam/bit_array
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import glisten
import mist.{type Connection, type ResponseData}

pub type MockResponse {
  MockResponse(
    method: String,
    path: String,
    headers: Dict(String, String),
    body: String,
  )
}

pub fn decode_response(body: String) -> MockResponse {
  let decoder = {
    use method <- decode.field("method", decode.string)
    use path <- decode.field("path", decode.string)
    use headers <- decode.field(
      "headers",
      decode.dict(decode.string, decode.string),
    )
    use body <- decode.field("body", decode.string)
    decode.success(MockResponse(method:, path:, headers:, body:))
  }
  let assert Ok(response) = json.parse(from: body, using: decoder)
  response
}

@external(erlang, "persistent_term", "put")
fn pt_put(key: atom.Atom, value: Int) -> Nil

@external(erlang, "persistent_term", "get")
fn pt_get(key: atom.Atom) -> Int

fn test_response(req: Request(Connection)) -> Response(ResponseData) {
  let headers =
    req.headers
    |> list.map(fn(pair) { #(pair.0, json.string(pair.1)) })
    |> json.object

  let request_body = case mist.read_body(req, max_body_limit: 1_000_000) {
    Ok(req) -> bit_array.to_string(req.body) |> result.unwrap("")
    Error(_) -> ""
  }

  let body =
    json.object([
      #("method", json.string(http.method_to_string(req.method))),
      #("path", json.string(req.path)),
      #("headers", headers),
      #("body", json.string(request_body)),
    ])
    |> json.to_string

  response.new(200)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn chunked_response(
  req: Request(Connection),
  count count: Int,
  delay delay: Int,
  abort abort: Bool,
) -> Response(ResponseData) {
  let echoed = case mist.read_body(req, max_body_limit: 1_000_000) {
    Ok(read) -> read.body
    Error(_) -> <<>>
  }

  mist.chunked(
    request: req,
    response: response.new(200),
    init: fn(subject) {
      process.send(subject, Nil)
      #(subject, 0)
    },
    loop: fn(state, _message, connection) {
      let #(subject, sent) = state
      case sent < count {
        False ->
          case abort {
            True -> mist.chunk_stop_abnormal("aborted")
            False -> mist.chunk_stop()
          }
        True -> {
          process.sleep(delay)
          let prefix = case sent {
            0 -> echoed
            _ -> <<>>
          }
          let name = bit_array.from_string("chunk" <> int.to_string(sent))
          let assert Ok(Nil) =
            mist.send_chunk(connection, bit_array.append(prefix, name))
          process.send(subject, Nil)
          mist.chunk_continue(#(subject, sent + 1))
        }
      }
    },
  )
}

fn http_handler(req: Request(Connection)) -> Response(ResponseData) {
  case request.path_segments(req), req.method {
    [], http.Head ->
      response.new(200)
      |> response.set_body(mist.Bytes(bytes_tree.new()))

    [], _ -> test_response(req)

    ["delay", ms_str], _ -> {
      let assert Ok(ms) = int.parse(ms_str)
      process.sleep(ms)
      test_response(req)
    }

    ["redirect"], _ -> {
      let host =
        request.get_header(req, "host")
        |> result.unwrap("localhost")
      response.new(308)
      |> response.set_header("location", "http://" <> host <> "/redirected")
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    }

    ["redirected"], _ -> test_response(req)

    ["stream", count, delay], _ -> {
      let assert Ok(count) = int.parse(count)
      let assert Ok(delay) = int.parse(delay)
      chunked_response(req, count:, delay:, abort: False)
    }

    ["stream-abort", count, delay], _ -> {
      let assert Ok(count) = int.parse(count)
      let assert Ok(delay) = int.parse(delay)
      chunked_response(req, count:, delay:, abort: True)
    }

    _, _ ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("not found")))
  }
}

/// Canned responses that mist cannot produce because it frames its own
/// output. One listener per response, so nothing has to parse the request.
fn start_raw(key: String, response: String) -> Nil {
  let name = process.new_name(key)

  let assert Ok(_) =
    glisten.new(
      fn(_connection) { #(Nil, None) },
      fn(_state, _message, connection) {
        let assert Ok(Nil) =
          glisten.send(connection, bytes_tree.from_string(response))
        glisten.stop()
      },
    )
    |> glisten.with_listener_name(name)
    |> glisten.start(0)

  pt_put(atom.create(key), glisten.get_server_info(name, 5000).port)
}

fn start_http() -> Nil {
  let subj = process.new_subject()

  let assert Ok(_) =
    mist.new(http_handler)
    |> mist.port(0)
    |> mist.with_ipv6
    |> mist.after_start(fn(port, _scheme, _ip) { process.send(subj, port) })
    |> mist.start

  let assert Ok(port) = process.receive(subj, 5000)
  pt_put(atom.create("http_port"), port)
}

pub fn start() -> Nil {
  start_http()
  start_raw(
    "truncated_port",
    "HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\ntruncated",
  )
  start_raw("garbage_port", "this is not an http response\r\n\r\n")
}

pub fn http_port() -> Int {
  pt_get(atom.create("http_port"))
}

pub fn url(path: String) -> String {
  "http://localhost:" <> int.to_string(http_port()) <> path
}

/// A response claiming more body than the server sends before hanging up.
pub fn truncated_url() -> String {
  raw_url("truncated_port")
}

/// A response that is not HTTP at all.
pub fn garbage_url() -> String {
  raw_url("garbage_port")
}

fn raw_url(key: String) -> String {
  "http://localhost:" <> int.to_string(pt_get(atom.create(key))) <> "/"
}

pub fn ipv6_url(path: String) -> String {
  "http://[::1]:" <> int.to_string(http_port()) <> path
}
