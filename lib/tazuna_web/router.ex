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

    # **トップは最新情報（一般ニュース）。** 何も選ばずに開いたときに読むものが
    # いちばん上にあればよく、入口のためだけの頁は置かない。
    # 収集は数十秒かかるので LiveView にする。押した人に再読み込みをさせない
    live "/", NewsLive, :index
    live "/news", NewsLive, :index
    # 記事のタグから育てたトピック。仕分けを頼むのもここ
    live "/relations", RelationsLive, :index

    # 依頼を出す画面。送るのも読み直すのも Chiezo への往復なので、押した人を待たせない
    live "/datasets", DatasetsLive, :index

    # 集めたものを travel-log 用の ZIP で渡す。**ファイルを返すだけなので LiveView に
    # 載せない**（押したら降ってくる、以上の状態を持たない）
    get "/datasets/:key/travel-log.zip", DatasetsController, :export
  end

  # 外のアプリから頼まれる口（JSON）。**LAN の中から呼ばれる前提**で、認証は持たない
  # （Chiezo と同じ線。ルーターでポートを開けないこと）
  scope "/api", TazunaWeb do
    pipe_through :api

    # 銘柄調査を頼む（調べる銘柄は 売買提案のアプリ が決める。`Tazuna.News.StockResearch`）
    post "/stock-research", StockResearchController, :create
  end
end
