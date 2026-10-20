defmodule Chidori.Relations.FacesTest do
  @moduledoc """
  関連図の顔写真（`Chidori.Relations.Faces`）。**1 人 1 回だけ**取りに行き、写しを配る。
  """

  use ChidoriWeb.ConnCase, async: false

  alias Chidori.Relations.Face
  alias Chidori.Relations.Faces
  alias Chidori.Repo

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

  test "レシピ集の写真のない料理には、ここの写しを付ける（収集の写しを持つ料理はそのまま）" do
    face = stored(@photo, "ok", "WEBP")

    recipes = [
      %{title: "写しを待つ", thumb: nil, image: @photo},
      %{title: "収集の写し", thumb: "/thumbs/x.webp", image: @photo},
      %{title: "写真なし", thumb: nil, image: nil}
    ]

    assert [%{thumb: path}, %{thumb: "/thumbs/x.webp"}, %{thumb: nil}] =
             Chidori.Datasets.Recipes.with_photos(recipes)

    assert path == Faces.path(face.id)
  end

  test "Chiezo が取りに行けなかったら、列の残りを捨てて休む（断られているのに頼み続けない）" do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
    test_pid = self()

    Chidori.HttpStub.stub(fn %{url: url} ->
      send(test_pid, {:asked, url})
      {:ok, %{status: 502, body: ~s({"error": "upstream unavailable", "reason": "HTTP 429"})}}
    end)

    {:ok, pid} = Faces.start_link(name: :faces_pause_test)
    urls = for n <- 1..3, do: "https://upload.wikimedia.org/wikipedia/commons/a/ab/P#{n}.jpg"
    GenServer.cast(pid, {:fetch, urls, 120})
    # 休んでいる間は、新しく並べもしない
    GenServer.cast(pid, {:fetch, [@photo], 120})
    _ = :sys.get_state(pid)

    assert_received {:asked, _url}
    refute_received {:asked, _url}
    state = :sys.get_state(pid)
    assert :queue.is_empty(state.queue) and state.paused_until
  end

  test "押したときに出典とライセンスを読める、Commons のファイルのページ" do
    assert Faces.file_page(@photo) == "https://commons.wikimedia.org/wiki/File:Sample_person.jpg"
  end

  test "写しは Chidori が配り、ブラウザに長く覚えさせる", %{conn: conn} do
    face = stored(@photo, "ok", "JPEG")

    conn = get(conn, Faces.path(face.id))
    assert conn.status == 200
    assert conn.resp_body == "JPEG"
    assert get_resp_header(conn, "cache-control") |> hd() =~ "immutable"

    assert get(build_conn(), "/faces/999999").status == 404
  end
end
