defmodule Tunebox.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications..
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    with :ok <- check_dependencies() do
      children =
        [
          TuneboxWeb.Telemetry,
          {DNSCluster, query: Application.get_env(:tunebox, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: Tunebox.PubSub},
          TuneBox.Repo,
          TuneboxWeb.Endpoint
        ] ++ player_children()

      opts = [strategy: :one_for_one, name: Tunebox.Supervisor]
      Supervisor.start_link(children, opts)
    end
  end

  defp player_children do
    if System.find_executable("mpv") do
      [TuneBox.Player]
    else
      Logger.warning("mpv not found — playback will be disabled.")
      []
    end
  end

  defp check_dependencies do
    case System.find_executable("ffprobe") do
      nil ->
        Logger.error("ffprobe not found. Please install ffmpeg (which includes ffprobe) to use TuneBox.")
        {:error, :ffprobe_not_found}

      _path ->
        :ok
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TuneboxWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
