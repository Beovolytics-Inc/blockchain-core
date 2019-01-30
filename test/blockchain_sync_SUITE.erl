-module(blockchain_sync_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("blockchain.hrl").

-export([
    all/0
]).

-export([
    basic/1
]).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [basic].

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
basic(_Config) ->
    BaseDir = "data/sync_SUITE/basic",
    Balance = 5000,
    BlocksN = 100,
    {ok, Sup, {PrivKey, PubKey}, _Opts} = test_utils:init(BaseDir),
    {ok, ConsensusMembers} = test_utils:init_chain(Balance, {PrivKey, PubKey}),
    Chain0 = blockchain_worker:blockchain(),
    {ok, Genesis} = blockchain:genesis_block(Chain0),

    % Simulate other chain with sync handler only
    {ok, SimSwarm} = libp2p_swarm:start(sync_SUITE_sim, [{libp2p_nat, [{enabled, false}]}]),
    ok = libp2p_swarm:listen(SimSwarm, "/ip4/0.0.0.0/tcp/0"),
    SimDir = "data/sync_SUITE/basic_sim",
    Chain = blockchain:new(SimDir, Genesis),

    % Add some blocks
    Blocks = lists:reverse(lists:foldl(
        fun(_, Acc) ->
            Block = test_utils:create_block(ConsensusMembers, []),
            _ = blockchain_gossip_handler:add_block(blockchain_swarm:swarm(), Block, Chain0, length(ConsensusMembers), blockchain_swarm:address()),
            [Block|Acc]
        end,
        [],
        lists:seq(1, BlocksN)
    )),
    LastBlock = lists:last(Blocks),

    ok = libp2p_swarm:add_stream_handler(
        SimSwarm
        ,?SYNC_PROTOCOL
        ,{libp2p_framed_stream, server, [c, ?MODULE, Chain]}
    ),
    % This is just to connect the 2 swarms
    [ListenAddr|_] = libp2p_swarm:listen_addrs(blockchain_swarm:swarm()),
    {ok, _} = libp2p_swarm:connect(SimSwarm, ListenAddr),
    ok = test_utils:wait_until(fun() -> erlang:length(libp2p_peerbook:values(libp2p_swarm:peerbook(blockchain_swarm:swarm()))) > 1 end),

    % Simulate add block from other chain
    _ = blockchain_gossip_handler:add_block(SimSwarm, LastBlock, Chain0, length(ConsensusMembers), libp2p_swarm:pubkey_bin(SimSwarm)),

    ok = test_utils:wait_until(fun() ->{ok, BlocksN + 1} =:= blockchain:height(Chain0) end),
    ?assertEqual({ok, LastBlock}, blockchain:head_block(blockchain_worker:blockchain())),
    true = erlang:exit(Sup, normal),
    ok.

