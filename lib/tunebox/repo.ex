# lib/jukebox/repo.ex
defmodule TuneBox.Repo do
  use Ecto.Repo,
    otp_app: :tunebox,
    adapter: Ecto.Adapters.SQLite3
end
