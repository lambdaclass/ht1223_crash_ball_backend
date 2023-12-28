defmodule DarkWorldsServer.Repo.Migrations.AddLapsToWin do
  use Ecto.Migration

  def change do
    alter table("games") do
      add :laps_to_win, :integer, null: :false, default: 0
    end
  end
end
