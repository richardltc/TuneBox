# lib/jukebox/music/importer.ex
defmodule TuneBox.Music.Importer do
  @moduledoc """
  Walks a directory tree and imports all supported audio files
  into the database, extracting metadata via ffprobe.
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
  def import(directory) do
    directory
    |> scan_files()
    |> Enum.each(&import_file/1)
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
  """
  def import_file(file_path) do
    Logger.info("Importing: #{file_path}")

    case extract_metadata(file_path) do
      {:ok, metadata} ->
        upsert_track(file_path, metadata)

      {:error, reason} ->
        Logger.warning("Failed to extract metadata from #{file_path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Extracts audio metadata using ffprobe.
  Requires ffmpeg/ffprobe to be installed on the system.
  """
  def extract_metadata(file_path) do
    args = [
      "-v",
      "quiet",
      "-print_format",
      "json",
      "-show_format",
      "-show_streams",
      file_path
    ]

    case System.cmd("ffprobe", args, stderr_to_stdout: true) do
      {output, 0} ->
        parse_ffprobe_output(output, file_path)

      {error, _code} ->
        {:error, "ffprobe failed: #{error}"}
    end
  end

  defp parse_ffprobe_output(json_string, file_path) do
    case Jason.decode(json_string) do
      {:ok, data} ->
        format = Map.get(data, "format", %{})
        tags = format |> Map.get("tags", %{}) |> normalise_tag_keys()
        streams = Map.get(data, "streams", [])
        audio_stream = Enum.find(streams, &(&1["codec_type"] == "audio")) || %{}

        metadata = %{
          title: Map.get(tags, "title") || filename_as_title(file_path),
          artist: Map.get(tags, "artist") || Map.get(tags, "album_artist"),
          album_artist: Map.get(tags, "album_artist"),
          album: Map.get(tags, "album"),
          track_number: parse_track_number(Map.get(tags, "track")),
          disc_number: parse_track_number(Map.get(tags, "disc")) || 1,
          genre: Map.get(tags, "genre"),
          year: parse_year(Map.get(tags, "date") || Map.get(tags, "year")),
          duration_seconds: parse_duration(Map.get(format, "duration")),
          file_format: Path.extname(file_path) |> String.trim_leading(".") |> String.downcase(),
          file_size: parse_int(Map.get(format, "size")),
          bit_rate: parse_int(Map.get(format, "bit_rate") || Map.get(audio_stream, "bit_rate")),
          sample_rate: parse_int(Map.get(audio_stream, "sample_rate"))
        }

        {:ok, metadata}

      {:error, _} ->
        {:error, "Failed to parse ffprobe JSON output"}
    end
  end

  # ffprobe tag keys can vary in case (TITLE vs title vs Title)
  defp normalise_tag_keys(tags) do
    Map.new(tags, fn {key, value} ->
      {String.downcase(key), value}
    end)
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

  defp parse_duration(nil), do: nil

  defp parse_duration(value) when is_binary(value) do
    case Float.parse(value) do
      {seconds, _} -> round(seconds)
      :error -> nil
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_int(value) when is_integer(value), do: value

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
