defmodule TuneBox.Player do
  use GenServer
  require Logger

  # --- Client API ---
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def play(file), do: GenServer.cast(__MODULE__, {:play, file})
  def play_from(file, seconds), do: GenServer.cast(__MODULE__, {:play_from, file, seconds})
  def resume, do: GenServer.cast(__MODULE__, :resume)
  def pause, do: GenServer.cast(__MODULE__, :pause)
  def stop, do: GenServer.cast(__MODULE__, :stop)
  def rewind, do: GenServer.cast(__MODULE__, {:seek, -10})
  def fast_forward, do: GenServer.cast(__MODULE__, {:seek, 10})
  def seek_absolute(seconds), do: GenServer.cast(__MODULE__, {:seek_absolute, seconds})
  def get_status, do: GenServer.call(__MODULE__, :get_status)

  # --- Server Callbacks ---
  @impl true
  def init(_opts) do
    mpv_path = System.find_executable("mpv")
    {socket_path, socket_type} = get_socket_config()

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
          "--audio-device=auto",
          "--audio-buffer=1",
          "--cache=yes",
          "--demuxer-max-bytes=50M",
          "--demuxer-readahead-secs=30",
          "--gapless-audio=yes"
        ]
      ])

    # Wait a bit for the socket to be created
    Process.send_after(self(), :check_socket, 100)

    {:ok,
     %{
       port: port,
       socket_path: socket_path,
       socket_type: socket_type,
       socket: nil,
       current_file: nil,
       paused: true,
       time_pos: 0.0,
       duration: 0.0,
       last_ended_file: nil
     }}
  end

  defp get_socket_config do
    case :os.type() do
      {:win32, _} ->
        # Windows named pipe
        socket_path = "\\\\.\\pipe\\mpv-socket-#{:os.getpid()}"
        {socket_path, :windows}

      {:unix, _} ->
        # Unix domain socket
        socket_path = "/tmp/mpv-socket-#{:os.getpid()}"
        {socket_path, :unix}
    end
  end

  @impl true
  def handle_info(:check_socket, %{socket_type: :unix} = state) do
    case File.exists?(state.socket_path) do
      true ->
        IO.puts("Socket created, connecting...")

        {:ok, socket} =
          :gen_tcp.connect({:local, state.socket_path}, 0, [:binary, packet: :line, active: true])

        observe_properties(socket)
        {:noreply, %{state | socket: socket}}

      false ->
        IO.puts("Waiting for socket...")
        Process.send_after(self(), :check_socket, 100)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:check_socket, %{socket_type: :windows} = state) do
    # On Windows, we connect to the named pipe
    # This is a bit tricky - we might need to use a different approach
    # Named pipes in Erlang/Elixir on Windows can be challenging
    case connect_windows_pipe(state.socket_path) do
      {:ok, socket} ->
        IO.puts("Connected to named pipe")
        {:noreply, %{state | socket: socket}}

      {:error, _reason} ->
        IO.puts("Waiting for named pipe...")
        Process.send_after(self(), :check_socket, 100)
        {:noreply, state}
    end
  end

  defp connect_windows_pipe(pipe_path) do
    # On Windows, try to open the named pipe as a file
    # This is a simplified approach - for production you might want to use a NIF or port
    case File.open(pipe_path, [:read, :write, :binary]) do
      {:ok, file} -> {:ok, {:file, file}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def handle_cast({:play, file}, state) do
    load = %{command: ["loadfile", file, "replace", "start=0"]} |> Jason.encode!()
    unpause = %{command: ["set_property", "pause", false]} |> Jason.encode!()
    IO.puts("Sending command: #{load}")
    send_to_mpv(state.socket, load)
    send_to_mpv(state.socket, unpause)
    {:noreply, %{state | current_file: file, paused: false, time_pos: 0.0, last_ended_file: nil}}
  end

  @impl true
  def handle_cast({:play_from, file, seconds}, state) do
    # Use mpv's loadfile "start" option to begin at a specific position
    load = %{command: ["loadfile", file, "replace", "start=#{seconds}"]} |> Jason.encode!()
    unpause = %{command: ["set_property", "pause", false]} |> Jason.encode!()
    IO.puts("Sending command: #{load}")
    send_to_mpv(state.socket, load)
    send_to_mpv(state.socket, unpause)
    {:noreply, %{state | current_file: file, paused: false, last_ended_file: nil}}
  end

  @impl true
  def handle_cast(:resume, state) do
    command = %{command: ["set_property", "pause", false]} |> Jason.encode!()
    IO.puts("Sending command: #{command}")
    send_to_mpv(state.socket, command)
    {:noreply, %{state | paused: false}}
  end

  @impl true
  def handle_cast(:pause, state) do
    command = %{command: ["set_property", "pause", true]} |> Jason.encode!()
    IO.puts("Sending command: #{command}")
    send_to_mpv(state.socket, command)
    {:noreply, %{state | paused: true}}
  end

  @impl true
  def handle_cast(:stop, state) do
    command = %{command: ["stop"]} |> Jason.encode!()
    IO.puts("Sending command: #{command}")
    send_to_mpv(state.socket, command)
    {:noreply, %{state | current_file: nil, paused: true, time_pos: 0.0, duration: 0.0}}
  end

  @impl true
  def handle_cast({:seek, seconds}, state) do
    command = %{command: ["seek", seconds]} |> Jason.encode!()
    IO.puts("Sending command: #{command}")
    send_to_mpv(state.socket, command)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:seek_absolute, seconds}, state) do
    command = %{command: ["seek", seconds, "absolute"]} |> Jason.encode!()
    IO.puts("Sending command: #{command}")
    send_to_mpv(state.socket, command)
    {:noreply, state}
  end

  defp observe_properties(socket) do
    for {id, prop} <- [{1, "time-pos"}, {2, "duration"}] do
      cmd = %{command: ["observe_property", id, prop]} |> Jason.encode!()
      send_to_mpv(socket, cmd)
    end
  end

  defp send_to_mpv(nil, _json_string) do
    IO.puts("Socket not ready yet")
  end

  defp send_to_mpv({:file, file}, json_string) do
    # Windows named pipe
    IO.write(file, json_string <> "\n")
  end

  defp send_to_mpv(socket, json_string) do
    # Unix socket
    :gen_tcp.send(socket, json_string <> "\n")
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, {state.current_file, state.paused, state.time_pos, state.duration, state.last_ended_file}, state}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    state =
      case Jason.decode(data) do
        {:ok, %{"event" => "property-change", "name" => "time-pos", "data" => pos}}
            when is_number(pos) ->
          Phoenix.PubSub.broadcast(Tunebox.PubSub, "player:status", {:time_pos, pos})
          %{state | time_pos: pos}

        {:ok, %{"event" => "property-change", "name" => "duration", "data" => dur}}
            when is_number(dur) ->
          Phoenix.PubSub.broadcast(Tunebox.PubSub, "player:status", {:duration, dur})
          %{state | duration: dur}

        {:ok, %{"event" => "end-file", "reason" => "eof"}} ->
          Phoenix.PubSub.broadcast(Tunebox.PubSub, "player:status", :track_ended)
          %{state | last_ended_file: state.current_file, current_file: nil, paused: true, time_pos: 0.0, duration: 0.0}

        _ ->
          state
      end

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
    cleanup_socket(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    IO.inspect(msg, label: ">>> OTHER MSG")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    cleanup_socket(state)
    :ok
  end

  defp cleanup_socket(%{socket: {:file, file}}) do
    File.close(file)
  end

  defp cleanup_socket(%{socket_path: socket_path}) do
    File.rm(socket_path)
  end

  defp cleanup_socket(_), do: :ok
end
