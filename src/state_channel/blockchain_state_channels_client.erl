%%%-------------------------------------------------------------------
%% @doc
%% == Blockchain State Channels Client ==
%% @end
%%%-------------------------------------------------------------------
-module(blockchain_state_channels_client).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1,
         packet/3,
         purchase/2,
         banner/2,
         reject/2,
         state/0,
         gc_state_channels/1,
         response/1]).

%% ------------------------------------------------------------------
%% gen_server exports
%% ------------------------------------------------------------------
-export([init/1,
         handle_call/3,
         handle_info/2,
         handle_cast/2,
         terminate/2,
         code_change/3]).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("blockchain.hrl").
-include("blockchain_vars.hrl").

-define(SERVER, ?MODULE).

-record(state,{
          db :: rocksdb:db_handle(),
          cf :: rocksdb:cf_handle(),
          swarm :: pid(),
          pubkey_bin :: libp2p_crypto:pubkey_bin(),
          sig_fun :: libp2p_crypto:sig_fun(),
          chain = undefined :: undefined | blockchain:blockchain(),
          streams = #{} :: streams(),
          packets = #{} :: #{pid() => queue:queue(blockchain_helium_packet_v1:packet())},
          waiting = #{} :: waiting(),
          pending_closes = [] :: list() %% TODO GC these
         }).

-type state() :: #state{}.
-type stream_key() :: non_neg_integer() | string().
-type stream_val() :: undefined | dialing | {unverified, pid()} | pid().
-type streams() :: #{stream_key() => stream_val()}.
-type waiting_packet() :: {Packet :: blockchain_helium_packet_v1:packet(), Region :: atom()}.
-type waiting_key() :: non_neg_integer() | string().
-type waiting() :: #{waiting_key() => [waiting_packet()]}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec response(blockchain_state_channel_response_v1:response()) -> any().
response(Resp) ->
    erlang:spawn(fun() ->
        case application:get_env(blockchain, sc_client_handler, undefined) of
            undefined ->
                ok;
            Mod when is_atom(Mod) ->
                Mod:handle_response(Resp)
        end
    end).

-spec packet(Packet :: blockchain_helium_packet_v1:packet(),
             DefaultRouters :: [string()],
             Region :: atom()) -> ok.
packet(Packet, DefaultRouters, Region) ->
    gen_server:cast(?SERVER, {packet, Packet, DefaultRouters, Region}).

-spec state() -> state().
state() ->
    gen_server:call(?SERVER, state).

-spec purchase(Purchase :: blockchain_state_channel_purchase_v1:purchase(),
               HandlerPid :: pid()) -> ok.
purchase(Purchase, HandlerPid) ->
    gen_server:cast(?SERVER, {purchase, Purchase, HandlerPid}).

-spec banner(Banner :: blockchain_state_channel_banner_v1:banner(),
             HandlerPid :: pid()) -> ok.
banner(Banner, HandlerPid) ->
    gen_server:cast(?SERVER, {banner, Banner, HandlerPid}).

-spec reject(Rejection :: blockchain_state_channel_rejection_v1:rejection(),
             HandlerPid :: pid()) -> ok.
reject(Rejection, HandlerPid) ->
    gen_server:cast(?SERVER, {reject, Rejection, HandlerPid}).

gc_state_channels([]) -> ok;
gc_state_channels(SCIDs) ->
    gen_server:cast(?SERVER, {gc_state_channels, SCIDs}).

%% ------------------------------------------------------------------
%% init, terminate and code_change
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    ok = blockchain_event:add_handler(self()),
    Swarm = maps:get(swarm, Args),
    DB = blockchain_state_channels_db_owner:db(),
    CF = blockchain_state_channels_db_owner:sc_clients_cf(),
    {PubkeyBin, SigFun} = blockchain_utils:get_pubkeybin_sigfun(Swarm),
    erlang:send_after(500, self(), post_init),
    State = #state{db=DB, cf=CF, swarm=Swarm, pubkey_bin=PubkeyBin, sig_fun=SigFun},
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% gen_server message handling
%% ------------------------------------------------------------------

