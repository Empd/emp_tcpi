%% EMP_TCPi_App.erl
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
%%  The EMP TCP interface application is an implementation of the EMP Interface
%%  API for TCP Sockets.
%% @end
%% ----------------------------------------------------------------------------
-module(emp_tcpi_app).
-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%%% ===================================================================
%%% Application callbacks
%%% ===================================================================

start(_StartType, StartArgs) ->
    process_flag(trap_exit, true),
    emp_tcpi_sup:start_link(StartArgs).

stop(_State) ->
    ok.
