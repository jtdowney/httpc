# Streaming branch review

## Blocking

- [x] **`src/gleam_httpc_ffi.erl:42` — raising catch-all silently hangs the consumer.**
      `normalise_error/1` raises inside inets' handler process, where `httpc_response:send/2`
      wraps the receiver MFA in `(catch apply(...))`. The exception is swallowed, no message
      is sent. Verified: `{shutdown,server_closed}`, `{tcp_error,_,_}`, `{ssl_error,_,_}`,
      `closed`, `epipe`, `unknown_encoding`, `body_too_big`,
      `{could_not_establish_ssl_tunnel,_}`, `{failed_connect,[{to_address,_},{tls,_,_}]}`
      all deliver nothing. Only `timeout`, `socket_closed_remotely` and the two-key
      `failed_connect` get through.
      Fix: make the FFI total with a catch-all `HttpError` variant instead of raising.

- [ ] **`gleam.toml:20` — `gleam_erlang >= 0.27.0` is unsatisfiable.**
      New code calls `atom.create` (httpc.gleam:269, 271, 337) and `process.select_record`
      (:335); neither exists before gleam_erlang 1.0. `manifest.toml` pins 1.3.0 so local
      builds pass, but a downstream resolver landing on 0.x gets `Unknown function
      select_record` inside gleam_httpc.
      Fix: raise the floor to `>= 1.0.0`.

- [ ] **`src/gleam/httpc.gleam:22` — new `HttpError` variant is a breaking change.**
      `SocketClosedRemotely` breaks every exhaustive downstream `case`. CHANGELOG.md:13
      shows v5.0.0 was a major bump for adding `ResponseTimeout` to this same type;
      gleam.toml:2 is still 5.0.0 and CHANGELOG.md:8 lists it as a plain addition.
      Also changes the sync API silently: `httpc.send` on a truncated response goes from
      raising `{unexpected_httpc_error, socket_closed_remotely}` to returning
      `Error(SocketClosedRemotely)`.
      Fix: major bump, and note the sync behaviour change in the CHANGELOG.

## Docs

- [ ] **`README.md:83` — the only streaming example doesn't compile.**
      `httpc.CompleteResponse(_id, _stream, _response)` passes 3 patterns to a 2-field
      constructor (httpc.gleam:246). README.md:49 also imports `gleam/function`, unused.
      Tests get it right, so only the README drifted; nothing in CI compiles README snippets.

- [ ] **`src/gleam/httpc.gleam:256` — backpressure claim is inaccurate.**
      "No part of the body is read until it is asked for" is false for body bytes arriving
      in the same socket read as the headers (httpc_handler.erl:1019, :999, :1095).
      For a small response StreamStart/StreamChunk/StreamEnd can all arrive before any pull.
      Fix: soften to "after the first socket read, no further bytes are read until asked for."

- [ ] **`src/gleam/httpc.gleam:318` — `cancel_stream` sends no terminal message.**
      httpc_handler.erl:479-484 sets `from = answer_sent` and stops; both send paths are
      guarded on `From =/= answer_sent`, so nothing is ever delivered. A consumer written
      like the README's `handle_stream` blocks in `selector_receive_forever` permanently.
      Cancel is also best-effort and a two-hop cast, so in-flight chunks still arrive.
      Doc states neither.

## Leaks and robustness

- [ ] **`src/gleam/httpc.gleam:263` — abandoned stream pins a handler + socket.**
      With `{self, once}` and `once = inactive`, `next_body_chunk` parks the handler with
      the socket de-activated (httpc_handler.erl:1550-1553). Only the request timeout frees
      it, and it's cancelled solely in `answer_request`, never reached while parked. Nothing
      monitors the receiver. A consumer that crashes or just reads headers holds a handler,
      socket and server connection for the full timeout — 10 minutes with the README's own
      `httpc.timeout(600_000)`. Nothing documents that `cancel_stream` is mandatory here.

- [ ] **`src/gleam/httpc.gleam:268` — one leaked process alias per stream request.**
      `request_options_defaults()` (httpc.erl:1535) creates `alias()` at :1606 and is
      re-evaluated per request. The sync clause unaliases on every exit path; the async
      clause (:1331-1332) does not. `dispatch_stream_bits` is the only async caller here,
      so a long-lived worker accumulates aliases monotonically.

- [ ] **`src/gleam_httpc_ffi.erl:9` — `http_message/1` is partial.**
      Five clauses, no catch-all; an unmodelled ReplyInfo shape is a `function_clause`
      swallowed by the same `(catch apply(...))`. Verified `{Id, stream_start, Headers}`
      and `{Id, saved_to_file}` deliver nothing. Unreachable today, but inets has reshaped
      these messages before. `headers/1` is likewise partial on non-`{K,V}` terms.

- [ ] **`src/gleam/httpc.gleam:310` — `receive_next_chunk_as_message` is a silent no-op.**
      `gen_server:cast` to a dead pid returns `ok`, and `StreamEnd`/`StreamError` both hand
      back a `stream:` whose handler has already stopped — inviting the call. The natural
      symmetric loop arms nothing and blocks forever; `-> Nil` can't represent the failure.
      Fix: drop `stream` from the terminal variants, or document that it's the handler pid.

- [ ] **`src/gleam_httpc_ffi.erl:18` — FFI hand-builds the Response record.**
      `{response, Status, headers(Headers), Body}` duplicates httpc.gleam:151-152's
      type-checked `string_header` + `Response(...)`, with no compile-time link to
      `gleam/http/response.Response`. A gleam_http field change keeps `dispatch_bits`
      correct while `CompleteResponse` yields a malformed record.
      Fix: hand the raw inets tuple to Gleam and convert once.

## Tests

- [ ] **`test/gleam_httpc_test.gleam:225` — abandoned streams pollute a shared mailbox.**
      Every test in a gleeunit module shares one process and mailbox (verified).
      `stream_start_test` and `:301` dispatch, take StreamStart, then never pull and never
      cancel — at the 30s timeout httpc delivers `StreamError` into that mailbox. Fires once
      the suite runs past 30s, breaking `:299` and `:324` (both assert an empty mailbox).
      Fix: `cancel_stream` on exit in every streaming test.

- [ ] **`test/mock_server.gleam:104` — `let assert Ok(Nil) = mist.send_chunk(...)` crashes mist.**
      Reproduced on all 4 runs: pattern-match panic plus a supervisor child_terminated report
      after `cancel_stops_the_stream_test` closes the socket. Tests stay green, so it's noise
      that will mask a real failure later — and the cancel path is torn down by a crash
      rather than by the code under test.
      Fix: match on `Error` and stop the loop.

- [ ] **`test/gleam_httpc_test.gleam:296` — cancel test races stream_next against cancel.**
      `cancel_stream` is two casts via httpc_manager; `receive_next_chunk_as_message` on the
      next line is one cast direct to the handler, so it can land first and deliver a chunk.
      Passes today only because `/stream/5/50` sleeps 50ms before chunk 0.
      Fix: drop the `stream_next` line — cancel alone stops the handler.

- [x] **`test/gleam_httpc_test.gleam:274` — only the truncation case that works is covered.**
      Chunked truncation maps to `socket_closed_remotely`, which the new clause handles.
      The Content-Length path becomes `{shutdown, server_closed}` — unmapped, hence the
      silent hang above.
      Fix: add a mock route with an oversized content-length that closes early.
