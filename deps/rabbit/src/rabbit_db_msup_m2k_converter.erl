%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2023 Broadcom. All Rights Reserved. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries.  All rights reserved.
%%

-module(rabbit_db_msup_m2k_converter).

-behaviour(mnesia_to_khepri_converter).

-include_lib("kernel/include/logger.hrl").
-include_lib("khepri/include/khepri.hrl").
-include_lib("khepri_mnesia_migration/src/kmm_logging.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").
-include("mirrored_supervisor.hrl").

-export([init_copy_to_khepri/3,
         copy_to_khepri/3,
         delete_from_khepri/3]).

-record(?MODULE, {record_converters :: [module()]}).

-spec init_copy_to_khepri(StoreId, MigrationId, Tables) -> Ret when
      StoreId :: khepri:store_id(),
      MigrationId :: mnesia_to_khepri:migration_id(),
      Tables :: [mnesia_to_khepri:mnesia_table()],
      Ret :: {ok, Priv},
      Priv :: #?MODULE{}.
%% @private

init_copy_to_khepri(_StoreId, _MigrationId, Tables) ->
    %% Clean up any previous attempt to copy the Mnesia table to Khepri.
    lists:foreach(fun clear_data_in_khepri/1, Tables),

    Converters = discover_converters(?MODULE),
    SubState = #?MODULE{record_converters = Converters},
    {ok, SubState}.

-spec copy_to_khepri(Table, Record, State) -> Ret when
      Table :: mnesia_to_khepri:mnesia_table(),
      Record :: tuple(),
      State :: rabbit_db_m2k_converter:state(),
      Ret :: {ok, NewState} | {error, Reason},
      NewState :: rabbit_db_m2k_converter:state(),
      Reason :: any().
%% @private

copy_to_khepri(mirrored_sup_childspec = Table,
               #mirrored_sup_childspec{} = Record0,
               State) ->
    #?MODULE{record_converters = Converters} =
        rabbit_db_m2k_converter:get_sub_state(?MODULE, State),
    Record = upgrade_record(Converters, Table, Record0),
    #mirrored_sup_childspec{key = {Group, {SimpleId, _}} = Key} = Record,
    ?LOG_DEBUG(
       "Mnesia->Khepri data copy: [~0p] key: ~0p",
       [Table, Key],
       #{domain => ?KMM_M2K_TABLE_COPY_LOG_DOMAIN}),
    Path = rabbit_db_msup:khepri_mirrored_supervisor_path(Group, SimpleId),
    rabbit_db_m2k_converter:with_correlation_id(
      fun(CorrId) ->
              Extra = #{async => CorrId},
              ?LOG_DEBUG(
                 "Mnesia->Khepri data copy: [~0p] path: ~0p corr: ~0p",
                 [Table, Path, CorrId],
                 #{domain => ?KMM_M2K_TABLE_COPY_LOG_DOMAIN}),
              rabbit_khepri:put(Path, Record, Extra)
      end, State);
copy_to_khepri(Table, Record, State) ->
    ?LOG_DEBUG("Mnesia->Khepri unexpected record table ~0p record ~0p state ~0p",
               [Table, Record, State]),
    {error, unexpected_record}.

-spec delete_from_khepri(Table, Key, State) -> Ret when
      Table :: mnesia_to_khepri:mnesia_table(),
      Key :: any(),
      State :: rabbit_db_m2k_converter:state(),
      Ret :: {ok, NewState} | {error, Reason},
      NewState :: rabbit_db_m2k_converter:state(),
      Reason :: any().
%% @private

delete_from_khepri(mirrored_sup_childspec = Table, Key0, State) ->
    #?MODULE{record_converters = Converters} =
        rabbit_db_m2k_converter:get_sub_state(?MODULE, State),
    {Group, Id} = Key = upgrade_key(Converters, Table, Key0),
    ?LOG_DEBUG(
       "Mnesia->Khepri data delete: [~0p] key: ~0p",
       [Table, Key],
       #{domain => ?KMM_M2K_TABLE_COPY_LOG_DOMAIN}),
    Path = rabbit_db_msup:khepri_mirrored_supervisor_path(Group, Id),
    rabbit_db_m2k_converter:with_correlation_id(
      fun(CorrId) ->
              Extra = #{async => CorrId},
              ?LOG_DEBUG(
                 "Mnesia->Khepri data delete: [~0p] path: ~0p corr: ~0p",
                 [Table, Path, CorrId],
                 #{domain => ?KMM_M2K_TABLE_COPY_LOG_DOMAIN}),
              rabbit_khepri:delete(Path, Extra)
      end, State).

-spec clear_data_in_khepri(Table) -> ok when
      Table :: atom().

clear_data_in_khepri(mirrored_sup_childspec) ->
    Path = rabbit_db_msup:khepri_mirrored_supervisor_path(),
    case rabbit_khepri:delete(Path) of
        ok -> ok;
        Error -> throw(Error)
    end.

%% Khepri paths don't support tuples or records, so the key part of the
%% #mirrored_sup_childspec{} used by some plugins must be  transformed in a
%% valid Khepri path during the migration from Mnesia to Khepri.
%% `rabbit_db_msup_m2k_converter` iterates over all declared converters, which
%% must implement `rabbit_mnesia_to_khepri_record_converter` behaviour callbacks.
%%
%% This mechanism could be reused by any other rabbit_db_*_m2k_converter

discover_converters(MigrationMod) ->
    Apps = rabbit_misc:rabbitmq_related_apps(),
    AttrsPerApp = rabbit_misc:module_attributes_from_apps(
                    rabbit_mnesia_records_to_khepri_db, Apps),
    discover_converters(MigrationMod, AttrsPerApp, []).

discover_converters(MigrationMod, [{_App, _AppMod, AppConverters} | Rest],
                           Converters0) ->
    Converters =
        lists:foldl(fun({Module, Mod}, Acc) when Module =:= MigrationMod ->
                            [Mod | Acc];
                       (_, Acc) ->
                            Acc
                    end, Converters0, AppConverters),
    discover_converters(MigrationMod, Rest, Converters);
discover_converters(_MigrationMod, [], Converters) ->
    Converters.

upgrade_record(Converters, Table, Record) ->
    lists:foldl(fun(Mod, Record0) ->
                        Mod:upgrade_record(Table, Record0)
                end, Record, Converters).

upgrade_key(Converters, Table, Key) ->
    lists:foldl(fun(Mod, Key0) ->
                        Mod:upgrade_key(Table, Key0)
                end, Key, Converters).
