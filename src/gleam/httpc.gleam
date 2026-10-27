import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process
import gleam/http.{type Method}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/list
import gleam/result
import gleam/string
import gleam/uri

pub type HttpError {
  /// The response body contained non-UTF-8 data, but UTF-8 data was expected.
  InvalidUtf8Response
  /// It was not possible to connect to the host.
  FailedToConnect(ip4: ConnectError, ip6: ConnectError)
  /// The response was not received within the configured timeout period.
  ResponseTimeout
  /// The server closed the connection before the response was complete.
  SocketClosedRemotely
  /// The server sent a response that could not be understood as HTTP.
  InvalidResponse
}

pub type ConnectError {
  Posix(code: String)
  TlsAlert(code: String, detail: String)
}

@external(erlang, "gleam_httpc_ffi", "default_user_agent")
fn default_user_agent() -> #(Charlist, Charlist)

@external(erlang, "gleam_httpc_ffi", "normalise_error")
fn normalise_error(error: Dynamic) -> HttpError

type ErlHttpOption {
  Ssl(List(ErlSslOption))
  Autoredirect(Bool)
  Timeout(Int)
}

type BodyFormat {
  Binary
}

type ErlOption {
  BodyFormat(BodyFormat)
  SocketOpts(List(SocketOpt))
  Ipv6HostWithBrackets(Bool)
  Sync(Bool)
  Stream(#(atom.Atom, atom.Atom))
  Receiver(#(atom.Atom, atom.Atom, List(process.Pid)))
}

type SocketOpt {
  Ipfamily(Inet6fb4)
}

type Inet6fb4 {
  Inet6fb4
}

type ErlSslOption {
  Verify(ErlVerifyOption)
}

type ErlVerifyOption {
  VerifyNone
}

@external(erlang, "httpc", "request")
fn erl_request(
  a: Method,
  b: #(Charlist, List(#(Charlist, Charlist)), Charlist, BitArray),
  c: List(ErlHttpOption),
  d: List(ErlOption),
) -> Result(
  #(#(Charlist, Int, Charlist), List(#(Charlist, Charlist)), BitArray),
  Dynamic,
)

@external(erlang, "httpc", "request")
fn erl_request_no_body(
  a: Method,
  b: #(Charlist, List(#(Charlist, Charlist))),
  c: List(ErlHttpOption),
  d: List(ErlOption),
) -> Result(
  #(#(Charlist, Int, Charlist), List(#(Charlist, Charlist)), BitArray),
  Dynamic,
)

/// `gleam/uri` parses IPv6 hosts without their surrounding brackets, but
/// Erlang's httpc requires them to be present in the URL.
///
fn bracket_ipv6_host(host: String) -> String {
  case host {
    "[" <> _ -> host
    _ ->
      case string.contains(host, ":") {
        True -> "[" <> host <> "]"
        False -> host
      }
  }
}

fn string_header(header: #(Charlist, Charlist)) -> #(String, String) {
  let #(k, v) = header
  #(charlist.to_string(k), charlist.to_string(v))
}

// TODO: refine error type
/// Send a HTTP request of binary data using the default configuration.
///
/// If you wish to use some other configuration use `dispatch_bits` instead.
///
pub fn send_bits(
  req: Request(BitArray),
) -> Result(Response(BitArray), HttpError) {
  configure()
  |> dispatch_bits(req)
}

// TODO: refine error type
/// Send a HTTP request of binary data.
///
pub fn dispatch_bits(
  config: Configuration,
  req: Request(BitArray),
) -> Result(Response(BitArray), HttpError) {
  let url = erl_url(req)
  let headers = prepare_headers(req.headers)
  let http_options = erl_http_options(config)
  let options = base_erl_options()

  use response <- result.try(
    case method_has_body(req.method) {
      False ->
        erl_request_no_body(req.method, #(url, headers), http_options, options)
      True ->
        erl_request(
          req.method,
          #(url, headers, erl_content_type(req), req.body),
          http_options,
          options,
        )
    }
    |> result.map_error(normalise_error),
  )

  let #(#(_version, status, _status), headers, resp_body) = response
  Ok(Response(status, list.map(headers, string_header), resp_body))
}

fn base_erl_options() -> List(ErlOption) {
  [
    BodyFormat(Binary),
    SocketOpts([Ipfamily(Inet6fb4)]),
    Ipv6HostWithBrackets(True),
  ]
}

fn erl_url(req: Request(BitArray)) -> Charlist {
  req
  |> request.set_host(bracket_ipv6_host(req.host))
  |> request.to_uri
  |> uri.to_string
  |> charlist.from_string
}

fn erl_content_type(req: Request(BitArray)) -> Charlist {
  req
  |> request.get_header("content-type")
  |> result.unwrap("application/octet-stream")
  |> charlist.from_string
}

fn erl_http_options(config: Configuration) -> List(ErlHttpOption) {
  let options = [
    Autoredirect(config.follow_redirects),
    Timeout(config.timeout),
  ]
  case config.verify_tls {
    True -> options
    False -> [Ssl([Verify(VerifyNone)]), ..options]
  }
}

fn method_has_body(method: Method) -> Bool {
  case method {
    http.Options | http.Head | http.Get -> False
    http.Post
    | http.Put
    | http.Delete
    | http.Trace
    | http.Connect
    | http.Patch
    | http.Other(_) -> True
  }
}

@external(erlang, "httpc", "request")
fn erl_stream_request(
  a: Method,
  b: #(Charlist, List(#(Charlist, Charlist)), Charlist, BitArray),
  c: List(ErlHttpOption),
  d: List(ErlOption),
) -> Result(RequestId, Dynamic)

@external(erlang, "httpc", "request")
fn erl_stream_request_no_body(
  a: Method,
  b: #(Charlist, List(#(Charlist, Charlist))),
  c: List(ErlHttpOption),
  d: List(ErlOption),
) -> Result(RequestId, Dynamic)

@external(erlang, "gleam_httpc_ffi", "cast_http_message")
fn cast_http_message(message: Dynamic) -> HttpMessage

/// Identifies a streaming request, so that messages from different requests
/// can be told apart.
///
pub type RequestId

/// A streamed response body, used to ask for the next chunk.
///
pub type Stream

/// Messages that can be sent by a streaming request to the process that
/// started it.
///
pub type HttpMessage {
  /// The response headers have been received and the body will follow.
  StreamStart(id: RequestId, stream: Stream, headers: List(#(String, String)))
  /// A piece of the response body has been received. There is no guarantee
  /// that a chunk is a valid UTF-8 string.
  StreamChunk(id: RequestId, stream: Stream, data: BitArray)
  /// The response body is complete. Chunked encoding can add headers, so
  /// there may be more here than in `StreamStart`.
  StreamEnd(id: RequestId, stream: Stream, headers: List(#(String, String)))
  /// An error has occurred and the request has stopped.
  StreamError(id: RequestId, stream: Stream, error: HttpError)
  /// The whole response has been received at once, as only 200 and 206
  /// responses are streamed. No further messages follow.
  CompleteResponse(id: RequestId, response: Response(BitArray))
}

/// Send a HTTP request of binary data, receiving the response body as
/// messages rather than all at once.
///
/// Returns once the request has been made, without waiting for the response.
/// Messages are sent to the process that called this function and can be
/// received with the `select_http_messages` function.
///
/// No part of the body is read until it is asked for with the
/// `receive_next_chunk_as_message` function, so a fast server will not
/// overwhelm a slow consumer.
///
/// Note the timeout applies to the whole request rather than to each chunk,
/// so a long running stream needs a long timeout.
///
pub fn dispatch_stream_bits(
  config: Configuration,
  req: Request(BitArray),
) -> Result(RequestId, HttpError) {
  let options = [
    Sync(False),
    Stream(#(atom.create("self"), atom.create("once"))),
    Receiver(
      #(atom.create("gleam_httpc_ffi"), atom.create("stream_receiver"), [
        process.self(),
      ]),
    ),
    ..base_erl_options()
  ]

  let url = erl_url(req)
  let headers = prepare_headers(req.headers)
  let http_options = erl_http_options(config)

  case method_has_body(req.method) {
    False ->
      erl_stream_request_no_body(
        req.method,
        #(url, headers),
        http_options,
        options,
      )
    True ->
      erl_stream_request(
        req.method,
        #(url, headers, erl_content_type(req), req.body),
        http_options,
        options,
      )
  }
  |> result.map_error(normalise_error)
}

@external(erlang, "httpc", "stream_next")
fn erl_stream_next(stream: Stream) -> atom.Atom

/// Ask for the next chunk of a streamed response body, which will be sent as
/// a message to the process that started the request.
///
/// This permits one read of the socket rather than one message, so a single
/// call may be answered by a `Chunk` and a `StreamEnd` together.
///
pub fn receive_next_chunk_as_message(stream: Stream) -> Nil {
  let _ = erl_stream_next(stream)
  Nil
}

@external(erlang, "httpc", "cancel_request")
fn erl_cancel_request(id: RequestId) -> atom.Atom

/// Stop a streaming request, discarding the rest of the response.
///
pub fn cancel_stream(id: RequestId) -> Nil {
  let _ = erl_cancel_request(id)
  Nil
}

/// Configure a selector to receive messages from streaming HTTP requests.
///
/// This will receive messages from all streaming requests that the process has
/// started, rather than any specific one. Each message carries the id of the
/// request that sent it.
///
pub fn select_http_messages(
  selector: process.Selector(t),
  mapping: fn(HttpMessage) -> t,
) -> process.Selector(t) {
  process.select_record(
    selector,
    tag: atom.create("gleam_httpc"),
    fields: 1,
    mapping: fn(message) { mapping(cast_http_message(message)) },
  )
}

/// Configuration that can be used to send HTTP requests.
///
/// To be used with `dispatch`, `dispatch_bits` and `dispatch_stream_bits`.
///
pub opaque type Configuration {
  Builder(
    /// Whether to verify the TLS certificate of the server.
    ///
    /// This defaults to `True`, meaning that the TLS certificate will be verified
    /// unless you call this function with `False`.
    ///
    /// Setting this to `False` can make your application vulnerable to
    /// man-in-the-middle attacks and other security risks. Do not do this unless
    /// you are sure and you understand the risks.
    ///
    verify_tls: Bool,
    /// Whether to follow redirects.
    ///
    follow_redirects: Bool,
    /// Timeout for the request in milliseconds.
    ///
    timeout: Int,
  )
}

/// Create a new configuration with the default settings.
///
/// # Defaults
///
/// - TLS is verified.
/// - Redirects are not followed.
/// - The timeout for the response to be received is 30 seconds from when the
///   request is sent.
///
pub fn configure() -> Configuration {
  Builder(verify_tls: True, follow_redirects: False, timeout: 30_000)
}

/// Set whether to verify the TLS certificate of the server.
///
/// This defaults to `True`, meaning that the TLS certificate will be verified
/// unless you call this function with `False`.
///
/// Setting this to `False` can make your application vulnerable to
/// man-in-the-middle attacks and other security risks. Do not do this unless
/// you are sure and you understand the risks.
///
pub fn verify_tls(config: Configuration, which: Bool) -> Configuration {
  Builder(..config, verify_tls: which)
}

/// Set whether redirects should be followed automatically.
pub fn follow_redirects(config: Configuration, which: Bool) -> Configuration {
  Builder(..config, follow_redirects: which)
}

/// Set the timeout in milliseconds, the default being 30 seconds.
///
/// If the response is not recieved within this amount of time then the
/// client disconnects and an error is returned.
///
/// The timeout applies to the whole request, so a streamed response body has
/// to arrive in full within it.
///
pub fn timeout(config: Configuration, timeout: Int) -> Configuration {
  Builder(..config, timeout:)
}

/// Send a HTTP request of unicode data.
///
pub fn dispatch(
  config: Configuration,
  request: Request(String),
) -> Result(Response(String), HttpError) {
  let request = request.map(request, bit_array.from_string)
  use resp <- result.try(dispatch_bits(config, request))

  case bit_array.to_string(resp.body) {
    Ok(body) -> Ok(response.set_body(resp, body))
    Error(_) -> Error(InvalidUtf8Response)
  }
}

// TODO: refine error type
/// Send a HTTP request of unicode data using the default configuration.
///
/// If you wish to use some other configuration use `dispatch` instead.
///
pub fn send(req: Request(String)) -> Result(Response(String), HttpError) {
  configure()
  |> dispatch(req)
}

fn prepare_headers(
  headers: List(#(String, String)),
) -> List(#(Charlist, Charlist)) {
  prepare_headers_loop(headers, [], False)
}

fn prepare_headers_loop(
  in: List(#(String, String)),
  out: List(#(Charlist, Charlist)),
  user_agent_set: Bool,
) -> List(#(Charlist, Charlist)) {
  case in {
    [] if user_agent_set -> out
    [] -> [default_user_agent(), ..out]
    [#(k, v), ..in] -> {
      let user_agent_set = user_agent_set || k == "user-agent"
      let out = [#(charlist.from_string(k), charlist.from_string(v)), ..out]
      prepare_headers_loop(in, out, user_agent_set)
    }
  }
}
