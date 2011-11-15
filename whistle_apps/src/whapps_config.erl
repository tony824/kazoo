%%%-------------------------------------------------------------------
%%% @author Karl Anderson <karl@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%% @end
%%% Created : 8 Nov 2011 by Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(whapps_config).

-include("whistle_apps.hrl").

-export([get/2, get/3, set/3, set_default/3]).
-export([flush/0, import/1]).

%%-----------------------------------------------------------------------------
%% @public
%% @doc
%% get a configuration key for a given category
%%
%% Also, when looking up the key see if there is a value specific to this
%% node but if there is not then use the default value.
%% @end
%%-----------------------------------------------------------------------------
-spec get/2 :: (Category, Key) -> term() | undefined when
      Category :: binary() | string() | atom(),
      Key :: binary() | string() | atom().
-spec get/3 :: (Category, Key, Default) -> term() | Default when
      Category :: binary() | string() | atom(),
      Key :: binary() | string() | atom(),
      Default :: term().

get(Category, Key) ->
    get(Category, Key, undefined).

get(Category, Key, Default) when not is_binary(Category)->
    get(wh_util:to_binary(Category), Key, Default);
get(Category, Key, Default) when not is_binary(Key)->
    get(Category, wh_util:to_binary(Key), Default);
get(Category, Key, Default) ->
    {ok, Cache} = whistle_apps_sup:config_cache_proc(),
    case fetch_category(Category, Cache) of
        {ok, JObj} ->
            Node = wh_util:to_binary(node()),
            case wh_json:get_value([Node, Key], JObj) of
                undefined ->
                    case wh_json:get_value([<<"default">>, Key], JObj) of
                        undefined ->
                            ?LOG("missing key ~s(~s) ~s: ~p", [Category, Node, Key, Default]),
                            Default =/= undefined andalso
                                spawn(fun() -> ?MODULE:set(Category, Key, Default) end),
                            Default;
                        Else ->
                            ?LOG("fetched config ~s(~s) ~s: ~p", [Category, "default", Key, Else]),
                            Else
                    end;
                Else ->
                    ?LOG("fetched config ~s(~s) ~s: ~p", [Category, Node, Key, Else]),
                    Else
            end;
        {error, _} ->
            ?LOG("missing category ~s(~s) ~s: ~p", [Category, "default", Key, Default]),
            Default
    end.

%%-----------------------------------------------------------------------------
%% @public
%% @doc
%% set the key to the value in the given category but specific to this node
%% @end
%%-----------------------------------------------------------------------------
-spec set/3 :: (Category, Key, Value) -> {ok, json_object()} when
      Category :: binary() | string() | atom(),
      Key :: binary() | string() | atom(),
      Value :: term().
set(Category, Key, Value) ->
    do_set(Category, wh_util:to_binary(node()), Key, Value).

%%-----------------------------------------------------------------------------
%% @public
%% @doc
%% set the key to the value in the given category but in the default (global)
%% section
%% @end
%%-----------------------------------------------------------------------------
-spec set_default/3 :: (Category, Key, Value) -> {ok, json_object()} when
      Category :: binary() | string() | atom(),
      Key :: binary() | string() | atom(),
      Value :: term().
set_default(Category, Key, Value) ->
    do_set(Category, <<"default">>, Key, Value).

%%-----------------------------------------------------------------------------
%% @public
%% @doc
%% flush the configuration cache
%% @end
%%-----------------------------------------------------------------------------
-spec flush/0 :: () -> ok.
flush() ->
    {ok, Cache} = whistle_apps_sup:config_cache_proc(),
    wh_cache:flush_local(Cache).

%%-----------------------------------------------------------------------------
%% @public
%% @doc
%% import any new configuration options for the given category from the flat
%% file (can be used when a new option is added)
%% @end
%%-----------------------------------------------------------------------------
-spec import/1 :: (Category) -> {ok, json_object()} | {error, not_found} when
      Category :: binary() | string() | atom().
import(Category) when not is_binary(Category) ->
    import(wh_util:to_binary(Category));
import(Category) ->
    {ok, Cache} = whistle_apps_sup:config_cache_proc(),
    fetch_file_config(Category, Cache).

%%-----------------------------------------------------------------------------
%% @private
%% @doc
%% fetch a given configuration category from (in order):
%% 1. from the cache
%% 2. from the db
%% 3. from a flat file
%% @end
%%-----------------------------------------------------------------------------
-spec fetch_category/2 :: (Category, Cache) -> {ok, json_object()} | {error, not_found} when
      Category :: binary(),
      Cache :: pid().
fetch_category(Category, Cache) ->
    Lookups = [fun fetch_file_config/2
               ,fun fetch_db_config/2
               ,fun(Cat, C) -> ?LOG("Trying cache for ~s", [Cat]), wh_cache:peek_local(C, {?MODULE, Cat}) end],
    lists:foldr(fun(_, {ok, _}=Acc) -> Acc;
                   (F, _) -> F(Category, Cache)
                end, {error, not_found}, Lookups).

%%-----------------------------------------------------------------------------
%% @private
%% @doc
%% try to fetch the configuration category from the database, if successful
%% cache it
%% @end
%%-----------------------------------------------------------------------------
-spec fetch_db_config/2 :: (Category, Cache) -> {ok, json_object()} | {error, not_found} when
      Category :: binary(),
      Cache :: pid().
fetch_db_config(Category, Cache) ->
    ?LOG("Trying DB for ~s", [Category]),
    case couch_mgr:open_doc(?CONFIG_DB, Category) of
        {ok, JObj}=Ok ->
            wh_cache:store_local(Cache, {?MODULE, Category}, JObj),
            Ok;
        {error, _E} ->
            ?LOG("could not fetch config ~s from db: ~p", [Category, _E]),
            {error, not_found}
    end.

