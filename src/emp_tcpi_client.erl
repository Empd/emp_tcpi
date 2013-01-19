%% EMP_TCPi_Client.erl
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
%%  The client that is spawn off to handle an individual TCP connection for
%%	a particular user.
%% @end
%% ----------------------------------------------------------------------------
-module(emp_tcpi_client).

-include_lib("empd/include/emptypes.hrl").

-export([init_conn/1]). %check_json/1]).

%% sofar is the json we received from a client so far
-define(SHUTDOWN_MESSAGE, shutdown).
-define(LOGIN_TIMEOUT, 30000). % 30 secs to login

%% init_conn will be called from tcphandler with a Socket connected to a new client
-spec init_conn(gen_tcp:socket()) -> any().
%% TODO: Add description to emptcp_client
init_conn(Socket) ->
    gen_tcp:send(Socket, empinterface:encode_reply(1, null, <<"connected">>)),
    verifyConnection(Socket, 3).

% Spawned from listenLoop, will wait for user to send login credintials
% for a certain number of seconds, if they don't reply within the threshold, 
% kill socket. Also will keep track of the number of tries, if they don't
% supply correct creds, then kill connection.
% TODO What piece of data signals the end of the transmission of login credentials?
%   If we know this, we can use receive_until instead.
-spec verifyConnection(gen_tcp:socket(), non_neg_integer()) -> any().

verifyConnection( Socket, 0 ) ->
    gen_tcp:send( Socket, 
            empinterface:encode_error(9, null, 
                      <<"Invalid Username or Passowrd. Connection Terminated.">>)),
    invalid_login;

verifyConnection( Socket, Tries ) when Tries > 0 ->
    % wait for the requested username/password
    case gen_tcp:recv(Socket, 0, ?LOGIN_TIMEOUT) of
        {error, Err } -> 
            emplog:warn(io_lib:format("~p:verifyConnection - ~p",[?MODULE, Err])),
            login_timeout; % tcphandler will detect I'm dead because he is linked to me, not that he needs to do anything
        {ok, Data}  ->
            % Check login information with null session key.
            % If it succeeds, run the socket handler. Otherwise 
            % reduce tries.
            emplog:debug("Attempting to login with: ~p", [Data]),
            Result =  empinterface:handle_sync(Data, null),
            case Result of 
                {util, auth_success, _UName, SID} ->
                    emplog:debug("Login successful; welcome ~p", [_UName]),                 
                    gen_tcp:send(Socket, 
                        empinterface:encode_reply(1, null, {[ {<<"sid">>, SID}]} )),
                    receive_main( Socket, SID );
                {error, Reason} -> 
                    emplog:warn("Error logging in: ~p",[Reason]),
                    gen_tcp:send(Socket, 
                        empinterface:encode_error(1, null, 
                                <<"Invalid Username or Passowrd. Please try again.">>)),
                    verifyConnection( Socket, Tries-1 )
            end
    end.



%% Receives client data forever.
%% TODO recognize the end of a JSON encoding and an invalid JSON encoding so that 
%% we can handle commands larger than 1 packet.  Use receive_until/3.
-spec receive_main(gen_tcp:socket(), SessionId::'UUID'()) -> any().

receive_main(Socket, SessionId) ->
    case receive_fun(Socket, infinity, SessionId) of
        {ok, Data} ->
            emplog:debug("Received data from client: ~p", [Data]),
            empinterface:handle_async( Data, self(), SessionId ),
            receive_main(Socket, SessionId);
        Other -> Other % errors, shutdown and whatnot.  Will drop the connection.
    end.

