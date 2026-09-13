defmodule AntennaWeb.Router do
  use AntennaWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AntennaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AntennaWeb do
    pipe_through :browser

    get "/", PageController, :home

    # 収集は数十秒かかるので LiveView にする。押した人に再読み込みをさせない
    live "/news", NewsLive, :index
    live "/relations", RelationsLive, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", AntennaWeb do
  #   pipe_through :api
  # end
end
