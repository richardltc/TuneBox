defmodule TuneBox.Music.Converter do
  @moduledoc """
  Converts audio files to Opus format using ffmpeg.
  """

  require Logger

  @doc """
  Converts a .flac file to .opus using ffmpeg.

  Options:
    - `:delete_original` - if true, deletes the source file after successful conversion (default: false)
    - `:bitrate` - opus bitrate, e.g. "192k" (default: "192k")

  Returns `{:ok, output_path}` or `{:error, reason}`.
  """
  def convert(source_path, opts \\ []) do
    delete_original = Keyword.get(opts, :delete_original, false)
    bitrate = Keyword.get(opts, :bitrate, "192k")
    output_path = Path.rootname(source_path) <> ".opus"

    args = [
      "-i", source_path,
      "-c:a", "libopus",
      "-b:a", bitrate,
      "-vn",
      output_path
    ]

    Logger.info("Converting #{source_path} -> #{output_path}")

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_output, 0} ->
        if delete_original do
          case File.rm(source_path) do
            :ok ->
              Logger.info("Deleted original: #{source_path}")

            {:error, reason} ->
              Logger.warning("Conversion succeeded but could not delete #{source_path}: #{inspect(reason)}")
          end
        end

        {:ok, output_path}

      {output, exit_code} ->
        Logger.error("ffmpeg failed (exit #{exit_code}) for #{source_path}: #{output}")
        {:error, {:ffmpeg_failed, exit_code, output}}
    end
  end
end
