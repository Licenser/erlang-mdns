%% Copyright (c) 2012, Peter Morgan <peter.james.morgan@gmail.com>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(mdns_node_discovery_server).
-behaviour(gen_server).
-import(proplists, [get_value/2]).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0,
	 start_link/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1,
	 handle_call/3,
	 handle_info/2,
         terminate/2,
	 code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    start_link([]).

start_link(Parameters) ->
    gen_server:start_link({local, mdns:name()}, ?MODULE, Parameters, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

-record(state, {socket,
		address,
		domain,
		port,
		type,
		discovered=[]}).

init(Parameters) ->
    process_flag(trap_exit, true),
    init(Parameters, #state{}).

init([{address, Address} | T], State) ->
    init(T, State#state{address = Address});
init([{domain, Domain} | T], State) ->
    init(T, State#state{domain = Domain});
init([{port, Port} | T], State) ->
    init(T, State#state{port = Port});
init([{type, Type} | T], State) ->
    init(T, State#state{type = Type});
init([_ | T], State) ->
    init(T, State);
init([], #state{address = Address, port = Port} = State) ->
%    lager:info("mdns:init_discovery_server: ~p.",
%	       [State]),
    {ok, Socket} = gen_udp:open(Port, [{mode, binary},
				       {reuseaddr, true},
				       {ip, Address},
				       {multicast_ttl, 4},
				       {multicast_loop, true},
				       {broadcast, true},
				       {add_membership, {Address, {0, 0, 0, 0}}},
				       {active, once}]),
    ok = net_kernel:monitor_nodes(true),
    {ok, State#state{socket = Socket}}.

handle_call(discovered, _, #state{discovered = Discovered} = State) ->
    {reply, Discovered, State};

handle_call(stop, _, State) ->
    {stop, normal, State}.

handle_info({nodeup, Node}, State) ->
%    lager:info("mdns:nodeup: ~p.", [Node]),
    {noreply, State};
handle_info({nodedown, Node}, #state{discovered = Discovered} = State) ->
%    lager:info("mdns:nodedown: ~p.", [Node]),
    {noreply, State#state{discovered = lists:delete(Node, Discovered)}};
handle_info({udp, Socket, _, _, Packet}, S1) ->
    {ok, Record} = inet_dns:decode(Packet),
    Header = inet_dns:header(inet_dns:msg(Record, header)),
    Type = inet_dns:record_type(Record),
    Questions = [inet_dns:dns_query(Query) || Query <- inet_dns:msg(Record, qdlist)],
    Answers = [inet_dns:rr(RR) || RR <- inet_dns:msg(Record, anlist)],
    Authorities = [inet_dns:rr(RR) || RR <- inet_dns:msg(Record, nslist)],
    Resources = [inet_dns:rr(RR) || RR <- inet_dns:msg(Record, arlist)],
    S2 = handle_record(Header,
		       Type,
		       get_value(qr, Header),
		       get_value(opcode, Header),
		       Questions,
		       Answers,
		       Authorities,
		       Resources,
		       S1),
    inet:setopts(Socket, [{active, once}]),
    {noreply, S2}.

terminate(_Reason, #state{socket = Socket}) ->
    net_kernel:monitor_nodes(false),
    gen_udp:close(Socket).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

handle_record(_, msg, false, 'query', [Question], [], [], [], State) ->
    case {type_domain(State), domain_type_class(Question)} of
	{TypeDomain, {TypeDomain, ptr, in}} ->
	    mdns_node_discovery:advertise(),
	    State;
	_ ->
	    State
    end;
handle_record(_, msg, false, 'query', [Question], [Answer], [], [], State) ->
    case {type_domain(State), domain_type_class(Question)} of
	{TypeDomain, {TypeDomain, ptr, in}} ->
	    case lists:member(data(Answer), local_instances(State)) of
		true ->
		    mdns_node_discovery:advertise(),
		    State;
		_ ->
		    State
	    end;
	_ ->
	    State
    end;
handle_record(_, msg, true, 'query', [], Answers, [], Resources, State) ->
    handle_advertisement(Answers, Resources, State);

handle_record(_, msg, false, 'query', _, _, _, _, State) ->
    State.

local_instances(#state{domain = Domain} = State) ->
    {ok, Names} = net_adm:names(),
    {ok, Hostname} = inet:gethostname(),
    HostnameWithDomain = 
	case re:run(Hostname, "\\.") of
	    nomatch ->
		Hostname  ++ Domain;
	    _ ->
		Hostname
	end,
    [instance(Node, HostnameWithDomain, State) || {Node, _} <- Names].

instance(Node, Hostname, #state{type = Type, domain = Domain}) ->
    Node ++ "@" ++ Hostname ++ "." ++ Type ++ Domain.

handle_advertisement([Answer | Answers], Resources, #state{discovered = Discovered} = State) ->
%    lager:info("mdns:handle_advertisement - Answer: ~p.", [Answer]),
    case {type_domain(State), domain_type_class(Answer)} of
	{TypeDomain, {TypeDomain, ptr, in}} ->
%	    lager:info("mdns:handle_advertisement - DomainType: ~p.", [TypeDomain]),
	    Node = node_and_hostname([{type(Resource), data(Resource)} || Resource <- Resources,
									  domain(Resource) =:= data(Answer)]),
%	    lager:info("mdns:handle_advertisement - Node: ~p <- ~p.", [Node, [{type(Resource), data(Resource)} || Resource <- Resources,
%									  domain(Resource) =:= data(Answer)]]),
	    case lists:member(Node, Discovered) of
		false ->
		    mdns_node_discovery_event:notify_node_advertisement(Node),
		    mdns_node_discovery:advertise(),
		    case net_kernel:connect_node(Node) of
			true ->
%			    lager:info("mdns:handle_advertisement: ok(~p)", [Node]),
			    handle_advertisement(Answers, Resources, State#state{discovered = [Node | Discovered]});
			false ->
%			    lager:info("mdns:handle_advertisement: error(~p)", [Node]),
			    handle_advertisement(Answers, Resources, State)
		    end;
		true ->
		    handle_advertisement(Answers, Resources, State)
	    end;
	_ ->
%	    lager:info("mdns:handle_advertisement - Unknown type: ~p vs ~p.", 
%		       [type_domain(State), domain_type_class(Answer)]),
	    handle_advertisement(Answers, Resources, State)
    end;
handle_advertisement([], _, State) ->
    State.


node_and_hostname(P) ->
    list_to_atom(node_name(get_value(txt, P)) ++ "@" ++ host_name(get_value(txt, P))).

node_name([[$n, $o, $d, $e, $= | Name] | _]) ->
    Name;
node_name([_ | T]) ->
    node_name(T).

host_name([[$h, $o, $s, $t, $n, $a, $m, $e, $= | Hostname] | _]) ->
    Hostname;
host_name([_ | T]) ->
    host_name(T).

		

type_domain(#state{type = Type, domain = Domain}) ->
    Type ++ Domain.

domain_type_class(Resource) ->
    {domain(Resource), type(Resource), class(Resource)}.


domain(Resource) ->
    get_value(domain, Resource).

type(Resource) ->
    get_value(type, Resource).

class(Resource) ->
    get_value(class, Resource).

data(Resource) ->
    get_value(data, Resource).
	
		    
		    
    
    

