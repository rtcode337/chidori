defmodule ChidoriWeb.ThumbControllerTest do
  @moduledoc """
  Chiezo のサムネイルを Chidori から配る。見ているのは、**Chiezo から引いて返すこと**、
  **形の違う名前は Chiezo に問い合わせずに断ること**、**画面が Chidori の場所で指すこと**です。
  """

  use ChidoriWeb.ConnCase, async: false

  alias Chidori.HttpStub

  @name String.duplicate("a", 40) <> ".webp"

  setup do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
  end

  test "Chiezo から引いて、長く覚えさせて返す", %{conn: conn} do
    HttpStub.stub(fn %{method: :get, url: "http://chiezo.test:7010/v1/thumbs/" <> @name} ->
      HttpStub.ok("WEBP")
    end)

    conn = get(conn, "/thumbs/" <> @name)

    assert response(conn, 200) == "WEBP"
    assert get_resp_header(conn, "content-type") == ["image/webp"]
    assert ["public, max-age=31536000, immutable"] = get_resp_header(conn, "cache-control")
  end

  test "形の違う名前は断る（Chiezo に問い合わせない）", %{conn: conn} do
    HttpStub.stub(fn _request -> flunk("問い合わせない") end)

    assert response(get(conn, "/thumbs/x.webp"), 404) == ""
  end

  test "Chiezo に無ければ 404", %{conn: conn} do
    HttpStub.stub(fn _request -> {:ok, %{status: 404, body: ""}} end)

    assert response(get(conn, "/thumbs/" <> @name), 404) == ""
  end

  test "画面は Chiezo ではなく Chidori の場所で指す" do
    assert Chidori.Chiezo.thumb_path("/v1/thumbs/" <> @name) == "/thumbs/" <> @name
    assert Chidori.Chiezo.thumb_path("/v1/thumbs/../x.webp") == nil
    assert Chidori.Chiezo.thumb_path("https://example.com/a.webp") == nil
  end

  test "画面に置く Chiezo へのリンクは、ブラウザから開ける宛先で組む" do
    # Chidori からはコンテナの名前で引き、ブラウザには LAN の宛先を渡す
    System.put_env("CHIEZO_BASE_URL", "http://chiezo-app:7010")
    System.put_env("CHIEZO_PUBLIC_URL", "http://chiezo.example.lan:7010/")
    on_exit(fn -> System.delete_env("CHIEZO_PUBLIC_URL") end)

    assert Chidori.Chiezo.url("/v1/sources") == "http://chiezo-app:7010/v1/sources"

    assert Chidori.Chiezo.link("/admin/collect") ==
             "http://chiezo.example.lan:7010/admin/collect"

    # 書いていなければ、引く宛先と同じ
    System.delete_env("CHIEZO_PUBLIC_URL")
    assert Chidori.Chiezo.link("/x") == "http://chiezo-app:7010/x"
  end
end
