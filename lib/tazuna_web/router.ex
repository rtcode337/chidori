defmodule TazunaWeb.Router do
  use TazunaWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TazunaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", TazunaWeb do
    pipe_through :browser

    get "/", PageController, :home

    # 収集は数十秒かかるので LiveView にする。押した人に再読み込みをさせない
    live "/news", NewsLive, :index
    # 記事のタグから育てたトピック。仕分けを頼むのもここ
    live "/relations", RelationsLive, :index

    # 依頼を出す画面。送るのも読み直すのも Chiezo への往復なので、押した人を待たせない
    live "/datasets", DatasetsLive, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", TazunaWeb do
  #   pipe_through :api
  # end
end
