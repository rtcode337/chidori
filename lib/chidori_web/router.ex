defmodule ChidoriWeb.Router do
  use ChidoriWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ChidoriWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", ChidoriWeb do
    pipe_through :browser

    # **トップは設定ページで選んだ枠**（要約・関連図・技術書）。何も選んでいなければ
    # 一般ニュースの要約を出す（`Chidori.Home`）。
    # 収集は数十秒かかるので LiveView にする。押した人に再読み込みをさせない
    live "/", HomeLive, :index
    live "/news", NewsLive, :index
    # 設定（Chiezo に頼んでいる収集の一覧・トップページに並べる枠）
    live "/settings", SettingsLive, :index
    # 記事のタグから育てたトピック。仕分けを頼むのもここ
    live "/relations", RelationsLive, :index

    # 依頼を出す画面。送るのも読み直すのも Chiezo への往復なので、押した人を待たせない
    live "/datasets", DatasetsLive, :index
    live "/datasets/areas", DiningAreasLive, :index

    # 集めたものを travel-log 用の ZIP で渡す。**ファイルを返すだけなので LiveView に
    # 載せない**（押したら降ってくる、以上の状態を持たない）
    # **範囲ごとの口より先に**（`areas` が `:key` として読まれないように）
    get "/datasets/areas/travel-log.zip", DatasetsController, :export_areas
    get "/datasets/:key/travel-log.zip", DatasetsController, :export

    # 関連図の顔写真の写し（`Chidori.Relations.Faces`）。見る人のブラウザに写真の
    # 置き場を直に引かせないため、Chidori が配る
    get "/faces/:id", FaceController, :show
  end
end
