%%% ---------------------------------------------------------------------------------
%%% @doc
%%% This module handles building broen requests out of Cowboy data.
%%% @end
%%% ---------------------------------------------------------------------------------
-module(broen_request).

-include_lib("eunit/include/eunit.hrl").

%% API
-export([build_request/3,
         check_http_origin/2]).

-define(XFF_HEADER, <<"x-forwarded-for">>).
-define(XRI_HEADER, <<"x-real-ip">>).
-define(PROTOCOL_HEADER_NAME, <<"x-forwarded-proto">>).
-define(PRIVATE_IP_RANGES, [{{10,0,0,0}, 8}, {{172,16,0,0}, 12}, {{192,168,0,0}, 16}, {{127, 0, 0, 1}, 32}]).

-spec build_request(map(), binary(), list(broen_core:broen_other_key())) -> broen_core:broen_request().
build_request(Req, RoutingKey, AuthData) ->
  {Body, ReadReq} = get_body(Req),
  Request =
    merge_maps([
                 querydata(cowboy_req:qs(ReadReq)),
                 postobj(ReadReq, Body),
                 body(ReadReq, Body),
                 #{
                   protocol => case cowboy_req:header(?PROTOCOL_HEADER_NAME, ReadReq) of
                     <<"https">> -> https;
                     _ -> http
                   end,
                   cookies => maps:from_list(cowboy_req:parse_cookies(ReadReq)),
                   http_headers => cowboy_req:headers(ReadReq),
                   request => cowboy_req:method(ReadReq),
                   method => cowboy_req:method(ReadReq),
                   fullpath => iolist_to_binary(cowboy_req:uri(ReadReq, #{qs => undefined, fragment => undefined})),
                   appmoddata => appmoddata(ReadReq),
                   referer => cowboy_req:header(<<"referer">>, ReadReq),
                   useragent => cowboy_req:header(<<"user-agent">>, ReadReq),
                   client_ip => iolist_to_binary(client_ip(ReadReq)),
                   routing_key => RoutingKey,
                   queryobj => maps:from_list(cowboy_req:parse_qs(Req)),
                   auth_data => AuthData}
               ]),
  maps:map(fun(_K, undefined) -> null;
              (client_data, <<>>) -> null;
              (_K, V) -> V end, Request).

appmoddata(Req) ->
  [First | Rest] = cowboy_req:path_info(Req),
  TrailingSlash = binary:last(cowboy_req:path(Req)) == $/,
  Data = lists:foldl(fun(El, SoFar) -> <<SoFar/binary, "/", El/binary>> end, First, Rest),
  case TrailingSlash of
    true -> <<Data/binary, "/">>;
    false -> Data
  end.


get_body(Req) ->
  case cowboy_req:header(<<"content-type">>, Req) of
    <<"multipart/form-data", _/binary>> ->
      B = get_body_multipart(Req, []),
      B;
    _ ->
      get_body(Req, <<>>)
  end.

get_body_multipart(Req0, Acc) ->
  ok = check_multipart_size(Acc),
  case cowboy_req:read_part(Req0) of
    {ok, Headers, Req1} ->
      {ok, Body, Req} = stream_body(Req1, <<>>),
      get_body_multipart(Req, [{Headers, Body} | Acc]);
    {done, Req} ->
      {{[parse_part(P) || P <- lists:reverse(Acc)]}, Req}
  end.

check_multipart_size(Parts) ->
  {ok, MaxSize} = application:get_env(broen, partial_post_size),
  case lists:foldl(fun({_, B}, Acc) -> Acc + byte_size(B) end, 0, Parts) > MaxSize of
    true -> throw(body_too_large);
    false -> ok
  end.

parse_part({#{<<"content-disposition">> := <<"form-data; ", Rest/binary>>} = M, Body}) ->
  Parts = binary:split(Rest, <<";">>, [global]),
  Parsed = [begin
              Trimmed = trim_part(P),
              NoQuotes = binary:replace(Trimmed, <<"\"">>, <<>>, [global]),
              [K, V] = binary:split(NoQuotes, <<"=">>, [global]),
              {K, V}
            end || P <- Parts],
  {value, {_, Name}, OtherData} = lists:keytake(<<"name">>, 1, Parsed),

  {_, M2} = maps:take(<<"content-disposition">>, M),
  {Name, {[
            {<<"opts">>, {OtherData ++ maps:to_list(M2)}},
            {<<"body">>, Body}

          ]}}.


trim_part(<<" ", Rest/binary>>) -> trim_part(Rest);
trim_part(B)                    -> B.

stream_body(Req0, Acc) ->
  case cowboy_req:read_part_body(Req0) of
    {more, Data, Req} ->
      stream_body(Req, <<Acc/binary, Data/binary>>);
    {ok, Data, Req} ->
      {ok, <<Acc/binary, Data/binary>>, Req}
  end.

get_body(Req0, SoFar) ->
  case cowboy_req:read_body(Req0) of
    {ok, Data, Req} ->
      {<<SoFar/binary, Data/binary>>, Req};
    {more, Data, Req} ->
      get_body(Req, <<SoFar/binary, Data/binary>>)
  end.

-spec check_http_origin(map(), binary() | invalid_route) -> {undefined | binary(), same_origin | allow_origin | unknown_origin}.
check_http_origin(Req, RoutingKey) ->
  Method = cowboy_req:method(Req),
  Origin = cowboy_req:header(<<"origin">>, Req),
  Referer = cowboy_req:header(<<"referer">>, Req),
  UserAgent = cowboy_req:header(<<"user-agent">>, Req),
  {Origin, check_http_origin(Method, Origin, RoutingKey, UserAgent, Referer)}.

check_http_origin(_Method, _Origin, invalid_route, _UserAgent, _Referer)     -> allow_origin;
check_http_origin(_Method, undefined, _RoutingKey, _UserAgent, _Referer)     -> same_origin;  % Not cross-origin request
check_http_origin(<<"GET">>, _Origin, _RoutingKey, _UserAgent, _Referer)     -> allow_origin; % Disregard GET method
check_http_origin(<<"OPTIONS">>, _Origin, _RoutingKey, _UserAgent, _Referer) -> allow_origin; % Disregard OPTIONS method
check_http_origin(Method, Origin, RoutingKey, UserAgent, Referer) ->
  OriginTokens = lists:reverse(parse_uri(Origin)),
  case match_origins(OriginTokens) of
    true ->
      allow_origin;
    false ->
      case match_white_listed_method(RoutingKey, Method) of
        [Method] ->
          allow_origin;
        _ ->
          lager:warning("method: ~s, routing-key: ~s, origin: ~s, user-agent: ~s, referer: ~s",
                        [Method, RoutingKey, Origin, UserAgent, Referer]),
          unknown_origin
      end
  end.

parse_uri(Origin) when is_binary(Origin) ->
  case http_uri:parse(Origin) of
    {ok, Res} -> binary:split(element(3, Res), <<".">>, [global]);
    _ -> binary:split(Origin, [<<":">>, <<".">>], [global])
  end.


%% Internal functions
%% ---------------------------------------------------------------------------------
querydata(<<>>) -> #{};
querydata(Data) -> #{querydata => Data}.

postobj(Req, Body) ->
  case cowboy_req:header(<<"content-type">>, Req) of
    <<"application/x-www-form-urlencoded">> ->
      #{postobj => maps:from_list(cow_qs:parse_qs(Body))};
    _ ->
      #{}
  end.


body(Req, Body) ->
  case cowboy_req:header(<<"content-type">>, Req) of
    <<"multipart/form-data", _/binary>> ->
      #{multipartobj => Body,
        client_data => null};
    _ ->
      #{client_data => Body}
  end.


client_ip(Req) ->
  case {cowboy_req:header(?XFF_HEADER, Req),
        cowboy_req:header(?XRI_HEADER, Req)} of
    {undefined, undefined} ->
      {{IP1, IP2, IP3, IP4}, _} = cowboy_req:peer(Req),
      lists:flatten(io_lib:format("~b.~b.~b.~b", [IP1, IP2, IP3, IP4]));
    {undefined, Ip} ->
      Ip;
    {Ip, _} -> xff_ip(Ip, <<"0.0.0.0">>)
  end.

xff_ip(IpList, Default) when is_binary(IpList) ->
  % get the list of ip address, and return
  % the latest non-private ip - or a bogus address
  % if we cannot find one.
  Ips = [binary:replace(Ip, <<" ">>, <<>>, [global]) ||
         Ip <-  lists:reverse(binary:split(IpList, <<",">>, [trim_all, global]))],
  first_non_private_addr(Ips, Default).

first_non_private_addr([], Default) -> Default;
first_non_private_addr([Ip|Rest], D) ->
  case is_private(Ip) of
    false -> Ip;
    true -> first_non_private_addr(Rest, D)
  end.

is_private(Ip) when is_binary(Ip) ->
  case inet:parse_address(binary_to_list(Ip)) of
    {ok, {_, _, _, _}=Addr} -> is_private(Addr, ?PRIVATE_IP_RANGES);
    {ok, _IPV6Addr} -> false; % TODO: support ipv6?
    {error, einval} -> true % skip non valid ips?
  end.

is_private(_, []) -> false;
is_private(Ip, [Range|Rest]) ->
  case ip_between(Ip, Range) of
    true -> true;
    false -> is_private(Ip, Rest)
  end.

ip_num({A, B, C, D}) ->
  B1 = A bsl 24,
  B2 = B bsl 16,
  B3 = C bsl 8,
  B4 = D,
  B1 + B2 + B3 + B4.

ip_between(Ip, {Network, NetworkBits}) ->
  IpNum = ip_num(Ip),
  NetLow = ip_num(Network),
  BitsHosts = 32 - NetworkBits,
  NetHigh = NetLow + erlang:trunc(math:pow(2, BitsHosts)) - 1,
  IpNum >= NetLow andalso IpNum =< NetHigh.

match_white_listed_method(RoutingKey, Method) ->
  [M || M <- proplists:get_all_values(RoutingKey, application:get_env(broen, cors_white_list, [])),
   M == Method].


match_origins(Origin) ->
  lists:any(fun(AllowedOrigin) -> match_origin(Origin, lists:reverse(AllowedOrigin)) end,
            application:get_env(broen, cors_allowed_origins, [])).


match_origin([Part | Rest], [Part | Rest2]) -> match_origin(Rest, Rest2);
match_origin(_, [])                         -> true;
match_origin(_, _)                          -> false.


merge_maps(Maps) -> merge_maps(Maps, #{}).

merge_maps([H | T], Acc) -> merge_maps(T, maps:merge(H, Acc));
merge_maps([], Acc)      -> Acc.

%% Unit tests
%% ---------------------------------------------------------------------------------
cors_bin_test_() ->
  application:set_env(broen, cors_allowed_origins, [
    [<<"test">>, <<"com">>],
    [<<"test2">>, <<"com">>],
    [<<"sub">>, <<"test3">>, <<"com">>]
  ]),
  application:set_env(broen, cors_white_list, [
    {<<"allowed.route">>, <<"PUT">>}
  ]),
  fun() ->
    ?assertMatch(allow_origin, check_http_origin(<<"GET">>, <<"http://www.any-origin.com">>, <<"some.route">>, "", "")),
    ?assertMatch(allow_origin, check_http_origin(<<"POST">>, <<"http://www.test.com">>, <<"some.route">>, "", "")),
    ?assertMatch(allow_origin, check_http_origin(<<"DELETE">>, <<"http://www.test2.com">>, <<"some.route">>, "", "")),
    ?assertMatch(allow_origin, check_http_origin(<<"POST">>, <<"http://www.sub.test3.com">>, <<"some.route">>, "", "")),
    ?assertMatch(unknown_origin, check_http_origin(<<"POST">>, <<"http://www.other.test3.com">>, <<"some.route">>, "", "")),
    ?assertMatch(allow_origin, check_http_origin(<<"POST">>, <<"http://www.something.test.com">>, <<"some.route">>, "", "")),
    ?assertMatch(allow_origin, check_http_origin(<<"POST">>, <<"http://www.something.test.com:5000">>, <<"some.route">>, "", "")),
    ?assertMatch(unknown_origin, check_http_origin(<<"POST">>, <<"http://www.any-origin.com">>, <<"some.route">>, "", "")),
    ?assertMatch(unknown_origin, check_http_origin(<<"POST">>, <<"http://www.any-origin.com">>, <<"allowed.route">>, "", "")),
    ?assertMatch(allow_origin, check_http_origin(<<"PUT">>, <<"http://www.any-origin.com">>, <<"allowed.route">>, "", ""))
  end.

private_ip_test() ->
  ?assertMatch(
    <<"195.184.103.10">>,
    xff_ip(<<"11.12.13.14,172.16.17.18, 195.184.103.10">>, default_addr)
  ),
  ?assertMatch(
    <<"195.184.103.10">>,
    xff_ip(<<"11.12.13.14  , 172. 16.17.18, , 195.184.103.10 ,  10.0.123.32 ">>, default_addr)
  ),

  ?assertMatch(
    <<"195.184.103.10">>,
    first_non_private_addr(
      [<<"192.168.0.5">>, <<"10.0.123.32">>, <<"195.184.103.10">>, <<"127.0.0.1">>],
      default_addr)),
  ?assertMatch(
    <<"195.184.103.10">>,
    first_non_private_addr(
      [<<"192.168.0.5">>, <<"10.0.123.32">>, <<"195.184.103.10">>, <<"195.184.103.11">>, <<"127.0.0.1">>],
      default_addr)),
  ?assertMatch(
    default_addr,
    first_non_private_addr(
      [<<"192.168.0.5">>, <<"10.0.123.32">>, <<"127.0.0.1">>],
      default_addr
    )
  ).
