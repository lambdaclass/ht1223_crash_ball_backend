defmodule DarkWorldsServerWeb.PlayWebSocket do
  @moduledoc """
  Play Websocket handler that parses msgs to be send to the runner genserver
  """
  alias DarkWorldsServer.Communication
  alias DarkWorldsServer.Communication.Proto.GameAction
  alias DarkWorldsServer.RunnerSupervisor
  alias DarkWorldsServer.RunnerSupervisor.RequestTracker
  alias DarkWorldsServer.RunnerSupervisor.Runner

  require Logger

  @behaviour :cowboy_websocket
  @ping_interval_ms 500

  @impl true
  def init(req, _opts) do
    game_id = :cowboy_req.binding(:game_id, req)
    client_id = :cowboy_req.binding(:client_id, req)
    player_name = :cowboy_req.binding(:player_name, req)
    client_hash = :cowboy_req.header("dark-worlds-client-hash", req)
    selected_character = :cowboy_req.binding(:selected_character, req)

    {:cowboy_websocket, req,
     %{
       game_id: game_id,
       client_id: client_id,
       player_name: player_name,
       client_hash: client_hash,
       selected_character: selected_character
     }}
  end

  @impl true
  def websocket_init(%{game_id: :undefined}) do
    {:stop, %{}}
  end

  def websocket_init(%{client_id: :undefined}) do
    {:stop, %{}}
  end

  # Uncomment to enable hash verification of client and server
  # def websocket_init(%{client_hash: hash}) when hash != @server_hash do
  #   {:stop, :version_mismatch}
  # end

  def websocket_init(%{
        game_id: game_id,
        client_id: client_id,
        player_name: player_name,
        selected_character: selected_character
      }) do
    runner_pid = Communication.external_id_to_pid(game_id)

    with :ok <- Phoenix.PubSub.subscribe(DarkWorldsServer.PubSub, "game_play_#{game_id}"),
         true <- runner_pid in RunnerSupervisor.list_runners_pids(),
         # String.to_integer(player_id) should be client_id

         {:ok, player_id} <- Runner.join(runner_pid, client_id, selected_character) do
      web_socket_state = %{runner_pid: runner_pid, player_id: client_id, game_id: game_id, player_name: player_name}

      Process.send_after(self(), :send_ping, @ping_interval_ms)

      NewRelic.increment_custom_metric("GameBackend/TotalGameWebSockets", 1)
      {:reply, {:binary, Communication.joined_game(player_id)}, web_socket_state}
    else
      false ->
        {:stop, :no_runner}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def terminate(reason, _partialreq, %{runner_pid: _pid, player_id: _id}) do
    NewRelic.increment_custom_metric("GameBackend/TotalGameWebSockets", -1)
    log_termination(reason)
    :ok
  end

  def terminate(:stop, _req, :version_mismatch) do
    Logger.info("#{__MODULE__} #{inspect(self())} closed because of server/client version mismatch")

    :ok
  end

  def terminate(:stop, _req, reason) do
    log_termination(reason)
    :ok
  end

  defp log_termination({_, 1000, _} = reason) do
    Logger.info("#{__MODULE__} with PID #{inspect(self())} closed with message: #{inspect(reason)}")
  end

  defp log_termination(reason) do
    Logger.error("#{__MODULE__} with PID #{inspect(self())} terminated with error: #{inspect(reason)}")
  end

  @impl true
  def websocket_handle({:binary, message}, web_socket_state) do
    case Communication.decode(message) do
      {:ok, %GameAction{action_type: {action, action_data}, timestamp: timestamp}} ->
        RequestTracker.add_counter(web_socket_state[:runner_pid], web_socket_state[:player_id])

        Runner.perform_action(
          action,
          web_socket_state[:runner_pid],
          web_socket_state[:player_id],
          action_data,
          timestamp
        )

        {:ok, web_socket_state}

      {:error, msg} ->
        {:reply, {:text, "ERROR: #{msg}"}, web_socket_state}
    end
  end

  def websocket_handle(:pong, web_socket_state) do
    last_ping_time = web_socket_state.last_ping_time
    time_now = Time.utc_now()
    latency = Time.diff(time_now, last_ping_time, :millisecond)
    # Send back the player's ping
    {:reply, {:binary, Communication.encode!(%{latency: latency})}, web_socket_state}
  end

  def websocket_handle(_, web_socket_state) do
    {:reply, {:text, "ERROR unsupported message"}, web_socket_state}
  end

  @impl true
  def websocket_info({:player_joined, player_id, player_name}, web_socket_state) do
    {:reply, {:binary, Communication.game_player_joined(player_id, player_name)}, web_socket_state}
  end

  # Send a ping frame every once in a while
  def websocket_info(:send_ping, web_socket_state) do
    Process.send_after(self(), :send_ping, @ping_interval_ms)
    time_now = Time.utc_now()
    {:reply, :ping, Map.put(web_socket_state, :last_ping_time, time_now)}
  end

  ## The difference with :game_update messages is that these come from Runner
  def websocket_info({:game_state, new_game_state, old_game_state}, web_socket_state) do
    player_timestamp = new_game_state.player_timestamps[web_socket_state.player_id]
    server_timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    msg = Communication.game_update!(new_game_state, old_game_state, player_timestamp, server_timestamp)
    {:reply, {:binary, msg}, web_socket_state}
  end

  def websocket_info({:game_start, new_game_state, old_game_state}, web_socket_state) do
    player_timestamp = new_game_state.player_timestamps[web_socket_state.player_id]
    server_timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    msg = Communication.game_started!(new_game_state, old_game_state, player_timestamp, server_timestamp)
    {:reply, {:binary, msg}, web_socket_state}
  end

  def websocket_info({:game_ended, new_winner, new_players, old_winner, old_players}, web_socket_state) do
    msg = Communication.game_finished!(new_winner, new_players, old_winner, old_players)
    {:reply, {:binary, msg}, web_socket_state}
  end

  def websocket_info(info, web_socket_state), do: {:reply, {:text, info}, web_socket_state}
end
