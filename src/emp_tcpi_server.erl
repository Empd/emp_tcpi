%% EMP_TCPi_Server.erl
%%
%% @copyright 2011-2012 The EMP Group <http://www.emp-d.com/>
%% @end
%%
%% This library is free software; you can redistribute it and/or
%% modify it under the terms of the GNU Lesser General Public
%% License as published by the Free Software Foundation; either 
%% version 2.1 of the License, or (at your option) any later version.
%% 
%% This library is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%% Lesser General Public License for more details.
%% 
%% You should have received a copy of the GNU Lesser General Public
%% License along with this library.  If not, see <http://www.gnu.org/licenses/>.
%% ----------------------------------------------------------------------------
%% @doc 
%%  
%% @end
%% ----------------------------------------------------------------------------
-module(emp_tcpi_server).
-behaviour(gen_server).

%% External exports
-export([start_link/0, start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, 
         handle_info/2, terminate/2, code_change/3]).

%% Used internally only
-export([child_accept/1]).

-record(state, {
        port :: inet:port_number(),
        client_handle_fun :: fun((gen_tcp:socket()) -> any()),
        current_child_acceptor :: pid(),    % The child currently waiting on a connection
        lsocket :: gen_tcp:socket(),
        children_with_clients=[] :: [{pid()}]   % The child pids that are handling client connections
    }).
% TODO Set a hard limit on the number of concurrent connections allowed by 
%   checking against length of children_with_clients.  Currently no limit.

%% TCP options for our listening socket.  We want to receive the data as a
%% list (not binary), have no packet size decoded from the packet (raw), 
%% reuse local port numbers
%% TODO Investigate other TCP packet options
-define(TCP_OPTIONS, [list, {packet, raw}, {active, false}, {reuseaddr, false}]).
-define(SHUTDOWN_MESSAGE, shutdown).
-define(REG_PROC, ?MODULE). %name of process for registration

%% ====================================================================
%% External functions
%% ====================================================================
start_link() ->
    {ok, Port} = application:get_env(emp_tcpi_app, tcp_port),
    emp_tcpi_server:start_link( Port ).

start_link(Port) ->
    emplog:debug("emptcp trying to start_link on ~p\n",[Port]),
    gen_server:start_link({global, ?REG_PROC}, ?MODULE, [Port], []).

%% ====================================================================
%% Server functions
%% ====================================================================

