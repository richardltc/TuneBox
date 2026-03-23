defmodule TuneBox.Repo.Migrations.RenameLiveTracksToQueuedTracks do
  use Ecto.Migration

  def change do
    rename table(:live_tracks), to: table(:queued_tracks)
  end
end
