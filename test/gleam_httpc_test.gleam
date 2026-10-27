import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/dict
import gleam/erlang/process
import gleam/function
import gleam/http.{Get, Head, Options}
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/httpc
import gleam/list
import gleam/string
import gleeunit
import mock_server

pub fn main() {
  mock_server.start()
  gleeunit.main()
}

fn stream_request(path: String) -> Request(BitArray) {
  let assert Ok(req) = request.to(mock_server.url(path))
  request.map(req, bit_array.from_string)
}

fn stream_selector() -> process.Selector(httpc.HttpMessage) {
  process.new_selector()
  |> httpc.select_http_messages(function.identity)
}

fn collect_stream(
  selector: process.Selector(httpc.HttpMessage),
  body: BytesTree,
) -> BitArray {
  let assert Ok(message) = process.selector_receive(selector, 5000)
  case message {
    httpc.StreamChunk(_id, stream, data) -> {
      httpc.receive_next_chunk_as_message(stream)
      collect_stream(selector, bytes_tree.append(body, data))
    }
    httpc.StreamEnd(_id, _stream, _headers) -> bytes_tree.to_bit_array(body)
    httpc.StreamStart(_id, _stream, _headers) ->
      panic as "unexpected second stream start"
    httpc.CompleteResponse(_id, _response) ->
      panic as "unexpected complete response mid-stream"
    httpc.StreamError(_id, _stream, _error) ->
      panic as "stream failed before it ended"
  }
}

fn drain_to_stream_error(
  selector: process.Selector(httpc.HttpMessage),
) -> httpc.HttpError {
  let assert Ok(message) = process.selector_receive(selector, 5000)
  case message {
    httpc.StreamChunk(_id, stream, _data) -> {
      httpc.receive_next_chunk_as_message(stream)
      drain_to_stream_error(selector)
    }
    httpc.StreamError(_id, _stream, error) -> error
    httpc.StreamStart(_id, _stream, _headers) ->
      panic as "unexpected second stream start"
    httpc.StreamEnd(_id, _stream, _headers) ->
      panic as "stream ended cleanly, expected an error"
    httpc.CompleteResponse(_id, _response) ->
      panic as "unexpected complete response mid-stream"
  }
}

pub fn request_test() {
  let req =
    request.new()
    |> request.set_method(Get)
    |> request.set_scheme(http.Http)
    |> request.set_host("localhost")
    |> request.set_port(mock_server.http_port())
    |> request.set_path("/")
    |> request.prepend_header("accept", "text/plain")

  let assert Ok(http_resp) = httpc.send(req)
  assert http_resp.status == 200
  assert response.get_header(http_resp, "content-type")
    == Ok("application/json")

  let resp = mock_server.decode_response(http_resp.body)
  assert resp.method == "GET"
  assert resp.path == "/"
  assert dict.get(resp.headers, "accept") == Ok("text/plain")
}

pub fn get_request_discards_body_test() {
  let assert Ok(req) = request.to(mock_server.url("/"))
  let req = request.set_body(req, "This gets dropped")

  let assert Ok(http_resp) = httpc.send(req)
  assert http_resp.status == 200

  let resp = mock_server.decode_response(http_resp.body)
  assert resp.method == "GET"
  assert resp.path == "/"
  assert resp.body == ""
}

pub fn head_request_discards_body_test() {
  let assert Ok(req) = request.to(mock_server.url("/"))
  let req =
    req
    |> request.set_method(Head)
    |> request.set_body("This gets dropped")

  let assert Ok(resp) = httpc.send(req)
  assert resp.status == 200
  assert resp.body == ""
}

pub fn options_request_discards_body_test() {
  let assert Ok(req) = request.to(mock_server.url("/"))
  let req =
    req
    |> request.set_method(Options)
    |> request.set_body("This gets dropped")

  let assert Ok(http_resp) = httpc.send(req)
  assert http_resp.status == 200

  let resp = mock_server.decode_response(http_resp.body)
  assert resp.method == "OPTIONS"
  assert resp.path == "/"
  assert resp.body == ""
}

pub fn invalid_tls_test() {
  let assert Ok(req) = request.to("https://expired.badssl.com")

  // This will fail because of invalid TLS
  let assert Error(httpc.FailedToConnect(
    ip4: httpc.TlsAlert("certificate_expired", _),
    ip6: _,
  )) = httpc.send(req)

  // This will fail because of invalid TLS
  let assert Error(httpc.FailedToConnect(
    ip4: httpc.TlsAlert("certificate_expired", _),
    ip6: _,
  )) =
    httpc.configure()
    |> httpc.verify_tls(True)
    |> httpc.dispatch(req)

  let assert Ok(response) =
    httpc.configure()
    |> httpc.verify_tls(False)
    |> httpc.dispatch(req)
  assert 200 == response.status
}

pub fn ipv6_test() {
  let assert Ok(req) = request.to(mock_server.ipv6_url("/"))
  let assert Ok(http_resp) = httpc.send(req)
  assert 200 == http_resp.status

  let resp = mock_server.decode_response(http_resp.body)
  assert resp.path == "/"
}

pub fn follow_redirects_option_test() {
  let assert Ok(req) = request.to(mock_server.url("/redirect"))

  let assert Ok(http_resp) = httpc.send(req)
  assert http_resp.status == 308

  let assert Ok(http_resp) =
    httpc.configure()
    |> httpc.follow_redirects(False)
    |> httpc.dispatch(req)
  assert http_resp.status == 308

  let assert Ok(http_resp) =
    httpc.configure()
    |> httpc.follow_redirects(True)
    |> httpc.dispatch(req)
  assert http_resp.status == 200

  let resp = mock_server.decode_response(http_resp.body)
  assert resp.path == "/redirected"
}

