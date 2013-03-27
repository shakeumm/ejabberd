%%% ====================================================================
%%% ``The contents of this file are subject to the Erlang Public License,
%%% Version 1.1, (the "License"); you may not use this file except in
%%% compliance with the License. You should have received a copy of the
%%% Erlang Public License along with this software. If not, it can be
%%% retrieved via the world wide web at http://www.erlang.org/.
%%%
%%% Software distributed under the License is distributed on an "AS IS"
%%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%%% the License for the specific language governing rights and limitations
%%% under the License.
%%%
%%% The Initial Developer of the Original Code is ProcessOne.
%%% Portions created by ProcessOne are Copyright 2006-2013, ProcessOne
%%% All Rights Reserved.''
%%% This software is copyright 2006-2013, ProcessOne.
%%%
%%%
%%% @copyright 2006-2013 ProcessOne
%%% @author Christophe Romain <christophe.romain@process-one.net>
%%%   [http://www.process-one.net/]
%%% @version {@vsn}, {@date} {@time}
%%% @end
%%% ====================================================================

%%% @doc The module <strong>{@module}</strong> is the PubSub node tree plugin that
%%% allow virtual nodes handling.
%%% <p>PubSub node tree plugins are using the {@link gen_nodetree} behaviour.</p>
%%% <p>This plugin development is still a work in progress. Due to optimizations in
%%% mod_pubsub, this plugin can not work anymore without altering functioning.
%%% Please, send us comments, feedback and improvements.</p>

-module(nodetree_virtual).

-author('christophe.romain@process-one.net').

-include("pubsub.hrl").

-include("jlib.hrl").

-behaviour(gen_pubsub_nodetree).

-export([init/3, terminate/2, options/0, set_node/1,
	 get_node/3, get_node/2, get_node/1, get_nodes/2,
	 get_nodes/1, get_parentnodes/3, get_parentnodes_tree/3,
	 get_subnodes/3, get_subnodes_tree/3, create_node/6,
	 delete_node/2]).

%% ================
%% API definition
%% ================

init(_Host, _ServerHost, _Opts) -> ok.

terminate(_Host, _ServerHost) -> ok.

options() -> [{virtual_tree, true}].

set_node(_NodeRecord) -> ok.

get_node(Host, Node, _From) -> get_node(Host, Node).

get_node(Host, Node) -> get_node({Host, Node}).

get_node({Host, _} = NodeId) ->
    Record = #pubsub_node{nodeid = NodeId, id = NodeId},
    Module = jlib:binary_to_atom(<<"node_",
				     (Record#pubsub_node.type)/binary>>),
    Options = Module:options(),
    Owners = [{<<"">>, Host, <<"">>}],
    Record#pubsub_node{owners = Owners, options = Options}.

get_nodes(Host, _From) -> get_nodes(Host).

get_nodes(_Host) -> [].

get_parentnodes(_Host, _Node, _From) -> [].

get_parentnodes_tree(_Host, _Node, _From) -> [].

get_subnodes(Host, Node, _From) ->
    get_subnodes(Host, Node).

get_subnodes(_Host, _Node) -> [].

get_subnodes_tree(Host, Node, _From) ->
    get_subnodes_tree(Host, Node).

get_subnodes_tree(_Host, _Node) -> [].

create_node(Host, Node, _Type, _Owner, _Options,
	    _Parents) ->
    {error, {virtual, {Host, Node}}}.

delete_node(Host, Node) -> [get_node(Host, Node)].
