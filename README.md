# httpc

Bindings to Erlang's built in HTTP client, `httpc`.

[![Package Version](https://img.shields.io/hexpm/v/gleam_httpc)](https://hex.pm/packages/gleam_httpc)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/gleam_httpc/)

```sh
gleam add gleam_httpc@5
```

```gleam
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/result

pub fn send_request() {
  // Prepare a HTTP request record
  let assert Ok(base_req) =
    request.to("https://test-api.service.hmrc.gov.uk/hello/world")

  let req =
    request.prepend_header(base_req, "accept", "application/vnd.hmrc.1.0+json")

  // Send the HTTP request to the server
  use resp <- result.try(httpc.send(req))

  // We get a response record back
  assert resp.status == 200

  let content_type = response.get_header(resp, "content-type")
  assert content_type == Ok("application/json")

  assert resp.body == "{\"message\":\"Hello World\"}"

  Ok(resp)
}
```

## Streaming a response body

`dispatch_stream_bits` returns once the request has been made, and the response
arrives as messages.

```gleam
import gleam/bit_array
import gleam/erlang/process
import gleam/function
import gleam/http/request
import gleam/httpc
import gleam/io

pub fn stream_request() {
  let assert Ok(req) = request.to("https://example.com/a-large-file")

  // The timeout covers the whole stream
  let assert Ok(_id) =
    httpc.configure()
    |> httpc.timeout(600_000)
    |> httpc.dispatch_stream_bits(request.map(req, bit_array.from_string))

  process.new_selector()
  |> httpc.select_http_messages(fn(message) { message })
  |> handle_stream
}

fn handle_stream(selector) {
  case process.selector_receive_forever(selector) {
    // Ask for a chunk, and for another each time one arrives
    httpc.StreamStart(_id, stream, _headers) -> {
      httpc.receive_next_chunk_as_message(stream)
      handle_stream(selector)
    }
    httpc.StreamChunk(_id, stream, data) -> {
      io.println("got " <> bit_array.inspect(data))
      httpc.receive_next_chunk_as_message(stream)
      handle_stream(selector)
    }
    httpc.StreamEnd(_id, _stream, _headers) -> Ok(Nil)
    httpc.StreamError(_id, _stream, error) -> Error(error)
    // Only 200 and 206 responses are streamed
    httpc.CompleteResponse(_id, _stream, _response) -> Ok(Nil)
  }
}
```

## Use with Erlang/OTP versions older than 26.0

Older versions of HTTPC do not verify TLS connections by default, so with them
your connection may not be secure when using this library. Consider upgrading to
a newer version of Erlang/OTP, or using a different HTTP client such as
[hackney](https://github.com/gleam-lang/hackney).
