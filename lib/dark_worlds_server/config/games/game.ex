defmodule DarkWorldsServer.Config.Games.Game do
  @moduledoc """
  The general configuration for a game. For now, we only have one game at a time.
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias DarkWorldsServer.Config.Games.ZoneModification

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "games" do
    field(:width, :integer)
    field(:height, :integer)
    field(:loot_interval_ms, :integer)
    field(:zone_starting_radius, :integer)
    field(:auto_aim_max_distance, :float)
    field(:initial_positions, :map)
    field(:tick_interval_ms, :integer)
    field(:obstacles, {:array ,:map})

    has_many(:zone_modifications, ZoneModification)

    timestamps()
  end

  @doc false
  def changeset(game, attrs) do
    game
    |> cast(attrs, [
      :width,
      :height,
      :loot_interval_ms,
      :zone_starting_radius,
      :auto_aim_max_distance,
      :initial_positions,
      :tick_interval_ms,
      :obstacles
    ])
    |> validate_required([:width, :height, :auto_aim_max_distance, :tick_interval_ms])
    |> cast_assoc(:zone_modifications)
  end

  def to_backend_map(game) do
    %{
      width: game.width,
      auto_aim_max_distance: game.auto_aim_max_distance,
      height: game.height,
      initial_positions:
        Enum.into(game.initial_positions, %{}, fn {player_id, positions} -> {String.to_integer(player_id), transform_map_keys_to_atoms(positions)} end),
      loot_interval_ms: game.loot_interval_ms,
      zone_modifications: Enum.map(game.zone_modifications, &ZoneModification.to_backend_map/1),
      zone_starting_radius: game.zone_starting_radius,
      tick_interval_ms: game.tick_interval_ms,
      obstacles: Enum.map(game.obstacles, fn map -> Enum.into(map, %{}, fn tuple -> transform_nested_map(tuple) end) end)
    }
  end

  defp transform_nested_map({key, %{} = value}) do
    {String.to_atom(key), transform_map_keys_to_atoms(value)}
  end
  defp transform_nested_map({key, value}) do
    {String.to_atom(key), value}
  end

  defp transform_map_keys_to_atoms(map) do
    Enum.into(map, %{}, fn {key, value} -> {String.to_atom(key), value} end)
  end
end
