defmodule LoadTest.PlayerSupervisor do
  @moduledoc """
  Player Supervisor
  """
  use DynamicSupervisor
  use Tesla
  plug(Tesla.Middleware.JSON)
  plug(Tesla.Middleware.Headers, [{"content-type", "application/json"}])

  alias LoadTest.GamePlayer
  alias LoadTest.LobbyPlayer

  def start_link(args) do
    DynamicSupervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  def spawn_lobby_player(player_number, max_duration_seconds) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {LobbyPlayer, {player_number, max_duration_seconds}}
    )
  end

  def spawn_game_player(player_number, game_id, max_duration_seconds) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {GamePlayer, {player_number, game_id, max_duration_seconds}}
    )
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # creates `num_players` which will try to join a lobby
  def spawn_players(num_players, duration_seconds \\ nil) do
    for i <- 1..num_players do
      {:ok, _pid} = spawn_lobby_player(i, duration_seconds)
    end
  end

  def server_host() do
    System.get_env("SERVER_HOST", "localhost:4000")
  end
end
