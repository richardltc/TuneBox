defmodule TuneBox.Player do
  use GenServer
  require Logger

  # --- Client API ---
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def play(file), do: GenServer.cast(__MODULE__, {:play, file})
  def pause, do: GenServer.cast(__MODULE__, :pause)
  def rewind, do: GenServer.cast(__MODULE__, {:seek, -10})
  def fast_forward, do: GenServer.cast(__MODULE__, {:seek, 10})
  def stop, do: GenServer.cast(__MODULE__, :stop)

  # --- Server Callbacks ---
  @impl true
  def init(_opts) do
    mpv_path = System.find_executable("mpv")
    socket_path = "/tmp/mpv-socket-#{:os.getpid()}"

    # Clean up any existing socket
    File.rm(socket_path)

    IO.puts("Starting MPV with socket: #{socket_path}")

    port =
      Port.open({:spawn_executable, mpv_path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        line: 1024,
        args: [
          "--idle=yes",
          "--input-ipc-server=#{socket_path}",
          "--no-video",
          "--no-terminal",
          "--msg-level=all=v",
          "--audio-device=auto"
        ]
      ])

    # Wait a bit for the socket to be created
    Process.send_after(self(), :check_socket, 100)

    {:ok, %{port: port, socket_path: socket_path, socket: nil}}
  end

  @impl true
  def handle_info(:check_socket, state) do
    case File.exists?(state.socket_path) do
      true ->
        IO.puts("Socket created, connecting...")

        {:ok, socket} =
          :gen_tcp.connect({:local, state.socket_path}, 0, [:binary, packet: :line, active: true])

        {:noreply, %{state | socket: socket}}

      false ->
        IO.puts("Waiting for socket...")
        Process.send_after(self(), :check_socket, 100)
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:play, file}, state) do
    command = %{command: ["loadfile", file]} |> Jason.encode!()
    IO.puts("Sending command: #{command}")
    send_to_mpv(state.socket, command)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:pause, state) do
    command = %{command: ["cycle", "pause"]} |> Jason.encode!()
    IO.puts("Sending command: #{command}")
    send_to_mpv(state.socket, command)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:stop, state) do
    command = %{command: ["stop"]} |> Jason.encode!()
    IO.puts("Sending command: #{command}")
    send_to_mpv(state.socket, command)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:seek, seconds}, state) do
    command = %{command: ["seek", seconds]} |> Jason.encode!()
    IO.puts("Sending command: #{command}")
    send_to_mpv(state.socket, command)
    {:noreply, state}
  end

  defp send_to_mpv(nil, _json_string) do
    IO.puts("Socket not ready yet")
  end

  defp send_to_mpv(socket, json_string) do
    :gen_tcp.send(socket, json_string <> "\n")
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    IO.puts(">>> MPV Response: #{data}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state) do
    IO.puts(">>> MPV socket closed")
    {:noreply, state}
  end

  @impl true
  def handle_info({_port, {:data, {:eol, msg}}}, state) do
    IO.puts(">>> MPV: #{msg}")
    {:noreply, state}
  end

  @impl true
  def handle_info({_port, {:data, {:noeol, msg}}}, state) do
    IO.write(">>> MPV (partial): #{msg}")
    {:noreply, state}
  end

  @impl true
  def handle_info({_port, {:exit_status, status}}, state) do
    IO.puts(">>> MPV EXITED with status: #{status}")
    File.rm(state.socket_path)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    IO.inspect(msg, label: ">>> OTHER MSG")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    File.rm(state.socket_path)
    :ok
  end
end
