-module(aws_metadata).

-behaviour(gen_server).

-define(CREDENTIAL_URL,
        <<"http://169.254.169.254/latest/meta-data/iam/security-credentials/">>).
-define(DOCUMENT_URL,
        <<"http://169.254.169.254/latest/dynamic/instance-identity/document">>).
%% As per
%% http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/iam-roles-for-amazon-ec2.html#instance-metadata-security-credentials
%% We make new credentials available at least five minutes prior to the
%% expiration of the old credentials.
-define(ALERT_BEFORE_EXPIRY, 4 * 60).

-export([init/1
        ,terminate/2
        ,code_change/3
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ]).

-export([start_link/0
        ,stop/0
        ,get_client/0
        ]).

-record(state, {client = undefined :: map() | undefined}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the server that stores and automatically updates client
%% credentials fetched from the instance metadata service.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Stop the server that holds the credentials.
stop() ->
    gen_server:stop(?MODULE).

%% @doc Get the client built with data fetched from the instance metadata
%% service.
get_client() ->
    gen_server:call(?MODULE, get_client).

%%====================================================================
%% Behaviour
%%====================================================================

init(_Args) ->
    {ok, Client} = fetch_client(),
    {ok, #state{client=Client}}.

terminate(_Reason, _State) ->
    ok.

handle_call(get_client, _From, State=#state{client=Client}) ->
    {reply, Client, State};
handle_call(Args, _From, State) ->
    error_logger:warning_msg("Unknown call: ~p~n", [Args]),
    {noreply, State}.

handle_cast(Message, State) ->
    error_logger:warning_msg("Unknown cast: ~p~n", [Message]),
    {noreply, State}.

handle_info(refresh_client, State) ->
    {ok, Client} = fetch_client(),
    {noreply, State=#state{client=Client}};
handle_info(Message, State) ->
    error_logger:warning_msg("Unknown message: ~p~n", [Message]),
    {noreply, State}.

code_change(_Prev, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================

fetch_client() ->
    {ok, Role} = fetch_role(),
    {ok, AccessKeyID, SecretAccessKey, ExpirationTime} = fetch_metadata(Role),
    {ok, Region} = fetch_document(),
    Client = aws_client:make_client(AccessKeyID, SecretAccessKey, Region),
    setup_update_callback(ExpirationTime),
    {ok, Client}.

fetch_role() ->
    {ok, 200, _, ClientRef} = hackney:get(?CREDENTIAL_URL),
    hackney:body(ClientRef).

fetch_metadata(Role) ->
    {ok, 200, _, ClientRef} = hackney:get([?CREDENTIAL_URL, Role]),
    {ok, Body} = hackney:body(ClientRef),
    Map = jsx:decode(Body, [return_maps]),
    {ok, maps:get(<<"AccessKeyId">>, Map),
     maps:get(<<"SecretAccessKey">>, Map),
     maps:get(<<"Expiration">>, Map)}.

fetch_document() ->
    {ok, 200, _, ClientRef} = hackney:get(?DOCUMENT_URL),
    {ok, Body} = hackney:body(ClientRef),
    Map = jsx:decode(Body, [return_maps]),
    {ok, maps:get(<<"region">>, Map)}.

setup_update_callback(Timestamp) ->
    RefreshAfter = seconds_until_timestamp(Timestamp) - ?ALERT_BEFORE_EXPIRY,
    erlang:send_after(RefreshAfter, ?MODULE, refresh_client).

seconds_until_timestamp(Timestamp) ->
    calendar:datetime_to_gregorian_seconds(iso8601:parse(Timestamp))
    - (erlang_system_seconds()
       + calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})).

erlang_system_seconds() ->
    try
        erlang:system_time(seconds)
    catch
        error:undef -> % Pre 18.0
            {MegaSecs, Secs, MicroSecs} = os:timestamp(),
            round(((MegaSecs * 1000000 + Secs) * 1000000 + MicroSecs) / 1000000)
    end.
