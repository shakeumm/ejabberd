%%%-------------------------------------------------------------------
%%% @author Alexey Shchepin <alexey@process-one.net>
%%% @doc
%%% Interface for Riak database
%%% @end
%%% Created : 29 Dec 2011 by Alexey Shchepin <alexey@process-one.net>
%%% @copyright (C) 2002-2013   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%-------------------------------------------------------------------
-module(ejabberd_riak).

-behaviour(gen_server).

%% API
-export([start_link/3, make_bucket/1, put/1, put/2,
         get/1, get/2, get_by_index/3, delete/1, delete/2,
         count_by_index/3, get_by_index_range/4,
         get_keys/1, get_keys_by_index/3,
         count/1, delete_by_index/3]).
%% For debugging
-export([get_tables/0]).
%% map/reduce exports
-export([map_key/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("ejabberd.hrl").

-record(state, {pid = self() :: pid()}).

-type index() :: {binary(), any()}.

-type index_info() :: [{i, any()} | {'2i', [index()]}].

%% The `index_info()' is used in put/delete functions:
%% `i' defines a primary index, `` '2i' '' defines secondary indexes.
%% There must be only one primary index. If `i' is not specified,
%% the first element of the record is assumed as a primary index,
%% i.e. `i' = element(2, Record).

-export_types([index_info/0]).

%%%===================================================================
%%% API
%%%===================================================================
%% @private
start_link(Server, Port, _StartInterval) ->
    gen_server:start_link(?MODULE, [Server, Port], []).

-spec make_bucket(atom()) -> binary().
%% @doc Makes a bucket from a table name
%% @private
make_bucket(Table) ->
    erlang:atom_to_binary(Table, utf8).

-spec put(tuple()) -> ok | {error, any()}.
%% @equiv put(Record, [])
put(Record) ->
    ?MODULE:put(Record, []).

-spec put(tuple(), index_info()) -> ok | {error, any()}.
%% @doc Stores a record `Rec' with indexes described in ``IndexInfo''
put(Rec, IndexInfo) ->
    Key = encode_key(proplists:get_value(i, IndexInfo, element(2, Rec))),
    SecIdxs = [encode_index_key(K, V) ||
                  {K, V} <- proplists:get_value('2i', IndexInfo, [])],
    Table = element(1, Rec),
    Value = term_to_binary(Rec),
    case put_raw(Table, Key, Value, SecIdxs) of
        ok ->
            ok;
        Error ->
            log_error(Error, put, [{record, Rec},
                                   {index_info, IndexInfo}]),
            Error
    end.

put_raw(Table, Key, Value, Indexes) ->
    Bucket = make_bucket(Table),
    Obj = riakc_obj:new(Bucket, Key, Value, "application/x-erlang-term"),
    Obj1 = if Indexes /= [] ->
                   MetaData = dict:store(<<"index">>, Indexes, dict:new()),
                   riakc_obj:update_metadata(Obj, MetaData);
              true ->
                   Obj
           end,
    riakc_pb_socket:put(ejabberd_riak_sup:get_random_pid(), Obj1).

get_object_raw(Table, Key) ->
    Bucket = make_bucket(Table),
    riakc_pb_socket:get(ejabberd_riak_sup:get_random_pid(), Bucket, Key).

-spec get(atom()) -> {ok, [any()]} | {error, any()}.
%% @doc Returns all objects from table `Table'
get(Table) ->
    Bucket = make_bucket(Table),
    case riakc_pb_socket:mapred(
           ejabberd_riak_sup:get_random_pid(),
           Bucket,
           [{map, {modfun, riak_kv_mapreduce, map_object_value},
             none, true}]) of
        {ok, [{_, Objs}]} ->
            {ok, lists:flatmap(
                   fun(Obj) ->
                           case catch binary_to_term(Obj) of
                               {'EXIT', _} ->
                                   Error = {error, make_invalid_object(Obj)},
                                   log_error(Error, get,
                                             [{table, Table}]),
                                   [];
                               Term ->
                                   [Term]
                           end
                   end, Objs)};
        {error, notfound} ->
            {ok, []};
        Error ->
            Error
    end.

-spec get(atom(), any()) -> {ok, any()} | {error, any()}.
%% @doc Reads record by `Key' from table `Table'
get(Table, Key) ->
    case get_raw(Table, encode_key(Key)) of
        {ok, Val} ->
            case catch binary_to_term(Val) of
                {'EXIT', _} ->
                    Error = {error, make_invalid_object(Val)},
                    log_error(Error, get, [{table, Table}, {key, Key}]),
                    {error, notfound};
                Term ->
                    {ok, Term}
            end;
        Error ->
            log_error(Error, get, [{table, Table},
                                   {key, Key}]),
            Error
    end.

-spec get_by_index(atom(), binary(), any()) -> {ok, [any()]} | {error, any()}.
%% @doc Reads records by `Index' and value `Key' from `Table' 
get_by_index(Table, Index, Key) ->
    {NewIndex, NewKey} = encode_index_key(Index, Key),
    case get_by_index_raw(Table, NewIndex, NewKey) of
        {ok, Vals} ->
            {ok, lists:flatmap(
                   fun(Val) ->
                           case catch binary_to_term(Val) of
                               {'EXIT', _} ->
                                   Error = {error, make_invalid_object(Val)},
                                   log_error(Error, get_by_index,
                                             [{table, Table},
                                              {index, Index},
                                              {key, Key}]),
                                   [];
                               Term ->
                                   [Term]
                           end
                   end, Vals)};
        {error, notfound} ->
            {ok, []};
        Error ->
            log_error(Error, get_by_index,
                      [{table, Table},
                       {index, Index},
                       {key, Key}]),
            Error
    end.

-spec get_by_index_range(atom(), binary(), any(), any()) ->
                                {ok, [any()]} | {error, any()}.
%% @doc Reads records by `Index' in the range `FromKey'..`ToKey' from `Table'
get_by_index_range(Table, Index, FromKey, ToKey) ->
    {NewIndex, NewFromKey} = encode_index_key(Index, FromKey),
    {NewIndex, NewToKey} = encode_index_key(Index, ToKey),
    case get_by_index_range_raw(Table, NewIndex, NewFromKey, NewToKey) of
        {ok, Vals} ->
            {ok, lists:flatmap(
                   fun(Val) ->
                           case catch binary_to_term(Val) of
                               {'EXIT', _} ->
                                   Error = {error, make_invalid_object(Val)},
                                   log_error(Error, get_by_index_range,
                                             [{table, Table},
                                              {index, Index},
                                              {start_key, FromKey},
                                              {end_key, ToKey}]),
                                   [];
                               Term ->
                                   [Term]
                           end
                   end, Vals)};
        {error, notfound} ->
            {ok, []};
        Error ->
            log_error(Error, get_by_index_range,
                      [{table, Table}, {index, Index},
                       {start_key, FromKey}, {end_key, ToKey}]),
            Error
    end.

get_raw(Table, Key) ->
    case get_object_raw(Table, Key) of
        {ok, Obj} ->
            {ok, riakc_obj:get_value(Obj)};
        Error ->
            Error
    end.

-spec get_keys(atom()) -> {ok, [any()]} | {error, any()}.
%% @doc Returns a list of index values
get_keys(Table) ->
    Bucket = make_bucket(Table),
    case riakc_pb_socket:mapred(
           ejabberd_riak_sup:get_random_pid(),
           Bucket,
           [{map, {modfun, ?MODULE, map_key}, none, true}]) of
        {ok, [{_, Keys}]} ->
            {ok, Keys};
        Error ->
            log_error(Error, get_keys, [{table, Table}]),
            Error
    end.

-spec get_keys_by_index(atom(), binary(),
                        any()) -> {ok, [any()]} | {error, any()}.
%% @doc Returns a list of primary keys of objects indexed by `Key'.
get_keys_by_index(Table, Index, Key) ->
    {NewIndex, NewKey} = encode_index_key(Index, Key),
    Bucket = make_bucket(Table),
    case riakc_pb_socket:mapred(
           ejabberd_riak_sup:get_random_pid(),
           {index, Bucket, NewIndex, NewKey},
           [{map, {modfun, ?MODULE, map_key}, none, true}]) of
        {ok, [{_, Keys}]} ->
            {ok, Keys};
        Error ->
            log_error(Error, get_keys_by_index, [{table, Table},
                                                 {index, Index},
                                                 {key, Key}]),
            Error
    end.

%% @hidden
get_tables() ->
    riakc_pb_socket:list_buckets(ejabberd_riak_sup:get_random_pid()).

get_by_index_raw(Table, Index, Key) ->
    Bucket = make_bucket(Table),
    case riakc_pb_socket:mapred(
           ejabberd_riak_sup:get_random_pid(),
           {index, Bucket, Index, Key},
           [{map, {modfun, riak_kv_mapreduce, map_object_value},
             none, true}]) of
        {ok, [{_, Objs}]} ->
            {ok, Objs};
        Error ->
            Error
    end.

get_by_index_range_raw(Table, Index, FromKey, ToKey) ->
    Bucket = make_bucket(Table),
    case riakc_pb_socket:mapred(
           ejabberd_riak_sup:get_random_pid(),
           {index, Bucket, Index, FromKey, ToKey},
           [{map, {modfun, riak_kv_mapreduce, map_object_value},
             none, true}]) of
        {ok, [{_, Objs}]} ->
            {ok, Objs};
        Error ->
            Error
    end.

-spec count(atom()) -> {ok, non_neg_integer()} | {error, any()}.
%% @doc Returns the number of objects in the `Table'
count(Table) ->
    Bucket = make_bucket(Table),
    case riakc_pb_socket:mapred(
           ejabberd_riak_sup:get_random_pid(),
           Bucket,
           [{reduce, {modfun, riak_kv_mapreduce, reduce_count_inputs},
             none, true}]) of
        {ok, [{_, [Cnt]}]} ->
            {ok, Cnt};
        Error ->
            log_error(Error, count, [{table, Table}]),
            Error
    end.

-spec count_by_index(atom(), binary(), any()) ->
                            {ok, non_neg_integer()} | {error, any()}.
%% @doc Returns the number of objects in the `Table' by index
count_by_index(Tab, Index, Key) ->
    {NewIndex, NewKey} = encode_index_key(Index, Key),
    case count_by_index_raw(Tab, NewIndex, NewKey) of
        {ok, Cnt} ->
            {ok, Cnt};
        {error, notfound} ->
            {ok, 0};
        Error ->
            log_error(Error, count_by_index,
                      [{table, Tab},
                       {index, Index},
                       {key, Key}]),
            Error
    end.

count_by_index_raw(Table, Index, Key) ->
    Bucket = make_bucket(Table),
    case riakc_pb_socket:mapred(
           ejabberd_riak_sup:get_random_pid(),
           {index, Bucket, Index, Key},
           [{reduce, {modfun, riak_kv_mapreduce, reduce_count_inputs},
             none, true}]) of
        {ok, [{_, [Cnt]}]} ->
            {ok, Cnt};
        Error ->
            Error
    end.

-spec delete(tuple() | atom()) -> ok | {error, any()}.
%% @doc Same as delete(T, []) when T is record.
%% Or deletes all elements from table if T is atom.
delete(Rec) when is_tuple(Rec) ->
    delete(Rec, []);
delete(Table) when is_atom(Table) ->
    try
        {ok, Keys} = ?MODULE:get_keys(Table),
        lists:foreach(
          fun(K) ->
                  ok = delete(Table, K)
          end, Keys)
    catch _:{badmatch, Err} ->
            Err
    end.

-spec delete(tuple() | atom(), index_info() | any()) -> ok | {error, any()}.
%% @doc Delete an object
delete(Rec, Opts) when is_tuple(Rec) ->
    Table = element(1, Rec),
    Key = proplists:get_value(i, Opts, element(2, Rec)),
    delete(Table, Key);
delete(Table, Key) when is_atom(Table) ->
    case delete_raw(Table, encode_key(Key)) of
        ok ->
            ok;
        Err ->
            log_error(Err, delete, [{table, Table}, {key, Key}]),
            Err
    end.

delete_raw(Table, Key) ->
    Bucket = make_bucket(Table),
    riakc_pb_socket:delete(ejabberd_riak_sup:get_random_pid(), Bucket, Key).

-spec delete_by_index(atom(), binary(), any()) -> ok | {error, any()}.
%% @doc Deletes objects by index
delete_by_index(Table, Index, Key) ->
    try
        {ok, Keys} = get_keys_by_index(Table, Index, Key),
        lists:foreach(
          fun(K) ->
                  ok = delete(Table, K)
          end, Keys)
    catch _:{badmatch, Err} ->
            Err
    end.

%%%===================================================================
%%% map/reduce functions
%%%===================================================================
%% @private
map_key(Obj, _, _) ->
    [case riak_object:key(Obj) of
         <<"b_", B/binary>> ->
             B;
         <<"i_", B/binary>> ->
             list_to_integer(binary_to_list(B));
         B ->
             erlang:binary_to_term(B)
     end].

%%%===================================================================
%%% gen_server API
%%%===================================================================
%% @private
init([Server, Port]) ->
    case riakc_pb_socket:start(
           Server, Port,
           [auto_reconnect]) of
        {ok, Pid} ->
            erlang:monitor(process, Pid),
            ejabberd_riak_sup:add_pid(Pid),
            {ok, #state{pid = Pid}};
        Err ->
            {stop, Err}
    end.

%% @private
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info({'DOWN', _MonitorRef, _Type, _Object, _Info}, State) ->
    {stop, normal, State};
handle_info(_Info, State) ->
    ?ERROR_MSG("unexpected info: ~p", [_Info]),
    {noreply, State}.

%% @private
terminate(_Reason, State) ->
    ejabberd_riak_sup:remove_pid(State#state.pid),
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
encode_index_key(Idx, Key) when is_integer(Key) ->
    {<<Idx/binary, "_int">>, Key};
encode_index_key(Idx, Key) ->
    {<<Idx/binary, "_bin">>, encode_key(Key)}.

encode_key(Bin) when is_binary(Bin) ->
    <<"b_", Bin/binary>>;
encode_key(Int) when is_integer(Int) ->
    <<"i_", (list_to_binary(integer_to_list(Int)))/binary>>;
encode_key(Term) ->
    erlang:term_to_binary(Term).

log_error({error, notfound}, _, _) ->
    ok;
log_error({error, Why} = Err, Function, Opts) ->
    Txt = lists:map(
            fun({table, Table}) ->
                    io_lib:fwrite("** Table: ~p~n", [Table]);
               ({key, Key}) ->
                    io_lib:fwrite("** Key: ~p~n", [Key]);
               ({index, Index}) ->
                    io_lib:fwrite("** Index = ~p~n", [Index]);
               ({start_key, Key}) ->
                    io_lib:fwrite("** Start Key: ~p~n", [Key]);
               ({end_key, Key}) ->
                    io_lib:fwrite("** End Key: ~p~n", [Key]);
               ({record, Rec}) ->
                    io_lib:fwrite("** Record = ~p~n", [Rec]);
               ({index_info, IdxInfo}) ->
                    io_lib:fwrite("** Index info = ~p~n", [IdxInfo]);
               (_) ->
                    ""
            end, Opts),
    ErrTxt = if is_binary(Why) ->
                     io_lib:fwrite("** Error: ~s", [Why]);
                true ->
                     io_lib:fwrite("** Error: ~p", [Err])
             end,
    ?ERROR_MSG("database error:~n** Function: ~p~n~s~s",
               [Function, Txt, ErrTxt]);
log_error(_, _, _) ->
    ok.

make_invalid_object(Val) ->
    list_to_binary(io_lib:fwrite("Invalid object: ~p", [Val])).