handle_cast({banner, Banner, HandlerPid}, State=#state{pubkey_bin=PubkeyBin, sig_fun=SigFun}) ->
    case blockchain_state_channel_banner_v1:sc(Banner) of
        undefined ->
            %% TODO in theory if you're in the same OUI as the router this is ok
            {noreply, State};
        BannerSC ->
            case is_valid_sc(BannerSC, State) of
                {error, causal_conflict} ->
                    lager:error("causal_conflict for banner sc: ~p", [BannerSC]),
                    _ = libp2p_framed_stream:close(HandlerPid),
                    ok = append_state_channel(BannerSC, State),
                    {noreply, State};
                {error, Reason} ->
                    lager:error("reason: ~p", [Reason]),
                    _ = libp2p_framed_stream:close(HandlerPid),
                    {noreply, State};
                ok ->
                    overwrite_state_channel(BannerSC, State),
                    AddressOrOUI = lookup_stream_id(HandlerPid, State),
                    Packets = get_waiting_packet(AddressOrOUI, State),
                    lager:info("valid banner for ~p, sending ~p packets", [AddressOrOUI, length(Packets)]),
                    case AddressOrOUI of
                        OUI when is_integer(OUI) ->
                            lager:debug("dial_success sending ~p packets or offer depending on OUI", [erlang:length(Packets)]),
                            State1 = lists:foldl(
                                       fun({Packet, Region}, Acc) ->
                                               send_packet_or_offer(HandlerPid, OUI, Packet, Region, Acc)
                                       end,
                                       State,
                                       Packets
                                      ),
                            {noreply, verify_stream(HandlerPid, remove_packet_from_waiting(OUI, State1))};
                        Address when is_list(Address) ->
                            case blockchain:config(sc_version, blockchain:ledger(State#state.chain)) of
                                {ok, 2} ->
                                    lists:foreach(
                                      fun({Packet, Region}) ->
                                              ok = send_offer(PubkeyBin, SigFun, HandlerPid, Packet, Region)
                                      end,
                                      Packets
                                     );
                                _ ->
                                    lists:foreach(
                                      fun({Packet, Region}) ->
                                              ok = send_packet(PubkeyBin, SigFun, HandlerPid, Packet, Region)
                                      end,
                                      Packets
                                     )
                            end,
                            {noreply, verify_stream(HandlerPid, remove_packet_from_waiting(Address, State))}
                    end
            end
    end;
handle_cast({purchase, Purchase, HandlerPid}, State) ->
    NewState = handle_purchase(Purchase, HandlerPid, State),
    {noreply, NewState};
handle_cast({packet, Packet, DefaultRouters, Region}, #state{chain=Chain}=State) ->
    NewState = case find_routing(Packet, Chain) of
                   {error, _Reason} ->
                     lager:notice("failed to find router for join packet with routing information ~p:~p, trying default routers",
                                   [blockchain_helium_packet_v1:routing_info(Packet), _Reason]),
                       handle_packet(Packet, DefaultRouters, Region, State);
                   {ok, Routes} ->
                       handle_packet(Packet, Routes, Region, State)
               end,
    {noreply, NewState};
handle_cast({reject, Rejection, HandlerPid}, State) ->
    lager:warning("Got rejection: ~p for: ~p, dropping packet", [Rejection, HandlerPid]),
    NewState = case dequeue_packet(HandlerPid, State) of
                   {undefined, State} -> State;
                   {_, NS} -> NS
               end,
    {noreply, NewState};
handle_cast({gc_state_channels, SCIDs}, #state{pending_closes=P, db=DB, cf=CF}=State) ->
    {ok, Batch} = rocksdb:batch(),
    lists:foreach(fun(SCID) ->
                          rocksdb:batch_delete(Batch, CF, SCID)
                  end, SCIDs),
    ok = rocksdb:write_batch(DB, Batch, [{sync, true}]),
    rocksdb:release_batch(Batch),
    {noreply, State#state{pending_closes=P -- SCIDs}};
handle_cast(_Msg, State) ->
    lager:debug("unhandled receive: ~p", [_Msg]),
    {noreply, State}.

handle_call(state, _From, State) ->
    {reply, {ok, State}, State};
handle_call(_, _, State) ->
    {reply, ok, State}.

handle_info(post_init, #state{chain=undefined}=State) ->
    case blockchain_worker:blockchain() of
        undefined ->
            erlang:send_after(500, self(), post_init),
            {noreply, State};
        Chain ->
            {noreply, State#state{chain=Chain}}
    end;
handle_info({blockchain_event, {new_chain, NC}}, State) ->
    {noreply, State#state{chain=NC}};
handle_info({dial_fail, AddressOrOUI, _Reason}, State0) ->
    Packets = get_waiting_packet(AddressOrOUI, State0),
    lager:error("failed to dial ~p: ~p dropping ~p packets", [AddressOrOUI, _Reason, erlang:length(Packets)+1]),
    State1 = remove_packet_from_waiting(AddressOrOUI, delete_stream(AddressOrOUI, State0)),
    {noreply, State1};
handle_info({dial_success, AddressOrOUI, Stream}, #state{chain=undefined}=State) ->
    %% We somehow lost the chain here, likely we were restarting and haven't gotten it yet
    %% There really isn't anything we can do about it, but we should probably keep this stream
    %% (if we don't already have it)
    NewState = case find_stream(AddressOrOUI, State) of
                   undefined ->
                       add_stream(AddressOrOUI, Stream, State);
                   _ ->
                       State
               end,
    {noreply, NewState};
handle_info({dial_success, OUIOrAddress, Stream}, State0) ->
    erlang:monitor(process, Stream),
    State1 = add_stream(OUIOrAddress, Stream, State0),
    {noreply, State1};
handle_info({blockchain_event, {add_block, _BlockHash, _Syncing, _Ledger}}, #state{chain=undefined}=State) ->
    {noreply, State};
handle_info({blockchain_event, {add_block, BlockHash, _Syncing, Ledger}},
            #state{chain=Chain, pubkey_bin=PubkeyBin, sig_fun=SigFun, pending_closes=PendingCloses}=State) ->
    ClosingChannels = case blockchain:get_block(BlockHash, Chain) of
                            {error, Reason} ->
                                lager:error("Couldn't get block with hash: ~p, reason: ~p", [BlockHash, Reason]),
                                [];
                            {ok, Block} ->
                                lists:foldl(fun(T, Acc) ->
                                                      case blockchain_txn:type(T) == blockchain_txn_state_channel_close_v1 of
                                                          true ->
                                                              SC = blockchain_txn_state_channel_close_v1:state_channel(T),
                                                              SCID = blockchain_txn_state_channel_close_v1:state_channel_id(T),
                                                              case lists:member(SCID, PendingCloses) orelse
                                                                   is_causally_correct_sc(SC, State) of
                                                                  true ->
                                                                      ok;
                                                                  false ->
                                                                      %% submit our own close with the conflicting view(s)
                                                                      close_state_channel(SC, State)
                                                              end,
                                                              %% add it to the list of closing channels so we don't try to double
                                                              %% close it below, irregardless of if we're disputing it
                                                              [SCID|Acc];
                                                          false ->
                                                              Acc
                                                      end
                                              end, [], blockchain_block:transactions(Block))
                        end,
    %% check if any other channels are expiring
    SCGrace = case blockchain:config(?sc_grace_blocks, Ledger) of
                  {ok, G} -> G;
                  _ -> 0
              end,
    SCs = state_channels(State),
    {ok, LedgerHeight} = blockchain_ledger_v1:current_height(Ledger),
    ExpiringChannels = lists:foldl(fun([H|_]=SC, Acc) ->
                                           ExpireAt = blockchain_state_channel_v1:expire_at_block(H),
                                           SCID = blockchain_state_channel_v1:id(H),
                                           SCOwner = blockchain_state_channel_v1:owner(H),
                                           case (not lists:member(SCID, PendingCloses ++ ClosingChannels)) andalso
                                                %% divide by 3 here so we give the server a chance to file its close first
                                                %% before the client tries to file a close
                                                LedgerHeight >= ExpireAt + (SCGrace div 3) andalso
                                                LedgerHeight =< ExpireAt + SCGrace of
                                               true ->
                                                   case length(SC) of
                                                       1 ->
                                                           %% check in the ledger that this sc is not already closing
                                                           case blockchain_ledger_v1:find_state_channel(SCID, SCOwner, Ledger) of
                                                               {error, _} ->
                                                                   %% don't do anything
                                                                   ok;
                                                               {ok, LSC} ->
                                                                   case blockchain_ledger_state_channel_v2:is_v2(LSC) of
                                                                       false ->
                                                                           %% ignore v1 state channels
                                                                           ok;
                                                                       true ->
                                                                           case blockchain_ledger_state_channel_v2:close_state(LSC) of
                                                                               undefined ->
                                                                                   Txn = blockchain_txn_state_channel_close_v1:new(H, PubkeyBin),
                                                                                   SignedTxn = blockchain_txn_state_channel_close_v1:sign(Txn, SigFun),
                                                                                   ok = blockchain_worker:submit_txn(SignedTxn);
                                                                               _ ->
                                                                                   %% already in closed/dispute state in ledger, do nothing
                                                                                   ok
                                                                           end
                                                                   end
                                                           end;
                                                       _ ->
                                                           %% close with conflict
                                                           close_state_channel(H, State)
                                                   end,
                                                   [SCID|Acc];
                                               false ->
                                                   Acc
                                           end
                                   end, [], SCs),
    {noreply, State#state{pending_closes=lists:usort(PendingCloses ++ ClosingChannels ++ ExpiringChannels)}};
handle_info({'DOWN', _Ref, process, Pid, _}, #state{streams=Streams}=State) ->
    FilteredStreams = maps:filter(fun(_Name, {unverified, Stream}) ->
                                          Stream /= Pid;
                                     (_Name, Stream) ->
                                          Stream /= Pid
                                  end, Streams),
    {noreply, State#state{streams=FilteredStreams}};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec handle_packet(Packet :: blockchain_helium_packet_v1:packet(),
                    RoutesOrAddresses :: [string()] | [blockchain_ledger_routing_v1:routing()],
                    Region :: atom(),
                    State :: state()) -> state().
handle_packet(Packet, RoutesOrAddresses, Region, #state{swarm=Swarm}=State0) ->
    lager:info("handle_packet ~p to ~p", [Packet, RoutesOrAddresses]),
    lists:foldl(
        fun(RouteOrAddress, StateAcc) ->
                StreamKey = case blockchain_ledger_routing_v1:is_routing(RouteOrAddress) of
                                false ->
                                    {address, RouteOrAddress};
                                true ->
                                    {oui, blockchain_ledger_routing_v1:oui(RouteOrAddress)}
                            end,

                case StreamKey of
                    {address, Address} ->
                        case find_stream(Address, StateAcc) of
                            undefined ->
                                lager:debug("stream undef dialing first"),
                                ok = dial(Swarm, RouteOrAddress),
                                add_packet_to_waiting(Address, {Packet, Region}, add_stream(Address, dialing, StateAcc));
                            dialing ->
                                lager:debug("stream is still dialing queueing packet"),
                                add_packet_to_waiting(Address, {Packet, Region}, StateAcc);
                            {unverified, _Stream} ->
                                %% queue it until we get a banner
                                add_packet_to_waiting(Address, {Packet, Region}, StateAcc);
                            Stream ->
                                send_packet_when_v1(Stream, Packet, Region, StateAcc)
                        end;
                    {oui, OUI} ->
                        case find_stream(OUI, StateAcc) of
                            undefined ->
                                lager:debug("stream undef dialing first"),
                                ok = dial(Swarm, RouteOrAddress),
                                add_packet_to_waiting(OUI, {Packet, Region}, add_stream(OUI, dialing, StateAcc));
                            dialing ->
                                lager:debug("stream is still dialing queueing packet"),
                                add_packet_to_waiting(OUI, {Packet, Region}, StateAcc);
                            {unverified, _Stream} ->
                                %% queue it until we get a banner
                                add_packet_to_waiting(OUI, {Packet, Region}, StateAcc);
                            Stream ->
                                lager:debug("got stream sending offer"),
                                send_packet_or_offer(Stream, OUI, Packet, Region, StateAcc)
                        end
                end
        end,
        State0,
        RoutesOrAddresses
        ).

-spec handle_purchase(Purchase :: blockchain_state_channel_purchase_v1:purchase(),
                      Stream :: pid(),
                      State :: state()) -> state().
handle_purchase(Purchase, Stream,
                #state{chain=Chain, pubkey_bin=PubkeyBin, sig_fun=SigFun}=State) ->
    PurchaseSC = blockchain_state_channel_purchase_v1:sc(Purchase),

    case is_valid_sc(PurchaseSC, State) of
        {error, causal_conflict} ->
            lager:error("causal_conflict for purchase sc: ~p", [PurchaseSC]),
            ok = append_state_channel(PurchaseSC, State),
            _ = libp2p_framed_stream:close(Stream),
            State;
        {error, _} ->
            _ = libp2p_framed_stream:close(Stream),
            State;
        ok ->
            Ledger = blockchain:ledger(Chain),
            DCBudget = blockchain_state_channel_v1:amount(PurchaseSC),
            TotalDCs = blockchain_state_channel_v1:total_dcs(PurchaseSC),
            RemainingDCs = max(0, DCBudget - TotalDCs),
            case blockchain_ledger_v1:is_state_channel_overpaid(PurchaseSC, Ledger) of
                true ->
                    lager:error("insufficient dcs for purchase sc: ~p: ~p - ~p = ~p", [PurchaseSC, DCBudget, TotalDCs, RemainingDCs]),
                    _ = libp2p_framed_stream:close(Stream),
                    %% we don't need to keep a sibling here as proof of misbehaviour is standalone
                    %% this will conflict or dominate any later attempt to close within spec
                    ok = overwrite_state_channel(PurchaseSC, State),
                    State;
                false ->
                    case dequeue_packet(Stream, State) of
                        {undefined, State0} ->
                            %% NOTE: We somehow don't have this packet in our queue,
                            %% All we do is store the state channel by overwriting instead of appending
                            %% since there was not a causal conflict
                            ok = overwrite_state_channel(PurchaseSC, State0),
                            State0;
                        {Packet, NewState} ->
                            Payload = blockchain_helium_packet_v1:payload(Packet),
                            PacketDCs = blockchain_utils:calculate_dc_amount(Ledger, byte_size(Payload)),
                            case RemainingDCs >= PacketDCs of
                                false ->
                                    lager:error("current packet (~p) (dc charge: ~p) will exceed remaining DCs (~p) in this SC, dropping",
                                                [Packet, PacketDCs, RemainingDCs]),
                                    _ = libp2p_framed_stream:close(Stream),
                                    NewState;
                                true ->
                                    %% now we need to make sure that our DC count between the previous
                                    %% and the current SC is _at least_ increased by this packet's
                                    %% DC cost.
                                    PrevTotal = get_previous_total_dcs(PurchaseSC, NewState),
                                    case (TotalDCs - PrevTotal) >= PacketDCs of
                                        true ->
                                            Region = blockchain_state_channel_purchase_v1:region(Purchase),
                                            lager:debug("successful purchase validation, sending packet: ~p",
                                                        [blockchain_helium_packet_v1:packet_hash(Packet)]),
                                            ok = send_packet(PubkeyBin, SigFun, Stream, Packet, Region),
                                            ok = overwrite_state_channel(PurchaseSC, NewState),
                                            NewState;
                                        false ->
                                            %% We are not getting paid, so drop this packet and
                                            %% do not send it. Close the stream.
                                            lager:error("purchase not valid - did not pay for packet: ~p, dropping.",
                                                        [Packet]),
                                            _ = libp2p_framed_stream:close(Stream),
                                            %% append this state channel, so we know about it later
                                            ok = overwrite_state_channel(PurchaseSC, NewState),
                                            NewState
                                    end
                            end
                    end
            end
    end.

-spec find_stream(AddressOrOUI :: stream_key(), State :: state()) -> stream_val().
find_stream(AddressOrOUI, #state{streams=Streams}) ->
    maps:get(AddressOrOUI, Streams, undefined).

-spec add_stream(AddressOrOUI :: non_neg_integer() | string(), Stream :: pid() | dialing, State :: state()) -> state().
add_stream(AddressOrOUI, Stream, #state{streams=Streams}=State) ->
    State#state{streams=maps:put(AddressOrOUI, {unverified, Stream}, Streams)}.

-spec delete_stream(AddressOrOUI :: non_neg_integer() | string(), State :: state()) -> state().
delete_stream(AddressOrOUI, #state{streams=Streams}=State) ->
    State#state{streams=maps:remove(AddressOrOUI, Streams)}.

lookup_stream_id(Pid, State) ->
    Result = maps:filter(fun(_Name, {unverified, Stream}) ->
                                          Stream == Pid;
                                     (_Name, Stream) ->
                                          Stream == Pid
                                  end, State#state.streams),
    case maps:size(Result) of
        0 ->
            undefined;
        1 ->
            hd(maps:keys(Result))
        %% more than one is an error
    end.

verify_stream(Stream, #state{streams=Streams}=State) ->
    AddressOrOUI = lookup_stream_id(Stream, State),
    State#state{streams=maps:update(AddressOrOUI, Stream, Streams)}.

-spec get_waiting_packet(AddressOrOUI :: waiting_key(), State :: state()) -> [waiting_packet()].
get_waiting_packet(AddressOrOUI, #state{waiting=Waiting}) ->
    maps:get(AddressOrOUI, Waiting, []).

-spec add_packet_to_waiting(AddressOrOUI :: waiting_key(),
                            WaitingPacket :: waiting_packet(),
                            State :: state()) -> state().
add_packet_to_waiting(AddressOrOUI, {Packet, Region}, #state{waiting=Waiting}=State) ->
    Q = get_waiting_packet(AddressOrOUI, State),
    State#state{waiting=maps:put(AddressOrOUI, Q ++ [{Packet, Region}], Waiting)}.

-spec remove_packet_from_waiting(AddressOrOUI :: waiting_key(), State :: state()) -> state().
remove_packet_from_waiting(AddressOrOUI, #state{waiting=Waiting}=State) ->
    State#state{waiting=maps:remove(AddressOrOUI, Waiting)}.

-spec enqueue_packet(Stream :: pid(),
                     Packet :: blockchain_helium_packet_v1:packet(),
                     State :: state()) -> state().
enqueue_packet(Stream, Packet, #state{packets=Packets}=State) ->
    State#state{packets=maps:update_with(Stream, fun(PacketList) -> queue:in(Packet, PacketList) end, queue:in(Packet, queue:new()), Packets)}.

-spec dequeue_packet(Stream :: pid(), State :: state()) -> {undefined | blockchain_helium_packet_v1:packet(), state()}.
dequeue_packet(Stream, #state{packets=Packets}=State) ->
    Queue = maps:get(Stream, Packets, queue:new()),
    case queue:out(Queue) of
        {empty, _} ->
            {undefined, State};
        {{value, ToPop}, NewQueue} ->
            {ToPop, State#state{packets=maps:update(Stream, NewQueue, Packets)}}
    end.

-spec find_routing(Packet :: blockchain_helium_packet_v1:packet(),
                   Chain :: blockchain:blockchain() | undefined) -> {ok, [blockchain_ledger_routing_v1:routing()]} | {error, any()}.
find_routing(_Packet, undefined) ->
    {error, no_chain};
find_routing(Packet, Chain) ->
    %% transitional shim for ignoring on-chain OUIs
    case application:get_env(blockchain, use_oui_routers, true) of
        true ->
            Ledger = blockchain:ledger(Chain),
            blockchain_ledger_v1:find_routing_for_packet(Packet, Ledger);
        false ->
            {error, oui_routing_disabled}
    end.

-spec dial(Swarm :: pid(),
           Address :: string() | blockchain_ledger_routing_v1:routing()) -> ok.
dial(Swarm, Address) when is_list(Address) ->
    Self = self(),
    erlang:spawn(
      fun() ->
              {P, R} =
                  erlang:spawn_monitor(
                    fun() ->
                            case blockchain_state_channel_handler:dial(Swarm, Address, []) of
                                {error, _Reason} ->
                                    Self ! {dial_fail, Address, _Reason};
                                {ok, Stream} ->
                                    unlink(Stream),
                                    Self ! {dial_success, Address, Stream}
                            end
                    end),
              receive
                  {'DOWN', R, process, P, normal} ->
                      ok;
                  {'DOWN', R, process, P, _Reason} ->
                      Self ! {dial_fail, Address, _Reason}
              end
      end),
    ok;
dial(Swarm, Route) ->
    Self = self(),
    erlang:spawn(
      fun() ->
              OUI = blockchain_ledger_routing_v1:oui(Route),
              {P, R} =
                  erlang:spawn_monitor(
                    fun() ->
                            Dialed = lists:foldl(
                                       fun(_PubkeyBin, {dialed, _}=Acc) ->
                                               Acc;
                                          (PubkeyBin, not_dialed) ->
                                               Address = libp2p_crypto:pubkey_bin_to_p2p(PubkeyBin),
                                               case blockchain_state_channel_handler:dial(Swarm, Address, []) of
                                                   {error, _Reason} ->
                                                       lager:error("failed to dial ~p:~p", [Address, _Reason]),
                                                       not_dialed;
                                                   {ok, Stream} ->
                                                       unlink(Stream),
                                                       {dialed, Stream}
                                               end
                                       end,
                                       not_dialed,
                                       blockchain_ledger_routing_v1:addresses(Route)
                                      ),
                            case Dialed of
                                not_dialed ->
                                    Self ! {dial_fail, OUI, failed};
                                {dialed, Stream} ->
                                    Self ! {dial_success, OUI, Stream}
                            end
                    end),
              receive
                  {'DOWN', R, process, P, normal} ->
                      ok;
                  {'DOWN', R, process, P, _Reason} ->
                      Self ! {dial_fail, OUI, failed}
              end
      end),
    ok.

-spec send_packet(PubkeyBin :: libp2p_crypto:pubkey_bin(),
                  SigFun :: libp2p_crypto:sig_fun(),
                  Stream :: pid(),
                  Packet :: blockchain_helium_packet_v1:packet(),
                  Region :: atom()  ) -> ok.
send_packet(PubkeyBin, SigFun, Stream, Packet, Region) ->
    PacketMsg0 = blockchain_state_channel_packet_v1:new(Packet, PubkeyBin, Region),
    PacketMsg1 = blockchain_state_channel_packet_v1:sign(PacketMsg0, SigFun),
    blockchain_state_channel_handler:send_packet(Stream, PacketMsg1).

-spec send_offer(PubkeyBin :: libp2p_crypto:pubkey_bin(),
                 SigFun :: libp2p_crypto:sig_fun(),
                 Stream :: pid(),
                 Packet :: blockchain_helium_packet_v1:packet(),
                 Region :: atom()  ) -> ok.
send_offer(PubkeyBin, SigFun, Stream, Packet, Region) ->
    OfferMsg0 = blockchain_state_channel_offer_v1:from_packet(Packet, PubkeyBin, Region),
    OfferMsg1 = blockchain_state_channel_offer_v1:sign(OfferMsg0, SigFun),
    lager:info("OfferMsg1: ~p", [OfferMsg1]),
    blockchain_state_channel_handler:send_offer(Stream, OfferMsg1).

-spec is_hotspot_in_router_oui(PubkeyBin :: libp2p_crypto:pubkey_bin(),
                               OUI :: pos_integer(),
                               Chain :: blockchain:blockchain()) -> boolean().
is_hotspot_in_router_oui(PubkeyBin, OUI, Chain) ->
    Ledger = blockchain:ledger(Chain),
    case blockchain_ledger_v1:find_gateway_info(PubkeyBin, Ledger) of
        {error, _} ->
            false;
        {ok, Gw} ->
            case blockchain_ledger_gateway_v2:oui(Gw) of
                undefined ->
                    false;
                OUI ->
                    true
            end
    end.

-spec send_packet_or_offer(Stream :: pid(),
                           OUI :: pos_integer(),
                           Packet :: blockchain_helium_packet_v1:packet(),
                           Region :: atom(),
                           State :: #state{}) -> #state{}.
send_packet_or_offer(Stream, OUI, Packet, Region,
                     #state{pubkey_bin=PubkeyBin, sig_fun=SigFun, chain=Chain}=State) ->
    SCVer = case blockchain:config(sc_version, blockchain:ledger(Chain)) of
                {ok, N} -> N;
                _ -> 1
            end,
    case (is_hotspot_in_router_oui(PubkeyBin, OUI, Chain) andalso SCVer >= 2) orelse SCVer == 1 of
        false ->
            ok = send_offer(PubkeyBin, SigFun, Stream, Packet, Region),
            enqueue_packet(Stream, Packet, State);
        true ->
            ok = send_packet(PubkeyBin, SigFun, Stream, Packet, Region),
            State
    end.

-spec send_packet_when_v1(Stream :: pid(),
                          Packet :: blockchain_helium_packet_v1:packet(),
                          Region :: atom(),
                          State :: #state{}) -> #state{}.
send_packet_when_v1(Stream, Packet, Region,
                    #state{pubkey_bin=PubkeyBin, sig_fun=SigFun, chain=Chain}=State) ->
    case blockchain:config(sc_version, blockchain:ledger(Chain)) of
        {ok, N} when N > 1 ->
            lager:debug("got stream sending offer"),
            ok = send_offer(PubkeyBin, SigFun, Stream, Packet, Region),
            enqueue_packet(Stream, Packet, State);
        _ ->
            lager:debug("got stream sending packet"),
            ok = send_packet(PubkeyBin, SigFun, Stream, Packet, Region),
            State
    end.

%% ------------------------------------------------------------------
%% State channel validation functions
%% ------------------------------------------------------------------
-spec is_valid_sc(SC :: blockchain_state_channel_v1:state_channel(),
                  State :: state()) -> ok | {error, any()}.
is_valid_sc(SC, State) ->
    case blockchain_state_channel_v1:validate(SC) of
        {error, Reason}=E ->
            lager:error("invalid sc, reason: ~p", [Reason]),
            E;
        ok ->
            case is_active_sc(SC, State) of
                {error, _}=E -> E;
                ok ->
                    case is_causally_correct_sc(SC, State) of
                        true ->
                            case is_overspent_sc(SC, State) of
                                true ->
                                    {error, overspent};
                                false ->
                                    ok
                            end;
                       false ->
                            {error, causal_conflict}
                    end
            end
    end.

-spec is_active_sc(SC :: blockchain_state_channel_v1:state_channel(),
                   State :: state()) -> ok | {error, no_chain} | {error, inactive_sc}.
is_active_sc(_, #state{chain=undefined}) ->
    {error, no_chain};
is_active_sc(SC, #state{chain=Chain}) ->
    Ledger = blockchain:ledger(Chain),
    SCOwner = blockchain_state_channel_v1:owner(SC),
    SCID = blockchain_state_channel_v1:id(SC),
    {ok, LedgerSCIDs} = blockchain_ledger_v1:find_sc_ids_by_owner(SCOwner, Ledger),
    case lists:member(SCID, LedgerSCIDs) of
        true -> ok;
        false -> {error, inactive_sc}
    end.

-spec is_causally_correct_sc(SC :: blockchain_state_channel_v1:state_channel(),
                             State :: state()) -> boolean().
is_causally_correct_sc(SC, State) ->
    SCID = blockchain_state_channel_v1:id(SC),

    case get_state_channels(SCID, State) of
        {error, not_found} ->
            true;
        {error, _} ->
            lager:error("rocks blew up"),
            %% rocks blew up
            false;
        {ok, [KnownSC]} ->
            %% Check if SC is causally correct
            Check = (caused == blockchain_state_channel_v1:compare_causality(KnownSC, SC) orelse
                     equal == blockchain_state_channel_v1:compare_causality(KnownSC, SC)),
            lager:info("causality check: ~p, this sc: ~p, known_sc: ~p", [Check, SC, KnownSC]),
            Check;
        {ok, KnownSCs} ->
            lager:error("multiple copies of state channels for id: ~p, found: ~p", [SCID, KnownSCs]),
            %% We have a conflict among incoming state channels
            false
    end.

is_overspent_sc(SC, State=#state{chain=Chain}) ->
    SCID = blockchain_state_channel_v1:id(SC),
    Ledger = blockchain:ledger(Chain),

    case get_state_channels(SCID, State) of
        {error, not_found} ->
            false;
        {error, _} ->
            lager:error("rocks blew up"),
            %% rocks blew up
            false;
        {ok, KnownSCs} ->
            lists:any(fun(E) -> blockchain_ledger_v1:is_state_channel_overpaid(E, Ledger) end, [SC|KnownSCs])
    end.

get_previous_total_dcs(SC, State) ->
    SCID = blockchain_state_channel_v1:id(SC),

    case get_state_channels(SCID, State) of
        {error, not_found} -> 0;
        {error, _} ->
            lager:error("rocks blew up"),
            0;
        {ok, [PreviousSC]} ->
            blockchain_state_channel_v1:total_dcs(PreviousSC);
        {ok, PrevSCs} ->
            lager:error("multiple copies of state channels for id: ~p, returning current total",
                        [PrevSCs]),
            %% returning this value will cause the test that we got paid to fail
            %% and the packet will get re-enqueued.
            blockchain_state_channel_v1:total_dcs(SC)
    end.

%% ------------------------------------------------------------------
%% DB functions
%% ------------------------------------------------------------------
-spec get_state_channels(SCID :: blockchain_state_channel_v1:id(),
                         State :: state()) ->
    {ok, [blockchain_state_channel_v1:state_channel()]} | {error, any()}.
get_state_channels(SCID, #state{db=DB, cf=CF}) ->
    case rocksdb:get(DB, CF, SCID, [{sync, true}]) of
        {ok, Bin} ->
            {ok, erlang:binary_to_term(Bin)};
        not_found ->
            {error, not_found};
        Error ->
            lager:error("error: ~p", [Error]),
            Error
    end.

-spec append_state_channel(SC :: blockchain_state_channel_v1:state_channel(),
                           State :: state()) -> ok | {error, any()}.
append_state_channel(SC, #state{db=DB, cf=CF}=State) ->
    SCID = blockchain_state_channel_v1:id(SC),
    case get_state_channels(SCID, State) of
        {ok, SCs} ->
            ToInsert = erlang:term_to_binary([SC | SCs]),
            rocksdb:put(DB, CF, SCID, ToInsert, [{sync, true}]);
        {error, not_found} ->
            ToInsert = erlang:term_to_binary([SC]),
            rocksdb:put(DB, CF, SCID, ToInsert, [{sync, true}]);
        {error, _}=E ->
            E
    end.

state_channels(#state{db=DB, cf=CF}) ->
    {ok, Itr} = rocksdb:iterator(DB, CF, []),
    state_channels(Itr, rocksdb:iterator_move(Itr, first), []).

state_channels(Itr, {error, invalid_iterator}, Acc) ->
    catch rocksdb:iterator_close(Itr),
    Acc;
state_channels(Itr, {ok, _, SCBin}, Acc) ->
    state_channels(Itr, rocksdb:iterator_move(Itr, next), [binary_to_term(SCBin)|Acc]).

-spec overwrite_state_channel(SC :: blockchain_state_channel_v1:state_channel(),
                              State :: state()) -> ok | {error, any()}.
overwrite_state_channel(SC, #state{db=DB, cf=CF}) ->
    SCID = blockchain_state_channel_v1:id(SC),
    ToInsert = erlang:term_to_binary([SC]),
    rocksdb:put(DB, CF, SCID, ToInsert, [{sync, true}]).

-spec close_state_channel(SC :: blockchain_state_channel_v1:state_channel(), State :: state()) -> ok.
close_state_channel(SC, State=#state{pubkey_bin=PubkeyBin, sig_fun=SigFun}) ->
    SCID = blockchain_state_channel_v1:id(SC),
    case get_state_channels(SCID, State) of
        {ok, [SC0]} ->
            %% just a single conflict locally, we can just send it
            Txn = blockchain_txn_state_channel_close_v1:new(SC0, SC, PubkeyBin),
            SignedTxn = blockchain_txn_state_channel_close_v1:sign(Txn, SigFun),
            ok = blockchain_worker:submit_txn(SignedTxn),
            lager:info("closing state channel on conflict ~p: ~p", [blockchain_state_channel_v1:id(SC), SignedTxn]);
        {ok, SCs} ->
            lager:warning("multiple conflicting SCs ~p", [length(SCs)]),
            %% TODO check for 'overpaid' state channels as well, not just causal conflicts
            %% see if we have any conflicts with the supplied close SC:
            case lists:filter(fun(E) -> conflicts(E, SC) end, SCs) of
                [] ->
                    lager:info("no direct conflict"),
                    %% find the latest state channel we have, and what it conflicts with
                    %%
                    %% first take the cartesian product of all the state channels, and select the conflicting ones
                    Conflicts = [ {A, B} || A <- SCs, B <- SCs, conflicts(A, B) ],
                    %% now try to find the ones with the highest balance (maximum refund guaranteed)
                    SortedConflicts = lists:sort(fun({A1, B1}, {A2, B2}) ->
                                                         V1 = num_dcs_for(PubkeyBin, A1),
                                                         V2 = num_dcs_for(PubkeyBin, B1),
                                                         V3 = num_dcs_for(PubkeyBin, A2),
                                                         V4 = num_dcs_for(PubkeyBin, B2),
                                                         max(V1, V2) =< max(V3, V4)
                                                 end, Conflicts),

                    case SortedConflicts of
                        [] ->
                            %% Only ever happens if a conflict has already been resolved during a core upgrade
                            ok;
                        L ->
                            {Conflict1, Conflict2} = lists:last(L),
                            Txn = blockchain_txn_state_channel_close_v1:new(Conflict1, Conflict2, PubkeyBin),
                            SignedTxn = blockchain_txn_state_channel_close_v1:sign(Txn, SigFun),
                            ok = blockchain_worker:submit_txn(SignedTxn)
                    end;
                Conflicts ->
                    %% sort the conflicts by the number of DCs they'd send to us
                    SortedConflicts = lists:sort(fun(C1, C2) ->
                                                         %% tuples can sort fine
                                                         blockchain_state_channel_v1:num_dcs_for(PubkeyBin, C1) =<
                                                         blockchain_state_channel_v1:num_dcs_for(PubkeyBin, C2)
                                                 end, Conflicts),
                    %% create a close using the SC with the most DC in our favor
                    Txn = blockchain_txn_state_channel_close_v1:new(lists:last(SortedConflicts), SC, PubkeyBin),
                    SignedTxn = blockchain_txn_state_channel_close_v1:sign(Txn, SigFun),
                    ok = blockchain_worker:submit_txn(SignedTxn),
                    lager:info("closing state channel on conflict ~p: ~p", [blockchain_state_channel_v1:id(SC), SignedTxn])
            end;
        _ ->
            ok
    end.

-spec conflicts(SCA :: blockchain_state_channel_v1:state_channel(),
                SCB :: blockchain_state_channel_v1:state_channel()) -> boolean().
conflicts(SCA, SCB) ->
    case blockchain_state_channel_v1:compare_causality(SCA, SCB) of
        conflict ->
            lager:info("sc_client reports state_channel conflict, SCA_ID: ~p, SCB_ID: ~p",
                       [libp2p_crypto:bin_to_b58(blockchain_state_channel_v1:id(SCA)),
                        libp2p_crypto:bin_to_b58(blockchain_state_channel_v1:id(SCB))]),
            true;
        _ ->
            false
    end.


num_dcs_for(PubkeyBin, SC) ->
    case blockchain_state_channel_v1:num_dcs_for(PubkeyBin, SC) of
        {ok, V} -> V;
        {error, not_found} -> 0
    end.
%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------

-ifdef(TEST).
-endif.
