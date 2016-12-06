%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2016 Benoît Chesneau <benoitc@refuge.io>
%%% Copyright (c) 2016 Feng Lee <feng@emqtt.io>.
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc
%%%
%%% CIDR Wiki: https://en.wikipedia.org/wiki/Classless_Inter-Domain_Routing
%%%
%%% The module is copied from inet_cidr.erl to avoid one file depencency.
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(esockd_cidr).

-export([parse/1, parse/2, match/2, count/1, to_string/1, is_ipv4/1, is_ipv6/1]).

-type(cidr_string() :: string()).

-type(cidr() :: {inet:ip_address(), inet:ip_address(), 0..128}).

-export_type([cidr_string/0, cidr/0]).

%%%-----------------------------------------------------------------------------
%%% API
%%%-----------------------------------------------------------------------------

%% @doc Parse CIDR.
-spec(parse(string()) -> cidr()).
parse(S) ->
    parse(S, false).

-spec(parse(string(), boolean()) -> cidr()).
parse(S, Adjust) ->
    case string:tokens(S, "/") of
        [AddrStr]         -> parse_addr(AddrStr);
        [AddrStr, LenStr] -> parse_cidr(AddrStr, LenStr, Adjust)
    end.

parse_addr(AddrStr) ->
    {ok, Addr} = inet:parse_address(AddrStr),
    {Addr, Addr, bit_count(Addr)}.

parse_cidr(AddrStr, LenStr, Adjust) ->
    {ok, Addr} = inet:parse_address(AddrStr),
    PrefixLen = list_to_integer(LenStr),
    StartAddr = band_with_mask(Addr, start_mask(Addr, PrefixLen)),
    if
        Adjust /= true, StartAddr /= Addr -> error(invalid_cidr);
        true -> ok
    end,
    EndAddr = calc_end_address(StartAddr, PrefixLen),
    {StartAddr, EndAddr, PrefixLen}.

%% @doc Check if the IP address is in the CIDR block.
-spec(match(inet:ip_address(), cidr()) -> boolean()).
match({W, X, Y, Z}, {{A, B, C, D}, {E, F, G, H}, _Len}) when
    ((W >= A) andalso (W =< E)),
    ((X >= B) andalso (X =< F)),
    ((Y >= C) andalso (Y =< G)),
    ((Z >= D) andalso (Z =< H)) ->
    true;
match({R, S, T, U, V, W, X, Y}, {{A, B, C, D, E, F, G, H}, {I, J, K, L, M, N, O, P}, _Len}) when
    ((R >= A) andalso (R =< I)),
    ((S >= B) andalso (S =< J)),
    ((T >= C) andalso (T =< K)),
    ((U >= D) andalso (U =< L)),
    ((V >= E) andalso (V =< M)),
    ((W >= F) andalso (W =< N)),
    ((X >= G) andalso (X =< O)),
    ((Y >= H) andalso (Y =< P)) ->
    true;
match(_, _) ->
    false.

count({{_, _, _, _}, _EndAddr, Len}) ->
    1 bsl (32 - Len);
count({{_, _, _, _, _, _, _, _}, _EndAddr, Len}) ->
    1 bsl (128 - Len).

to_string({StartAddr, _EndAddr, Len}) ->
    inet:ntoa(StartAddr) ++ "/" ++ integer_to_list(Len).

%% @doc Return true if the value is an ipv4 address
is_ipv4({A, B, C, D}) ->
    ((A >= 0) and (A =< 255)) and
    ((B >= 0) and (B =< 255)) and
    ((C >= 0) and (C =< 255)) and
    ((D >= 0) and (D =< 255));
is_ipv4(_) ->
    false.

%% @doc Return true if the value is an ipv6 address
is_ipv6({A, B, C, D, E, F, G, H}) ->
    ((A >= 0) and (A =< 65535)) and
    ((B >= 0) and (B =< 65535)) and
    ((C >= 0) and (C =< 65535)) and
    ((D >= 0) and (D =< 65535)) and
    ((E >= 0) and (E =< 65535)) and
    ((F >= 0) and (F =< 65535)) and
    ((G >= 0) and (G =< 65535)) and
    ((H >= 0) and (H =< 65535));
