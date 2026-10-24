defmodule ChidoriWeb.PageController do
  @moduledoc """
  **トップページ（閲覧）は置かない。** `/` はニュースへ送る —— 読むものはニュース・イベント・
  趣味・ツールの画面に分けてあり、並べ直すだけのページを別に持つ理由が無くなった。
  ホーム画面に置いた PWA（開く先は `/`）や前のブックマークのために、道だけ残す。
  """
  use ChidoriWeb, :controller

  def to_news(conn, _params), do: redirect(conn, to: ~p"/news")
end