%%-----------------------------------------------------------------------------
%% @private
%% @doc
%% try to fetch the configuration category from a flat file, if successful
%% save it to the db and cache it
%% @end
%%-----------------------------------------------------------------------------
-spec fetch_file_config/2 :: (Category, Cache) -> {ok, json_object()} | {error, not_found} when
      Category :: binary(),
      Cache :: pid().
fetch_file_config(Category, Cache) ->
    File = category_to_file(Category),

    ?LOG("Trying file ~s for ~s", [File, Category]),
    case file:consult(File) of
        {ok, Terms} ->
            JObj = config_terms_to_json(Terms),
            UpdateFun = fun(J) ->
                                ?LOG("initializing ~s from ~s", [Category, File]),
                                DefaultConfig = wh_json:get_value(<<"default">>, J, wh_json:new()),
                                wh_json:merge_jobjs(DefaultConfig, JObj)
                        end,
            update_category_node(Category, <<"default">>, UpdateFun, Cache);
        {error, _}=E ->
            ?LOG("failed to imported default configuration from ~s: ~p", [File, E]),
            {error, not_found}
    end.

%%-----------------------------------------------------------------------------
%% @private
%% @doc
%% convert the result of the file consult into a json object
%% @end
%%-----------------------------------------------------------------------------
-spec config_terms_to_json/1 :: (Terms) -> json_object() when
      Terms :: list().
config_terms_to_json(Terms) ->
    wh_json:from_list([{wh_util:to_binary(K), V} || {K, V} <- Terms]).

%%-----------------------------------------------------------------------------
%% @private
%% @doc
%% does the actual work of setting the key to the value in the given category
%% for the given node
%% @end
%%-----------------------------------------------------------------------------
-spec do_set/4 :: (Category, Node, Key, Value) -> {ok, json_object()} when
      Category :: binary() | string() | atom(),
      Node :: binary() | string() | atom(),
      Key :: binary() | string() | atom(),
      Value :: term().
do_set(Category, Node, Key, Value) when not is_binary(Category) ->
    do_set(wh_util:to_binary(Category), Node, Key, Value);
do_set(Category, Node, Key, Value) when not is_binary(Node) ->
    do_set(Category, wh_util:to_binary(Node), Key, Value);
do_set(Category, Node, Key, Value) when not is_binary(Key) ->
    do_set(Category, Node, wh_util:to_binary(Key), Value);
do_set(Category, Node, Key, Value) ->
    {ok, Cache} = whistle_apps_sup:config_cache_proc(),
    UpdateFun = fun(J) ->
                        ?LOG("setting configuration ~s(~s) ~s: ~p", [Category, Node, Key, Value]),
                        NodeConfig = wh_json:get_value(Node, J, wh_json:new()),
                        wh_json:set_value(wh_util:to_binary(Key), Value, NodeConfig)
                end,
    update_category_node(Category, Node, UpdateFun, Cache).

%%-----------------------------------------------------------------------------
%% @private
%% @doc
%% update the configuration category for a given node in both the db and cache
%% @end
%%-----------------------------------------------------------------------------
-spec update_category_node/4 :: (Category, Node, UpdateFun , Cache) -> {ok, json_object()} when
      Category :: binary(),
      Node :: binary(),
      UpdateFun :: fun(),
      Cache :: pid().
update_category_node(Category, Node, UpdateFun , Cache) ->
    case couch_mgr:open_doc(?CONFIG_DB, Category) of
        {ok, JObj} ->
            case wh_json:set_value(Node, UpdateFun(JObj), JObj) of
                JObj -> {ok, JObj};
                UpdatedCat -> update_category(Category, UpdatedCat, Cache)
            end;
        {error, _} ->
            NewCat = wh_json:set_value(Node, UpdateFun(wh_json:new()), wh_json:new()),
            update_category(Category, NewCat, Cache)
    end.

%%-----------------------------------------------------------------------------
%% @private
%% @doc
%% update the entire category in both the db and cache
%% @end
%%-----------------------------------------------------------------------------
-spec update_category/3 :: (Category, JObj, Cache) -> {ok, json_object()} when
      Category :: binary(),
      JObj :: json_object(),
      Cache :: pid().
update_category(Category, JObj, Cache) ->
    ?LOG("updating configuration category ~s", [Category]),
    JObj1 = wh_json:set_value(<<"_id">>, Category, JObj),
    {ok, SavedJObj} = couch_mgr:ensure_saved(?CONFIG_DB, JObj1),
    ?LOG("Saved cat ~s to db ~s", [Category, ?CONFIG_DB]),
    wh_cache:store_local(Cache, {?MODULE, Category}, SavedJObj),
    {ok, SavedJObj}.

%%-----------------------------------------------------------------------------
%% @private
%% @doc
%% convert the category name to a corresponding flat file that contains those
%% initial (default) settings
%% @end
%%-----------------------------------------------------------------------------
-spec category_to_file/1 :: (Category) -> list() | undefined when
      Category :: binary().
category_to_file(<<"whapps_controller">>) ->
    [code:lib_dir(whistle_apps, priv), "/startup.config"];
category_to_file(<<"notify_vm">>) ->
    [code:lib_dir(notify, priv), "/notify_vm.config"];
category_to_file(<<"smtp_client">>) ->
    [code:lib_dir(whistle_apps, priv), "/smtp_client.config"];
category_to_file(<<"alerts">>) ->
    [code:lib_dir(whistle_apps, priv), "/alerts.config"];
category_to_file(_) ->
    undefined.