%% Keeps receiving data until DataDoneFun returns something other than false (= not done).
%% Return value is {DataDoneFunRetValue, Data}
%% If error in receive_fun it is propogated up
%% -spec receive_until(gen_tcp:socket(), 
%%                     fun((DataSoFar :: string()) -> {boolean(), Ret}), 
%%                     SessionId::'UUID'()) -> 
%%             {ok, Ret, Data :: string()} | {error, Reason :: atom()} when Ret::any().
%% receive_until(Socket, DataDoneFun, SessionId) -> 
%%     receive_until(Socket, DataDoneFun, SessionId, []).
%% 
%% receive_until(Socket, DataDoneFun, SessionId, Sofar) ->
%%     case receive_fun(Socket, infinity, SessionId) of
%%         {ok, D} ->
%%             Data = D ++ Sofar,
%%             case DataDoneFun(Data) of
%%                 false -> receive_until(Socket, DataDoneFun, SessionId, Data);
%%                 Ret -> {ok, Ret, Data}
%%             end;
%%         {error, Reason} -> {error, Reason}
%%     end.



%% Return some data from tcp, or {error, Reason}.
%% If Timeout is not infinity, this might return {error, timeout}.
%% If we receive a system command from someone else, jump to that
%% In other words, calls here may get interruptedby a pending system message
-spec receive_fun(gen_tcp:socket(), timeout(), SessionId::'UUID'()) -> 
          {ok, Data :: string()} | {error, Reason :: any()}. 
receive_fun(Socket, Timeout, SessionId) ->
    inet:setopts(Socket, [{active,once}]),
    receive
        % Client communication
        {tcp, Socket, Data} -> 
            {ok, Data};
        {tcp_closed, Socket} -> 
            {error, tcp_closed};
        {tcp_error, Socket, Reason} -> 
            {error, Reason};
        
        %% EMP messages
        {event, Event} ->
            gen_tcp:send(Socket, empinterface:encode_event(Event)),
            receive_fun(Socket, Timeout, SessionId);
        {ok, Target, Message} ->
            gen_tcp:send(Socket, empinterface:encode_reply(5, Target, Message) ),
            receive_fun(Socket, Timeout, SessionId);
        {ok, Message} ->
            gen_tcp:send(Socket, empinterface:encode_reply(5, null, Message) ),
            receive_fun(Socket, Timeout, SessionId);
        {error, Target, ErrorMessage} ->
            gen_tcp:send(Socket, empinterface:encode_error(5, Target, ErrorMessage) ),
            receive_fun(Socket, Timeout, SessionId);
        {error, ErrorMessage} ->
            gen_tcp:send(Socket, empinterface:encode_error(5, null, ErrorMessage) ),
            receive_fun(Socket, Timeout, SessionId);
        {cast, Message} ->
            gen_tcp:send(Socket, empinterface:encode_cast(5, null, Message) ),
            receive_fun(Socket, Timeout, SessionId);
        
        ?SHUTDOWN_MESSAGE ->
            gen_tcp:send(Socket, 
                         empinterface:encode_update(9, null, <<"Shutting down socket... Goodbye.">>)), 
            gen_tcp:close( Socket ),
%%          try global:send( ?REG_PROC , {remove_client, self()}) 
%%          catch _BadArg -> false end;
            shutting_down;

        %% Unknown message, fail.
        Message -> %TODO: in the future, we shouldn't send these. but for now testing is priority.
            emplog:warn(io_lib:format("Unknown message type, sending anyway: ~p",
            [Message])),
            gen_tcp:send(Socket, empinterface:encode_cast(1,null,Message)),
            receive_fun(Socket, Timeout, SessionId)
    after Timeout ->
        inet:setopts(Socket, [{active,false}]), % Cancel tcp reception (I don't think this is a race condition)
        {error, timeout}
    end.


%% %% Is this string valid Json?
%% %% For now, I assume all invlid json is just incomplete json
%% -spec check_json(string()) -> true | {error, invalid} | {error, incomplete}.
%% 
%% check_json(S) ->
%%  try ejson:decode(S) of
%%      {ok, _} -> {true, complete}
%%  catch
%%      throw:{invalid_json, {_, _}} -> {false, incomplete}
%%  end.
