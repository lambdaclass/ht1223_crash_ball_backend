defmodule DarkWorldsServer.Repo.Migrations.MakeObstaclesStringMaps do
  use Ecto.Migration

  def change do
    alter table(:games) do
      remove :obstacles
    end

    create table(:obstacles) do
      add :position, :map
      add :shape, :string
      add :game_id, references(:games, on_delete: :delete_all), null: :false
    end
  end
end
