# lib/jukebox/music/importer.ex
defmodule TuneBox.Music.Importer do
  @moduledoc """
  Walks a directory tree and imports all supported audio files
  into the database, extracting metadata via mpv.
  """

  alias TuneBox.Repo
  alias TuneBox.Music.{Artist, Album, Track}

  require Logger

  @supported_extensions ~w(.mp3 .flac .aac .ogg .opus)

  @doc """
  Import all supported audio files from the given directory (recursively).

  ## Example

      TuneBox.Music.Importer.import("/home/user/Music")
  """
  def import(directory, on_progress \\ nil) do
    prune_missing_files()

    directory
    |> scan_files()
    |> Enum.each(fn file_path ->
      if is_function(on_progress, 1) do
        on_progress.(Path.dirname(file_path))
      end

      import_file(file_path)
    end)
  end

  @doc """
  Removes tracks from the database whose files no longer exist on disk.
  Associated live_tracks are cascade-deleted automatically.
  """
  def prune_missing_files do
    Track
    |> Repo.all()
    |> Enum.each(fn track ->
      unless File.exists?(track.file_path) do
        Logger.info("Pruning missing file: #{track.file_path}")
        Repo.delete(track)
      end
    end)
  end

  @doc """
  Scans directory recursively for supported audio files.
  """
  def scan_files(directory) do
    directory
    |> Path.expand()
    |> do_scan([])
    |> Enum.reverse()
  end

  defp do_scan(path, acc) do
    cond do
      File.dir?(path) ->
        case File.ls(path) do
          {:ok, entries} ->
            entries
            |> Enum.sort()
            |> Enum.reduce(acc, fn entry, inner_acc ->
              do_scan(Path.join(path, entry), inner_acc)
            end)

          {:error, reason} ->
            Logger.warning("Could not read directory #{path}: #{inspect(reason)}")
            acc
        end

      supported_file?(path) ->
        [path | acc]

      true ->
        acc
    end
  end

  defp supported_file?(path) do
    path
    |> Path.extname()
    |> String.downcase()
    |> then(&(&1 in @supported_extensions))
  end

  @doc """
  Imports a single file, extracting metadata and upserting into the database.
  Skips extraction entirely if the track already exists.
  """
  def import_file(file_path) do
    normalised_path = file_path |> Path.expand() |> String.replace("\\", "/")

    if Repo.get_by(Track, file_path: normalised_path) do
      Logger.debug("Skipping (already imported): #{file_path}")
    else
      Logger.info("Importing: #{file_path}")

      case extract_metadata(file_path) do
        {:ok, metadata} ->
          upsert_track(file_path, metadata)

        {:error, reason} ->
          Logger.warning("Failed to extract metadata from #{file_path}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Extracts audio metadata using mpv.
  Requires mpv to be installed on the system.
  """
  def extract_metadata(file_path) do
    args = [
      "--msg-level=identify=info",
      "--end=0.01",
      "--term-playing-msg=DURATION=${=duration}",
      "--no-audio-display",
      file_path
    ]

    case System.cmd("mpv", args, stderr_to_stdout: true) do
      {output, _code} ->
        parse_mpv_output(output, file_path)
    end
  end

  defp parse_mpv_output(output, file_path) do
    lines = String.split(output, "\n")
    tags = parse_file_tags(lines)

    metadata = %{
      title: Map.get(tags, "title") || filename_as_title(file_path),
      artist: Map.get(tags, "artist") || Map.get(tags, "album_artist"),
      album_artist: Map.get(tags, "album_artist"),
      album: Map.get(tags, "album"),
      track_number: parse_track_number(Map.get(tags, "track")),
      disc_number: parse_track_number(Map.get(tags, "disc") || Map.get(tags, "discnumber")) || 1,
      genre: Map.get(tags, "genre"),
      year: parse_year(Map.get(tags, "date") || Map.get(tags, "year")),
      duration_seconds: parse_duration_line(lines),
      file_format: Path.extname(file_path) |> String.trim_leading(".") |> String.downcase(),
      file_size: file_size(file_path),
      bit_rate: nil,
      sample_rate: parse_sample_rate(lines)
    }

    {:ok, metadata}
  end

  # Parses the "File tags:" block — keys are lowercased and underscores preserved.
  # mpv outputs tags indented with a leading space, e.g. " Artist: Dire Straits"
  defp parse_file_tags(lines) do
    lines
    |> Enum.drop_while(&(&1 != "File tags:"))
    |> Enum.drop(1)
    |> Enum.take_while(&String.starts_with?(&1, " "))
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(String.trim(line), ": ", parts: 2) do
        [key, value] -> Map.put(acc, key |> String.downcase() |> String.replace(" ", "_"), value)
        _ -> acc
      end
    end)
  end

  # Parses sample rate from the audio track line, e.g. "(+) Audio --aid=1 'Title' (opus 2ch 48000Hz)"
  defp parse_sample_rate(lines) do
    audio_line = Enum.find(lines, &String.contains?(&1, "(+) Audio"))

    case audio_line && Regex.run(~r/(\d+)Hz/, audio_line) do
      [_, rate] -> String.to_integer(rate)
      _ -> nil
    end
  end

  # Parses the DURATION=<float> line emitted by --term-playing-msg
  defp parse_duration_line(lines) do
    duration_line = Enum.find(lines, &String.starts_with?(&1, "DURATION="))

    case duration_line do
      nil ->
        nil

      line ->
        value = line |> String.replace_prefix("DURATION=", "") |> String.trim()

        case Float.parse(value) do
          {seconds, _} -> round(seconds)
          :error -> nil
        end
    end
  end

  defp file_size(file_path) do
    case File.stat(file_path) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end

  defp filename_as_title(file_path) do
    file_path
    |> Path.basename()
    |> Path.rootname()
  end

  defp parse_track_number(nil), do: nil
  defp parse_track_number(value) when is_integer(value), do: value

  defp parse_track_number(value) when is_binary(value) do
    # Handle "3/12" format common in tags
    value
    |> String.split("/")
    |> List.first()
    |> String.trim()
    |> String.to_integer()
  rescue
    _ -> nil
  end

  defp parse_year(nil), do: nil

  defp parse_year(value) when is_binary(value) do
    # Extract 4-digit year from various date formats
    case Regex.run(~r/(\d{4})/, value) do
      [_, year] -> String.to_integer(year)
      _ -> nil
    end
  end

  # --- Database upsert logic ---

  defp upsert_track(file_path, metadata) do
    # Normalise path separators for consistent storage across OS
    normalised_path = file_path |> Path.expand() |> String.replace("\\", "/")

    Repo.transaction(fn ->
      artist = find_or_create_artist(metadata.artist || "Unknown Artist")
      album = maybe_find_or_create_album(metadata, artist)

      track_attrs = %{
        title: metadata.title,
        artist_id: artist.id,
        album_id: album && album.id,
        track_number: metadata.track_number,
        disc_number: metadata.disc_number,
        duration_seconds: metadata.duration_seconds,
        file_path: normalised_path,
        file_format: metadata.file_format,
        file_size: metadata.file_size,
        bit_rate: metadata.bit_rate,
        sample_rate: metadata.sample_rate
      }

      case Repo.get_by(Track, file_path: normalised_path) do
        nil ->
          %Track{}
          |> Track.changeset(track_attrs)
          |> Repo.insert!()

        existing ->
          existing
          |> Track.changeset(track_attrs)
          |> Repo.update!()
      end
    end)
  end

  defp find_or_create_artist(name) do
    case Repo.get_by(Artist, name: name) do
      nil ->
        %Artist{}
        |> Artist.changeset(%{name: name})
        |> Repo.insert!()

      artist ->
        artist
    end
  end

  defp maybe_find_or_create_album(%{album: nil}, _artist), do: nil

  defp maybe_find_or_create_album(metadata, artist) do
    album_artist =
      if metadata.album_artist do
        find_or_create_artist(metadata.album_artist)
      else
        artist
      end

    case Repo.get_by(Album, title: metadata.album, artist_id: album_artist.id) do
      nil ->
        %Album{}
        |> Album.changeset(%{
          title: metadata.album,
          artist_id: album_artist.id,
          year: metadata.year,
          genre: metadata.genre
        })
        |> Repo.insert!()

      album ->
        album
    end
  end
end
