defmodule ChidoriWeb.PageController do
  @moduledoc """
  **トップページ（閲覧）は置かない。** `/` はニュースへ送る —— 読むものはニュース（イベントも）・
  趣味・ツールの画面に分けてあり、並べ直すだけのページを別に持つ理由が無くなった。
  ホーム画面に置いた PWA（開く先は `/`）や前のブックマークのために、道だけ残す。
  """
  use ChidoriWeb, :controller

  def to_news(conn, _params), do: redirect(conn, to: ~p"/news")

  @doc """
  前の収集の一覧（`/collect`）は、設定の「収集の一覧」へ送る。収集の画面の段は、収集ごとの画面
  （流れ・網羅・他アプリ用・写真と表紙）だけにした。
  """
  def to_collect_list(conn, _params), do: redirect(conn, to: ~p"/settings?tab=chiezo")
end
