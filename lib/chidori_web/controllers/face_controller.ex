defmodule ChidoriWeb.FaceController do
  @moduledoc """
  関連図の顔写真の写しを配ります（`Chidori.Relations.Faces`）。**中身は変わらない**
  （写真が差し替わったら別の行になる）ので、ブラウザには長く覚えさせます。
  """

  use ChidoriWeb, :controller

  def show(conn, %{"id" => id}) do
    with {id, ""} <- Integer.parse(id),
         {:ok, image, type} <- Chidori.Relations.Faces.get(id) do
      conn
      |> put_resp_content_type(type, nil)
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> send_resp(200, image)
    else
      _missing -> send_resp(conn, 404, "")
    end
  end
end
