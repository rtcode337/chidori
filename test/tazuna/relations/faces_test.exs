defmodule Tazuna.Relations.FacesTest do
  @moduledoc """
  関連図の顔写真（`Tazuna.Relations.Faces`）。**1 人 1 回だけ**取りに行き、写しを配る。
  """

  use TazunaWeb.ConnCase, async: false

  alias Tazuna.Relations.Face
  alias Tazuna.Relations.Faces
  alias Tazuna.Repo

  @photo "https://upload.wikimedia.org/wikipedia/commons/b/b5/Sample_person.jpg"

  defp stored(url, status, image \\ nil) do
    %Face{}
    |> Face.changeset(%{
      source_url: url,
      status: status,
      image: image,
      content_type: "image/jpeg"
    })
    |> Repo.insert!()
  end

  test "写しのある写真だけ、配る道を返す" do
    face = stored(@photo, "ok", "JPEG")
    stored(@photo <> "2", "missing")

    assert Faces.faces([@photo, @photo <> "2"]) == %{@photo => Faces.path(face.id)}
  end

  test "Commons の写真だけを使う（日本語版にだけある画像は取らない）" do
    assert Faces.commons?(@photo)
    refute Faces.commons?("https://upload.wikimedia.org/wikipedia/ja/1/12/Local.jpg")
    assert Faces.faces(["https://upload.wikimedia.org/wikipedia/ja/1/12/Local.jpg"]) == %{}
  end

  test "押したときに出典とライセンスを読める、Commons のファイルのページ" do
    assert Faces.file_page(@photo) == "https://commons.wikimedia.org/wiki/File:Sample_person.jpg"
  end

  test "写しは tazuna が配り、ブラウザに長く覚えさせる", %{conn: conn} do
    face = stored(@photo, "ok", "JPEG")

    conn = get(conn, Faces.path(face.id))
    assert conn.status == 200
    assert conn.resp_body == "JPEG"
    assert get_resp_header(conn, "cache-control") |> hd() =~ "immutable"

    assert get(build_conn(), "/faces/999999").status == 404
  end
end
