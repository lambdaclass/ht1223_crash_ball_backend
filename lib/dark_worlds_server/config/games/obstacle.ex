defmodule DarkWorldsServer.Config.Games.Obstacle do
  alias DarkWorldsServer.Config.Games.Game
  alias DarkWorldsServer.Config.Games.Shape
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "obstacles" do
    field(:position, :map)
    field(:shape, Shape)

    belongs_to(:game, Game)
  end

  def changeset(obstacle, attrs) do
    obstacle
    |> cast(attrs, [:position, :shape, :game_id])
    |> validate_required([:position, :shape])
  end

  def to_backend_map(obstacle), do:
  %{
    position: obstacle.position,
    shape: obstacle.shape
  }
end
