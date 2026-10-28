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

    # **トップページ（閲覧）は置かない**。ニュースへ送る（読むものは画面ごとに分けてある）
    get "/", PageController, :to_news

    # 収集は数十秒かかるので LiveView にする。押した人に再読み込みをさせない
    live "/news", NewsLive, :index

    # 技術イベント・お笑いイベント（画面は最新情報のもの。頭のメニューの「イベント」）
    live "/events", NewsLive, :events
    # その場の様子を見る道具（いま止めている通信）
    live "/tools", ToolsLive, :index
    # 設定（Chiezo に頼んでいる収集の一覧・トップページに並べる枠）
    live "/settings", SettingsLive, :index
    # 記事のタグから育てたトピック。仕分けを頼むのもここ
    live "/relations", RelationsLive, :index

    # 依頼を出す画面。送るのも読み直すのも Chiezo への往復なので、押した人を待たせない
    live "/datasets", DatasetsLive, :index

    # 食事処の「全体」は収集の画面へ移した（範囲・依頼・書き出し。読むのは travel-log）
    get "/datasets/areas", DatasetsController, :to_collect_areas
    get "/collect/datasets/areas", DatasetsController, :to_collect_areas

    # **収集の画面**（Chiezo へ頼む口をここに集める）。読む画面と同じ LiveView を、収集の形
    # （`:collect`）で開く —— 見る画面には集めたものだけを出し、頼むのは Chidori のこの画面だけで済むように
    live "/collect", SettingsLive, :collect
    live "/collect/news", NewsLive, :collect
    live "/collect/events", NewsLive, :collect_events
    live "/collect/relations", RelationsLive, :collect

    # 写真と表紙の取得の様子（もとは設定ページのタブ。Chiezo に頼む仕事なので収集の画面に置く）
    live "/collect/photos", SettingsLive, :collect_photos
    live "/collect/datasets", DatasetsLive, :collect

    # 他のアプリ（travel-log）が読む収集。ご当地グルメ・アニメ聖地・食事処（範囲ごと）
    live "/collect/apps", DatasetsLive, :collect_apps
    live "/collect/apps/areas", DiningAreasLive, :index

    # 集めたものを travel-log 用の ZIP で渡す。**ファイルを返すだけなので LiveView に
    # 載せない**（押したら降ってくる、以上の状態を持たない）
    # **範囲ごとの口より先に**（`areas` が `:key` として読まれないように）
    get "/datasets/areas/travel-log.zip", DatasetsController, :export_areas
    get "/datasets/:key/travel-log.zip", DatasetsController, :export

    # 関連図の顔写真の写し（`Chidori.Relations.Faces`）。見る人のブラウザに写真の
    # 置き場を直に引かせないため、Chidori が配る
    get "/faces/:id", FaceController, :show

    # Chiezo が作ったサムネイル（`Chidori.Chiezo.thumb_path/1`）。ブラウザに Chiezo を
    # 直に引かせない（https の画面から http の絵は止められる。コンテナの名前も引けない）
    get "/thumbs/:name", ThumbController, :show
  end
end