is_ipv6(_) ->
    false.

%%%-----------------------------------------------------------------------------
%%% Internal Functions
%%%-----------------------------------------------------------------------------

start_mask({_, _, _, _} = Addr, Len) when 0 =< Len, Len =< 32 ->
    {A, B, C, D} = end_mask(Addr, Len),
    {bnot A, bnot B, bnot C, bnot D};

start_mask({_, _, _, _, _, _, _, _} = Addr, Len) when 0 =< Len, Len =< 128 ->
    {A, B, C, D, E, F, G, H} = end_mask(Addr, Len),
    {bnot A, bnot B, bnot C, bnot D, bnot E, bnot F, bnot G, bnot H}.

end_mask({_, _, _, _}, Len) when 0 =< Len, Len =< 32 ->
    if
        Len == 32 -> {0, 0, 0, 0};
        Len >= 24 -> {0, 0, 0, bmask(Len, 8)};
        Len >= 16 -> {0, 0, bmask(Len, 8), 16#FF};
        Len >= 8  -> {0, bmask(Len, 8), 16#FF, 16#FF};
        Len >= 0  -> {bmask(Len, 8), 16#FF, 16#FF, 16#FF}
    end;

end_mask({_, _, _, _, _, _, _, _}, Len) when 0 =< Len, Len =< 128 ->
    if
        Len == 128 -> {0, 0, 0, 0, 0, 0, 0, 0};
        Len >= 112 -> {0, 0, 0, 0, 0, 0, 0, bmask(Len, 16)};
        Len >= 96  -> {0, 0, 0, 0, 0, 0, bmask(Len, 16), 16#FFFF};
        Len >= 80  -> {0, 0, 0, 0, 0, bmask(Len, 16), 16#FFFF, 16#FFFF};
        Len >= 64  -> {0, 0, 0, 0, bmask(Len, 16), 16#FFFF, 16#FFFF, 16#FFFF};
        Len >= 49  -> {0, 0, 0, bmask(Len, 16), 16#FFFF, 16#FFFF, 16#FFFF, 16#FFFF};
        Len >= 32  -> {0, 0, bmask(Len, 16), 16#FFFF, 16#FFFF, 16#FFFF, 16#FFFF, 16#FFFF};
        Len >= 16  -> {0, bmask(Len, 16), 16#FFFF, 16#FFFF, 16#FFFF, 16#FFFF, 16#FFFF, 16#FFFF};
        Len >= 0   -> {bmask(Len, 16), 16#FFFF, 16#FFFF, 16#FFFF, 16#FFFF, 16#FFFF, 16#FFFF, 16#FFFF}
    end.

bmask(I, 8) when 0 =< I, I =< 32 ->
    16#FF bsr (I rem 8);
bmask(I, 16) when 0 =< I, I =< 128 ->
    16#FFFF bsr (I rem 16).

calc_end_address(Addr, Len) ->
    bor_with_mask(Addr, end_mask(Addr, Len)).

bor_with_mask({A, B, C, D}, {E, F, G, H}) ->
    {A bor E, B bor F, C bor G, D bor H};
bor_with_mask({A, B, C, D, E, F, G, H}, {I, J, K, L, M, N, O, P}) ->
    {A bor I, B bor J, C bor K, D bor L, E bor M, F bor N, G bor O, H bor P}.

band_with_mask({A, B, C, D}, {E, F, G, H}) ->
    {A band E, B band F, C band G, D band H};
band_with_mask({A, B, C, D, E, F, G, H}, {I, J, K, L, M, N, O, P}) ->
    {A band I, B band J, C band K, D band L, E band M, F band N, G band O, H band P}.

bit_count({_, _, _, _}) -> 32;
bit_count({_, _, _, _, _, _, _, _}) -> 128.

