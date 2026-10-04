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

    # **トップは設定ページで選んだ枠**（要約・関連図・技術書）。何も選んでいなければ
    # 一般ニュースの要約を出す（`Tazuna.Home`）。
    # 収集は数十秒かかるので LiveView にする。押した人に再読み込みをさせない
    live "/", HomeLive, :index
    live "/news", NewsLive, :index
    # 設定（Chiezo に頼んでいる収集の一覧・トップページに並べる枠）
    live "/settings", SettingsLive, :index
    # 記事のタグから育てたトピック。仕分けを頼むのもここ
    live "/relations", RelationsLive, :index

    # 依頼を出す画面。送るのも読み直すのも Chiezo への往復なので、押した人を待たせない
    live "/datasets", DatasetsLive, :index
    live "/datasets/areas", MealAreasLive, :index

    # 集めたものを travel-log 用の ZIP で渡す。**ファイルを返すだけなので LiveView に
    # 載せない**（押したら降ってくる、以上の状態を持たない）
    get "/datasets/:key/travel-log.zip", DatasetsController, :export

    # 関連図の顔写真の写し（`Tazuna.Relations.Faces`）。見る人のブラウザに写真の
    # 置き場を直に引かせないため、tazuna が配る
    get "/faces/:id", FaceController, :show
  end

  # 外のアプリから頼まれる口（JSON）。**LAN の中から呼ばれる前提**で、認証は持たない
  # （Chiezo と同じ線。ルーターでポートを開けないこと）
  scope "/api", TazunaWeb do
    pipe_through :api

    # 銘柄調査を頼む（調べる銘柄は 売買提案のアプリ が決める。`Tazuna.News.StockResearch`）
    post "/stock-research", StockResearchController, :create
  end
end
