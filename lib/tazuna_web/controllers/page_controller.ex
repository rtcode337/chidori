defmodule TazunaWeb.PageController do
  use TazunaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
