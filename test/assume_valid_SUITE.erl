-module(assume_valid_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("blockchain.hrl").

-export([
    all/0
]).

-export([
    basic/1,
    blockchain_restart/1,
    blockchain_almost_synced/1,
    blockchain_crash_while_absorbing/1
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
    [basic, blockchain_restart, blockchain_almost_synced, blockchain_crash_while_absorbing].

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

basic(_Config) ->
    BaseDir = "data/assume_valid_SUITE/basic",
    Balance = 5000,
    BlocksN = 100,
    {ok, _Sup, {PrivKey, PubKey}, _Opts} = test_utils:init(BaseDir),
    {ok, ConsensusMembers, _} = test_utils:init_chain(Balance, {PrivKey, PubKey}),
    Chain0 = blockchain_worker:blockchain(),
    {ok, Genesis} = blockchain:genesis_block(Chain0),

    % Add some blocks
    Blocks = lists:reverse(lists:foldl(
        fun(_, Acc) ->
            Block = test_utils:create_block(ConsensusMembers, []),
            blockchain:add_block(Block, Chain0),
            [Block|Acc]
        end,
        [],
        lists:seq(1, BlocksN)
    )),
    LastBlock = lists:last(Blocks),

    SimDir = "data/assume_valid_SUITE/basic_sim",
    {ok, Chain} = blockchain:new(SimDir, Genesis, blockchain_block:hash_block(LastBlock)),

    ?assertEqual({ok, 1}, blockchain:height(Chain)),
    %% this should fail without all the supporting blocks
    blockchain:add_block(LastBlock, Chain),
    ?assertEqual({ok, 1}, blockchain:height(Chain)),
    ok = blockchain:add_blocks(Blocks -- [LastBlock], Chain),
    ?assertEqual({ok, 1}, blockchain:height(Chain)),
    ?assertEqual({ok, 100}, blockchain:sync_height(Chain)),
    ok = blockchain:add_block(LastBlock, Chain),
    ?assertEqual({ok, 101}, blockchain:height(Chain)),
    ?assertEqual({ok, 101}, blockchain:sync_height(Chain)),
    ok.

blockchain_restart(_Config) ->
    BaseDir = "data/assume_valid_SUITE/blockchain_restart",
    Balance = 5000,
    BlocksN = 100,
    {ok, _Sup, {PrivKey, PubKey}, _Opts} = test_utils:init(BaseDir),
    {ok, ConsensusMembers, _} = test_utils:init_chain(Balance, {PrivKey, PubKey}),
    Chain0 = blockchain_worker:blockchain(),
    {ok, Genesis} = blockchain:genesis_block(Chain0),

    % Add some blocks
    Blocks = lists:reverse(lists:foldl(
        fun(_, Acc) ->
            Block = test_utils:create_block(ConsensusMembers, []),
            blockchain:add_block(Block, Chain0),
            [Block|Acc]
        end,
        [],
        lists:seq(1, BlocksN)
    )),
    LastBlock = lists:last(Blocks),

    SimDir = "data/assume_valid_SUITE/blockchain_restart_sim",
    {ok, Chain} = blockchain:new(SimDir, Genesis, blockchain_block:hash_block(LastBlock)),

    ?assertEqual({ok, 1}, blockchain:height(Chain)),
    ok = blockchain:add_blocks(Blocks -- [LastBlock], Chain),
    ?assertEqual({ok, 1}, blockchain:height(Chain)),
    ?assertEqual({ok, 100}, blockchain:sync_height(Chain)),
    %% simulate the node stopping or crashing
    blockchain:close(Chain),
    {ok, Chain1} = blockchain:new(SimDir, Genesis, blockchain_block:hash_block(LastBlock)),
    ?assertEqual({ok, 1}, blockchain:height(Chain1)),
    ?assertEqual({ok, 100}, blockchain:sync_height(Chain1)),
    ok = blockchain:add_block(LastBlock, Chain1),
    ?assertEqual({ok, 101}, blockchain:height(Chain1)),
    ?assertEqual({ok, 101}, blockchain:sync_height(Chain1)),
    ok.

blockchain_almost_synced(_Config) ->
    BaseDir = "data/assume_valid_SUITE/blockchain_almost_synced",
    Balance = 5000,
    BlocksN = 100,
    {ok, _Sup, {PrivKey, PubKey}, _Opts} = test_utils:init(BaseDir),
    {ok, ConsensusMembers, _} = test_utils:init_chain(Balance, {PrivKey, PubKey}),
    Chain0 = blockchain_worker:blockchain(),
    {ok, Genesis} = blockchain:genesis_block(Chain0),

    % Add some blocks
    Blocks = lists:reverse(lists:foldl(
        fun(_, Acc) ->
            Block = test_utils:create_block(ConsensusMembers, []),
            blockchain:add_block(Block, Chain0),
            [Block|Acc]
        end,
        [],
        lists:seq(1, BlocksN)
    )),
    LastBlock = lists:last(Blocks),

    SimDir = "data/assume_valid_SUITE/blockchain_almost_synced_sim",
    {ok, Chain} = blockchain:new(SimDir, Genesis, undefined),

    ?assertEqual({ok, 1}, blockchain:height(Chain)),
    ok = blockchain:add_blocks(Blocks -- [LastBlock], Chain),
    ?assertEqual({ok, 100}, blockchain:height(Chain)),
    ?assertEqual({ok, 100}, blockchain:sync_height(Chain)),
    %% simulate the node stopping or crashing
    blockchain:close(Chain),
    %% re-open with the assumed-valid hash supplied, like if we got an OTA
    {ok, Chain1} = blockchain:new(SimDir, Genesis, blockchain_block:hash_block(LastBlock)),
    ?assertEqual({ok, 100}, blockchain:height(Chain1)),
    ?assertEqual({ok, 100}, blockchain:sync_height(Chain1)),
    ok = blockchain:add_block(LastBlock, Chain1),
    ?assertEqual({ok, 101}, blockchain:height(Chain1)),
    ?assertEqual({ok, 101}, blockchain:sync_height(Chain1)),
    ok.

blockchain_crash_while_absorbing(_Config) ->
    BaseDir = "data/assume_valid_SUITE/blockchain_crash_while_absorbing",
    Balance = 5000,
    BlocksN = 100,
    {ok, _Sup, {PrivKey, PubKey}, _Opts} = test_utils:init(BaseDir),
    {ok, ConsensusMembers, _} = test_utils:init_chain(Balance, {PrivKey, PubKey}),
    Chain0 = blockchain_worker:blockchain(),
    {ok, Genesis} = blockchain:genesis_block(Chain0),

    % Add some blocks
    Blocks = lists:reverse(lists:foldl(
        fun(_, Acc) ->
            Block = test_utils:create_block(ConsensusMembers, []),
            blockchain:add_block(Block, Chain0),
            [Block|Acc]
        end,
        [],
        lists:seq(1, BlocksN)
    )),
    LastBlock = lists:last(Blocks),
    ExplodeBlock = lists:nth(50, Blocks),

    SimDir = "data/assume_valid_SUITE/blockchain_crash_while_absorbing_sim",
    {ok, Chain} = blockchain:new(SimDir, Genesis, blockchain_block:hash_block(LastBlock)),

    meck:new(blockchain_txn, [passthrough]),
    meck:expect(blockchain_txn, unvalidated_absorb_and_commit,
                fun(B, C, BC, R) ->
                        case B == ExplodeBlock of
                            true ->
                                blockchain_lock:release(),
                                error(explode);
                            false ->
                                meck:passthrough([B, C, BC, R])
                        end
                end),

    ?assertEqual({ok, 1}, blockchain:height(Chain)),
    ?assertError(explode, blockchain:add_blocks(Blocks, Chain)),
    ?assertEqual({ok, 50}, blockchain:height(Chain)),
    meck:unload(blockchain_txn),
    %% simulate the node stopping or crashing
    blockchain:close(Chain),
    %% re-open with the assumed-valid hash supplied, like if we got an OTA
    {ok, Chain1} = blockchain:new(SimDir, Genesis, blockchain_block:hash_block(LastBlock)),
    %% the sync height should be 100 because we didn't write the assumed valid block
    ?assertEqual({ok, 100}, blockchain:sync_height(Chain1)),
    %% the actual height should be right before the explode block
    ?assertEqual({ok, 50}, blockchain:height(Chain1)),
    %% check the hashes
    ?assertEqual(blockchain:head_hash(Chain1), {ok, blockchain_block:prev_hash(ExplodeBlock)}),
    ?assertEqual(blockchain:sync_hash(Chain1), {ok, blockchain_block:prev_hash(LastBlock)}),
    %% add the final block again
    blockchain:add_block(LastBlock, Chain1),
    ?assertEqual({ok, 101}, blockchain:sync_height(Chain1)),
    %% the actual height should be right before the explode block
    ?assertEqual({ok, 101}, blockchain:height(Chain1)),
    ok.
