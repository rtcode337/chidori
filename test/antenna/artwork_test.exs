defmodule Antenna.ArtworkTest do
  use ExUnit.Case, async: false

  alias Antenna.Artwork

  # 覚え書きはアプリ全体で 1 つなので、テストのあいだで持ち越さない
  setup do
    :ets.delete_all_objects(:antenna_artwork)
    :ok
  end

  defp summary(body), do: fn _request -> Antenna.HttpStub.ok(Jason.encode!(body)) end

  # 絵は Wikipedia、説明は Chiezo。**行き先で分ける**
  defp both(image, opening) do
    fn %{url: url} ->
      if String.contains?(url, "wikipedia.org") do
        Antenna.HttpStub.ok(Jason.encode!(%{"thumbnail" => %{"source" => image}}))
      else
        Antenna.HttpStub.ok(Jason.encode!(%{"title" => "印象・日の出", "opening" => opening}))
      end
    end
  end

  test "説明も絵も、まず Chiezo から引く" do
    # 取り込みが `page_props` から代表画像を拾って `extra.image` に入れている。
    # **外へ聞きに行く理由が無い**
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
    test_pid = self()

    Antenna.HttpStub.stub(fn %{url: url} ->
      if String.contains?(url, "wikipedia.org") do
        send(test_pid, :went_outside)
        Antenna.HttpStub.ok("{}")
      else
        Antenna.HttpStub.ok(
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

  test "Chiezo が画像を持っていなければ Wikipedia に聞く" do
    # 取り込み直す前の長期記憶には画像が入っていない（入れば通らなくなる）
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
    Antenna.HttpStub.stub(both("https://example.org/sunrise.jpg", "モネの作品。"))

    art = Artwork.lookup("印象・日の出")

    assert art.image == "https://example.org/sunrise.jpg"
    assert art.extract == "モネの作品。"
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

  test "Chiezo が無くても絵は出す" do
    # 説明が引けないだけ。図が出ないより、説明が無いほうがまし
    System.delete_env("CHIEZO_BASE_URL")
    Antenna.HttpStub.stub(summary(%{"thumbnail" => %{"source" => "https://e.test/a.jpg"}}))

    art = Artwork.lookup("何かの絵")

    assert art.image == "https://e.test/a.jpg"
    assert art.extract == nil
  end

  test "画像の無い記事は出さない" do
    # 見たいのは絵のほう。記事はあっても、載せられる画像が無いことは普通にある
    Antenna.HttpStub.stub(summary(%{"title" => "ある作品", "extract" => "説明。"}))

    assert Artwork.lookup("ある作品") == nil
  end

  test "記事そのものが無ければ出さない" do
    # AI が書いた作品名が実在しないときはこちら
    Antenna.HttpStub.stub(fn _request -> {:ok, %{status: 404, body: "{}"}} end)

    assert Artwork.lookup("記事の無い作品") == nil
  end

  test "一度引いたら覚える" do
    # **同じ画家を何度押しても外へは出ない。** 押されたときにだけ引く作りなので、
    # 覚えないと押した回数だけ Wikipedia を叩く
    test_pid = self()

    Antenna.HttpStub.stub(fn _request ->
      send(test_pid, :asked)
      Antenna.HttpStub.ok(Jason.encode!(%{"thumbnail" => %{"source" => "https://e.test/a.jpg"}}))
    end)

    assert Artwork.lookup("何かの絵").image == "https://e.test/a.jpg"
    assert_received :asked

    assert Artwork.lookup("何かの絵").image == "https://e.test/a.jpg"
    refute_received :asked
  end

  test "取れなかったことも覚える" do
    # 絵の無い画家がいちばん押される（出ないから何度も押す）
    test_pid = self()

    Antenna.HttpStub.stub(fn _request ->
      send(test_pid, :asked)
      {:ok, %{status: 404, body: "{}"}}
    end)

    assert Artwork.lookup("無い絵") == nil
    assert_received :asked

    assert Artwork.lookup("無い絵") == nil
    refute_received :asked
  end
end
