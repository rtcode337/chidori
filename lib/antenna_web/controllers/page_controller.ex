defmodule AntennaWeb.PageController do
  use AntennaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
