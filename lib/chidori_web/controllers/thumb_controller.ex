defmodule ChidoriWeb.ThumbController do
  @moduledoc """
  Chiezo が作ったサムネイル（`/v1/thumbs/<sha1>.webp`）を、Chidori から配ります
  （`Chidori.Chiezo.thumb_path/1`）。

  **見る人のブラウザに Chiezo を直に引かせない** —— Chidori を https で配ると、http の
  Chiezo を指す絵は混在コンテンツとしてブラウザに止められ、Chiezo をコンテナの名前で
  つないでいるときは、ブラウザからはその名前が引けない。どちらも絵が「?」になる。

  **名前は中身のハッシュで、中身は変わらない**ので、ブラウザには長く覚えさせます。
  手元には持たず、届いたものをそのまま返します（同じ絵はブラウザが覚えている）。
  """

  use ChidoriWeb, :controller

  alias Chidori.Chiezo

  def show(conn, %{"name" => name}) do
    with true <- Chiezo.thumb_name?(name),
         url when is_binary(url) <- Chiezo.url("/v1/thumbs/" <> name),
         {:ok, %{status: 200, body: image}} <- Chiezo.get(url) do
      conn
      |> put_resp_content_type("image/webp", nil)
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> send_resp(200, image)
    else
      _missing -> send_resp(conn, 404, "")
    end
  end
end
