defmodule TuneboxWeb.PageController do
  use TuneboxWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
