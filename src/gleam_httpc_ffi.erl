-module(gleam_httpc_ffi).
-export([default_user_agent/0, normalise_error/1, stream_receiver/2,
         cast_http_message/1]).

stream_receiver(ReplyInfo, Owner) ->
    Owner ! {gleam_httpc, http_message(ReplyInfo)},
    ok.

http_message({Id, stream_start, Headers, Pid}) ->
    {stream_start, Id, Pid, headers(Headers)};
http_message({Id, stream, Data}) ->
    {stream_chunk, Id, self(), Data};
http_message({Id, stream_end, Headers}) ->
    {stream_end, Id, self(), headers(Headers)};
http_message({Id, {error, Reason}}) ->
    {stream_error, Id, self(), normalise_error(Reason)};
http_message({Id, {{_Version, Status, _Reason}, Headers, Body}}) ->
    Response = {response, Status, headers(Headers), Body},
    {complete_response, Id, Response}.

cast_http_message({gleam_httpc, Message}) ->
    Message.

headers(Headers) ->
    [{unicode:characters_to_binary(K), unicode:characters_to_binary(V)}
     || {K, V} <- Headers].

normalise_error(Error = {failed_connect, Opts}) ->
    Ipv6 = case lists:keyfind(inet6, 1, Opts) of
        {inet6, _, V1} -> V1;
        _ -> erlang:error({unexpected_httpc_error, Error})
    end,
    Ipv4 = case lists:keyfind(inet, 1, Opts) of
        {inet, _, V2} -> V2;
        _ -> erlang:error({unexpected_httpc_error, Error})
    end,
    {failed_to_connect, normalise_ip_error(Ipv4), normalise_ip_error(Ipv6)};
normalise_error(timeout) -> 
    response_timeout;
normalise_error(socket_closed_remotely) ->
    socket_closed_remotely;
%% The server hung up part way through a content-length delimited body.
normalise_error({shutdown, server_closed}) ->
    socket_closed_remotely;
%% The server sent something that could not be understood as HTTP.
normalise_error({invalid_version, _}) ->
    invalid_response;
normalise_error({invalid_content_length, _}) ->
    invalid_response;
normalise_error({chunk_size, _}) ->
    invalid_response;
normalise_error({header_too_long, _}) ->
    invalid_response;
normalise_error(unknown_encoding) ->
    invalid_response;
normalise_error(Error) ->
    erlang:error({unexpected_httpc_error, Error}).

normalise_ip_error(Code) when is_atom(Code) ->
    {posix, erlang:atom_to_binary(Code)};
normalise_ip_error({tls_alert, {A, B}}) ->
    {tls_alert, erlang:atom_to_binary(A), unicode:characters_to_binary(B)};
normalise_ip_error(Error) ->
    erlang:error({unexpected_httpc_ip_error, Error}).

default_user_agent() ->
    Version =
        case application:get_key(gleam_httpc, vsn) of
            {ok, V} when is_list(V) -> V;
            undefined -> "0.0.0"
        end,
    {"user-agent", "gleam_httpc/" ++ Version}.
