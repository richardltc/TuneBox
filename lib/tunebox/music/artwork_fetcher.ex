defmodule TuneBox.Music.ArtworkFetcher do
  @moduledoc """
  Fetches artist and album artwork from the Deezer API and stores the
  binary image data in the database.
  """

  require Logger

  alias TuneBox.Repo
  alias TuneBox.Music.{Artist, Album}

  @deezer "https://api.deezer.com"

  @doc """
  Fetches and stores missing artwork for the artist and album of the given track.
  Each is only fetched if the image column is currently nil in the database.
  """
  def fetch_for_track(track) do
    artist = Repo.get!(Artist, track.artist.id)
    fetch_artist_picture(artist)

    if track.album do
      album = Repo.get!(Album, track.album.id)
      fetch_album_cover(album, artist.name)
    end
  end

  defp fetch_artist_picture(%Artist{picture_big: nil} = artist) do
    with {:ok, url} <- search_artist_picture(artist.name),
         {:ok, data} <- download(url) do
      artist
      |> Artist.changeset(%{picture_big: data})
      |> Repo.update()
      |> case do
        {:ok, _} -> Logger.info("Fetched artist picture for #{artist.name}")
        {:error, e} -> Logger.warning("Failed to save artist picture: #{inspect(e)}")
      end
    else
      err -> Logger.warning("Could not fetch artist picture for #{artist.name}: #{inspect(err)}")
    end
  end

  defp fetch_artist_picture(_artist), do: :ok

  defp fetch_album_cover(%Album{cover_big: nil} = album, artist_name) do
    with {:ok, url} <- search_album_cover(album.title, artist_name),
         {:ok, data} <- download(url) do
      album
      |> Album.changeset(%{cover_big: data})
      |> Repo.update()
      |> case do
        {:ok, _} -> Logger.info("Fetched album cover for #{album.title}")
        {:error, e} -> Logger.warning("Failed to save album cover: #{inspect(e)}")
      end
    else
      err -> Logger.warning("Could not fetch album cover for #{album.title}: #{inspect(err)}")
    end
  end

  defp fetch_album_cover(_album, _artist_name), do: :ok

  defp search_artist_picture(name) do
    case Req.get("#{@deezer}/search/artist", params: [q: name]) do
      {:ok, %{status: 200, body: %{"data" => [first | _]}}} ->
        {:ok, first["picture_big"]}

      _ ->
        {:error, :not_found}
    end
  end

  defp search_album_cover(title, artist_name) do
    case Req.get("#{@deezer}/search/album", params: [q: "#{artist_name} #{title}"]) do
      {:ok, %{status: 200, body: %{"data" => [first | _]}}} ->
        {:ok, first["cover_big"]}

      _ ->
        {:error, :not_found}
    end
  end

  defp download(url) do
    case Req.get(url) do
      {:ok, %{status: 200, body: data}} when is_binary(data) -> {:ok, data}
      _ -> {:error, :download_failed}
    end
  end
end