pub fn default_user_agent_test() {
  let assert Ok(req) = request.to(mock_server.url("/"))
  let assert Ok(http_resp) = httpc.send(req)

  let resp = mock_server.decode_response(http_resp.body)
  let assert Ok(user_agent) = dict.get(resp.headers, "user-agent")
  assert string.starts_with(user_agent, "gleam_httpc/")
}

pub fn custom_user_agent_test() {
  let assert Ok(req) = request.to(mock_server.url("/"))
  let assert Ok(http_resp) =
    httpc.send(request.set_header(req, "user-agent", "gleam-test"))

  let resp = mock_server.decode_response(http_resp.body)
  assert dict.get(resp.headers, "user-agent") == Ok("gleam-test")
}

pub fn timeout_success_test() {
  let assert Ok(req) = request.to(mock_server.url("/delay/100"))

  let assert Ok(http_resp) =
    httpc.configure()
    |> httpc.timeout(500)
    |> httpc.dispatch(req)

  assert http_resp.status == 200
}

pub fn timeout_error_test() {
  let assert Ok(req) = request.to(mock_server.url("/delay/500"))

  assert httpc.configure()
    |> httpc.timeout(200)
    |> httpc.dispatch(req)
    == Error(httpc.ResponseTimeout)
}

pub fn truncated_content_length_test() {
  let assert Ok(req) = request.to(mock_server.truncated_url())

  assert httpc.send(req) == Error(httpc.SocketClosedRemotely)
}

pub fn malformed_response_test() {
  let assert Ok(req) = request.to(mock_server.garbage_url())

  assert httpc.send(req) == Error(httpc.InvalidResponse)
}

pub fn stream_start_test() {
  let req = stream_request("/stream/3/50")

  let assert Ok(request_id) =
    httpc.configure()
    |> httpc.dispatch_stream_bits(req)

  let assert Ok(httpc.StreamStart(id, _stream, headers)) =
    process.selector_receive(stream_selector(), 5000)

  assert id == request_id
  assert list.key_find(headers, "transfer-encoding") == Ok("chunked")
}

pub fn stream_body_arrives_in_chunks_test() {
  let req = stream_request("/stream/3/20")

  let assert Ok(_request_id) =
    httpc.configure()
    |> httpc.dispatch_stream_bits(req)

  let selector = stream_selector()
  let assert Ok(httpc.StreamStart(_id, stream, _headers)) =
    process.selector_receive(selector, 5000)
  httpc.receive_next_chunk_as_message(stream)

  assert collect_stream(selector, bytes_tree.new()) == <<"chunk0chunk1chunk2">>
}

pub fn non_streamed_status_arrives_complete_test() {
  let req = stream_request("/missing")

  let assert Ok(request_id) =
    httpc.configure()
    |> httpc.dispatch_stream_bits(req)

  let assert Ok(httpc.CompleteResponse(id, resp)) =
    process.selector_receive(stream_selector(), 5000)

  assert id == request_id
  assert resp.status == 404
  assert resp.body == <<"not found">>
  assert response.get_header(resp, "content-length") == Ok("9")
}

pub fn stream_dropped_by_server_test() {
  let req = stream_request("/stream-abort/2/20")

  let assert Ok(_request_id) =
    httpc.configure()
    |> httpc.dispatch_stream_bits(req)

  let selector = stream_selector()
  let assert Ok(httpc.StreamStart(_id, stream, _headers)) =
    process.selector_receive(selector, 5000)
  httpc.receive_next_chunk_as_message(stream)

  assert drain_to_stream_error(selector) == httpc.SocketClosedRemotely
}

pub fn cancel_stops_the_stream_test() {
  let req = stream_request("/stream/5/50")

  let assert Ok(request_id) =
    httpc.configure()
    |> httpc.dispatch_stream_bits(req)

  let selector = stream_selector()
  let assert Ok(httpc.StreamStart(_id, stream, _headers)) =
    process.selector_receive(selector, 5000)

  httpc.cancel_stream(request_id)
  httpc.receive_next_chunk_as_message(stream)

  assert process.selector_receive(selector, 500) == Error(Nil)
}

pub fn stream_handle_matches_the_advertised_handler_test() {
  let req = stream_request("/stream/2/20")

  let assert Ok(_request_id) =
    httpc.configure()
    |> httpc.dispatch_stream_bits(req)

  let selector = stream_selector()
  let assert Ok(httpc.StreamStart(_id, stream, _headers)) =
    process.selector_receive(selector, 5000)
  httpc.receive_next_chunk_as_message(stream)

  let assert Ok(httpc.StreamChunk(_id, next_stream, _data)) =
    process.selector_receive(selector, 5000)

  assert stream == next_stream
}

pub fn select_http_messages_leaves_other_messages_alone_test() {
  let subject = process.new_subject()
  process.send(subject, "not for httpc")

  assert process.selector_receive(stream_selector(), 100) == Error(Nil)
  assert process.receive(subject, 100) == Ok("not for httpc")
}

pub fn stream_request_with_body_test() {
  let req =
    stream_request("/stream/2/20")
    |> request.set_method(http.Post)
    |> request.set_body(<<"posted">>)

  let assert Ok(_request_id) =
    httpc.configure()
    |> httpc.dispatch_stream_bits(req)

  let selector = stream_selector()
  let assert Ok(httpc.StreamStart(_id, stream, _headers)) =
    process.selector_receive(selector, 5000)
  httpc.receive_next_chunk_as_message(stream)

  assert collect_stream(selector, bytes_tree.new()) == <<"postedchunk0chunk1">>
}