%% --------------------------------------------------------------------
%% Function: init/1
%% Description: Initiates the server
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%% --------------------------------------------------------------------
-spec init([ inet:port_number() ]) -> {ok, #state{}} | {stop, Reason::any()}.

%% init() ->
%%  {ok, Port} = application:get_env(emptcp, port),
%%  init([Port]);

init([Port]) ->
    %emplog:debug("emptcp trying to init on ~p\n",[Port]),
    process_flag(trap_exit, true),
    case gen_tcp:listen(Port, ?TCP_OPTIONS) of
        {ok, LSocket} ->
            emplog:debug(io_lib:format("Emp tcp interface server started on port ~p",[Port])),
            NewState = #state{lsocket = LSocket, client_handle_fun = fun emp_tcpi_client:init_conn/1},
            {ok, spawn_child_acceptor(NewState)};
        {error, Reason} ->
            {stop, Reason}
    end.

%% --------------------------------------------------------------------
%% Function: handle_call/3
%% Description: Handling call messages
%% Returns: {reply, Reply, State}          |
%%          {reply, Reply, State, Timeout} |
%%          {noreply, State}               |
%%          {noreply, State, Timeout}      |
%%          {stop, Reason, Reply, State}   | (terminate/2 is called)
%%          {stop, Reason, State}            (terminate/2 is called)
%% --------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%% --------------------------------------------------------------------
%% Function: handle_cast/2
%% Description: Handling cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%% --------------------------------------------------------------------

%% current_child_acceptor accepted a new connection
handle_cast({accepted, AcceptorPid}, State=#state{current_child_acceptor=AcceptorPid, children_with_clients=ChildList}) ->
    {noreply, spawn_child_acceptor( State#state{children_with_clients=[{AcceptorPid} | ChildList]} )};

%% Someone other than the AcceptorPid sent an accepted message - someone's messing with us
%% Get rid of this once we know the module is perfect?
handle_cast({accepted, Pid}, State=#state{}) ->
    emplog:warn( io_lib:format("~p: The pid ~p, who is not the current_child_acceptor, casted an accepted message",[?MODULE, Pid]) ),
    {noreply, State};

handle_cast(_Msg, State=#state{}) ->
    {noreply, State}.

%% --------------------------------------------------------------------
%% Function: handle_info/2
%% Description: Handling all non call/cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%% --------------------------------------------------------------------

%% A child exited.  If it's the current_child_acceptor, make a new one.
%% Otherwise he's in children_with_clients (or someone's messing with me)
handle_info({'EXIT', _AcceptorPid, Reason}, State=#state{current_child_acceptor=_AcceptorPid}) ->
    emplog:warn( io_lib:format("~p: current_child_acceptor died because of ~p, restarting...",[?MODULE, Reason]) ),
    {noreply, spawn_child_acceptor(State)};
    
handle_info({'EXIT', Pid, Reason}, State=#state{children_with_clients=ChildList}) when is_pid(Pid)->
    NewChildList = case lists:keymember(Pid, 1, ChildList) of
        true ->
            lists:keydelete(Pid, 1, ChildList);
        false ->
            emplog:warn( io_lib:format("~p: Received death message from unknown child because of ~p",[?MODULE, Reason]) ),
            ChildList
    end,
    {noreply, State#state{children_with_clients=NewChildList}};
    
handle_info(Info, State) ->
    emplog:warn( io_lib:format("~p: Received Unknown info: ~p",[?MODULE, Info]) ), % for debugging
    {noreply, State}.

%% --------------------------------------------------------------------
%% Function: terminate/2
%% Description: Shutdown the server
%% Returns: any (ignored by gen_server)
%% --------------------------------------------------------------------

%% Send shutdown messages to all the clients and close up the sockets
%% current_child_acceptor will die on error once we close the LSocket
terminate(Reason, #state{children_with_clients=ChildList, lsocket=LSocket}) ->
    emplog:debug( io_lib:format("~p: Shutting down because of ~p",[?MODULE, Reason]) ),
    gen_tcp:close(LSocket),
    emplog:debug("Now killing children_with_clients: ~p", [ChildList]),
    lists:foreach(fun({Child}) -> Child ! ?SHUTDOWN_MESSAGE end, ChildList).

%% --------------------------------------------------------------------
%% Func: code_change/3
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState}
%% --------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% --------------------------------------------------------------------
%%% Internal functions
%% --------------------------------------------------------------------
% Called by server to create a new child acceptor
-spec spawn_child_acceptor(#state{}) -> #state{}.

spawn_child_acceptor(State = #state{lsocket=LSocket, client_handle_fun = Client_handle_fun}) ->
    Child = proc_lib:spawn_link(?MODULE, child_accept, [{self(), LSocket, Client_handle_fun}]),
    State#state{current_child_acceptor=Child}.

%% @private
%% Child starts here.  Accepts 1 connection, tells parent to spawn a new child to listen for the next
%% connection, and calls Fun to handle the new connection
-spec child_accept( {pid(), gen_tcp:socket(), fun((gen_tcp:socket()) -> any())} ) -> any().

child_accept({Server, LSocket, Fun}) ->
    {ok, Socket} = gen_tcp:accept(LSocket), % BLOCKING
    gen_server:cast(Server, {accepted, self()}),
    Ret = Fun(Socket),
    emplog:debug( io_lib:format("~p: Client connection finished with return value: ~p",[?MODULE, Ret]) ),
    Ret.
    

