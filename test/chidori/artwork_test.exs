defmodule Chidori.ArtworkTest do
  use ExUnit.Case, async: false

  alias Chidori.Artwork

  # 覚え書きはアプリ全体で 1 つなので、テストのあいだで持ち越さない
  setup do
    :ets.delete_all_objects(:chidori_artwork)
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
    :ok
  end

  # Chiezo の jawiki の 1 件（`doc`）
  defp jawiki(doc), do: fn _request -> Chidori.HttpStub.ok(Jason.encode!(doc)) end

  test "説明も絵も Chiezo から引く" do
    # 取り込みが `page_props` から代表画像を拾って `extra.image` に入れている。
    # **外へ聞きに行く理由が無い**
    test_pid = self()

    Chidori.HttpStub.stub(fn %{url: url} ->
      if String.contains?(url, "wikipedia.org") do
        send(test_pid, :went_outside)
        Chidori.HttpStub.ok("{}")
      else
        Chidori.HttpStub.ok(
          Jason.encode!(%{
            "title" => "印象・日の出",
            "opening" => "モネの作品。",
            "extra" => %{
              "image" => "https://upload.wikimedia.org/wikipedia/commons/5/54/Sunrise.jpg"
            }
          })
        )
      end
    end)

    art = Artwork.lookup("印象・日の出")

    assert art.extract == "モネの作品。"
    # 札に出すだけなので原寸は指さない
    assert art.image ==
             "https://upload.wikimedia.org/wikipedia/commons/thumb/5/54/Sunrise.jpg/500px-Sunrise.jpg"

    refute_received :went_outside
  end

  test "出典は記事のページを指す" do
    Chidori.HttpStub.stub(
      jawiki(%{
        "title" => "印象・日の出",
        "extra" => %{"image" => "https://example.org/sunrise.jpg"}
      })
    )

    art = Artwork.lookup("印象・日の出")

    assert art.image == "https://example.org/sunrise.jpg"
    assert art.page =~ "ja.wikipedia.org"
  end

  test "Commons 以外の URL はそのまま指す" do
    assert Artwork.thumb("https://example.org/a.jpg") == "https://example.org/a.jpg"

    already = "https://upload.wikimedia.org/wikipedia/commons/thumb/5/54/A.jpg/320px-A.jpg"
    assert Artwork.thumb(already) == already
  end

  test "SVG の縮小版は PNG になる" do
    assert Artwork.thumb("https://upload.wikimedia.org/wikipedia/commons/1/12/A.svg") ==
             "https://upload.wikimedia.org/wikipedia/commons/thumb/1/12/A.svg/500px-A.svg.png"
  end

  test "受け付けない幅を頼まれたら、組み替えずに原寸を指す" do
    # Commons は決まった幅しか受け付けず、それ以外は 400 を返す。組み替えた URL を
    # そのまま出すと、絵が 1 枚残らず消える（640 を頼んでいて実際にそうなった）
    original = "https://upload.wikimedia.org/wikipedia/commons/5/54/A.jpg"

    assert Artwork.thumb(original, 640) == original
    assert Artwork.thumb(original, 800) == original
  end

  test "受け付ける幅なら組み替える" do
    original = "https://upload.wikimedia.org/wikipedia/commons/5/54/A.jpg"

    assert Artwork.thumb(original, 250) ==
             "https://upload.wikimedia.org/wikipedia/commons/thumb/5/54/A.jpg/250px-A.jpg"
  end

  test "Chiezo が無ければ出さない" do
    System.delete_env("CHIEZO_BASE_URL")
    Chidori.HttpStub.stub(fn _request -> flunk("Chiezo が無いのに外へ出ている") end)

    assert Artwork.lookup("何かの絵") == nil
  end

  test "画像の無い記事は出さない" do
    # 見たいのは絵のほう。記事はあっても、載せられる画像が無いことは普通にある
    Chidori.HttpStub.stub(jawiki(%{"title" => "ある作品", "opening" => "説明。"}))

    assert Artwork.lookup("ある作品") == nil
  end

  test "記事そのものが無ければ出さない" do
    # AI が書いた作品名が実在しないときはこちら
    Chidori.HttpStub.stub(fn _request -> {:ok, %{status: 404, body: "{}"}} end)

    assert Artwork.lookup("記事の無い作品") == nil
  end

  test "一度引いたら覚える" do
    # 同じ画家を何度押しても聞き直さない。押されたときにだけ引く作りなので、
    # 覚えないと押した回数だけ Chiezo を叩く
    test_pid = self()

    Chidori.HttpStub.stub(fn _request ->
      send(test_pid, :asked)
      Chidori.HttpStub.ok(Jason.encode!(%{"extra" => %{"image" => "https://e.test/a.jpg"}}))
    end)

    assert Artwork.lookup("何かの絵").image == "https://e.test/a.jpg"
    assert_received :asked

    assert Artwork.lookup("何かの絵").image == "https://e.test/a.jpg"
    refute_received :asked
  end

  test "取れなかったことも覚える" do
    # 絵の無い画家がいちばん押される（出ないから何度も押す）
    test_pid = self()

    Chidori.HttpStub.stub(fn _request ->
      send(test_pid, :asked)
      {:ok, %{status: 404, body: "{}"}}
    end)

    assert Artwork.lookup("無い絵") == nil
    assert_received :asked

    assert Artwork.lookup("無い絵") == nil
    refute_received :asked
  end
end
