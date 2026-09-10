defmodule Antenna.FameTest do
  use Antenna.DataCase, async: false

  alias Antenna.Fame
  alias Antenna.HttpStub

  @base "http://chiezo.test:7010"

  defp views_body(count), do: Jason.encode!(%{"extra" => %{"pageviews_month" => count}})

  # 引きに来た記事名を送り返すスタブ（何回・どれを引いたかを見る）
  defp stub_views(counts) do
    test_pid = self()

    HttpStub.stub(fn %{method: :get, url: url} ->
      title = url |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("title")
      send(test_pid, {:asked, title})

      case Map.fetch(counts, title) do
        {:ok, count} -> HttpStub.ok(views_body(count))
        :error -> {:ok, %{status: 404, body: ""}}
      end
    end)
  end

  test "月次ページビューを引く" do
    stub_views(%{"モネ" => 12_345})
    assert Fame.for_articles(@base, ["モネ"]) == %{"モネ" => 12_345}
  end

  test "二度目は控えを使い、引きに行かない" do
    # 記事 1 本につき 1 リクエストなので、人数がそのまま往復の数になる
    stub_views(%{"モネ" => 100})

    assert Fame.for_articles(@base, ["モネ"]) == %{"モネ" => 100}
    assert_received {:asked, "モネ"}

    assert Fame.for_articles(@base, ["モネ"]) == %{"モネ" => 100}
    refute_received {:asked, "モネ"}
  end

  test "足りないものだけ引きに行く" do
    stub_views(%{"モネ" => 100, "ゴッホ" => 200})
    Fame.for_articles(@base, ["モネ"])
    assert_received {:asked, "モネ"}

    assert Fame.for_articles(@base, ["モネ", "ゴッホ"]) == %{"モネ" => 100, "ゴッホ" => 200}
    assert_received {:asked, "ゴッホ"}
    refute_received {:asked, "モネ"}
  end

  test "引けなかったことも控える" do
    # 控えないと、値を持たない記事を開くたびに引きに行くことになる
    stub_views(%{})

    assert Fame.for_articles(@base, ["無い人"]) == %{"無い人" => 0}
    assert_received {:asked, "無い人"}

    assert Fame.for_articles(@base, ["無い人"]) == %{"無い人" => 0}
    refute_received {:asked, "無い人"}
  end

  test "古くなった控えは引き直す" do
    stub_views(%{"モネ" => 100})
    Fame.for_articles(@base, ["モネ"])
    assert_received {:asked, "モネ"}

    # 期限より前に引いたことにする
    old = DateTime.utc_now() |> DateTime.add(-30 * 24 * 3600, :second) |> DateTime.truncate(:second)
    Antenna.Repo.update_all(Antenna.ArticleFame, set: [fetched_at: old])

    stub_views(%{"モネ" => 999})
    assert Fame.for_articles(@base, ["モネ"]) == %{"モネ" => 999}
    assert_received {:asked, "モネ"}
  end

  test "同じ記事名を並べても 1 回しか引かない" do
    stub_views(%{"モネ" => 100})
    assert Fame.for_articles(@base, ["モネ", "モネ", "モネ"]) == %{"モネ" => 100}

    assert_received {:asked, "モネ"}
    refute_received {:asked, "モネ"}
  end

  test "記事名が無ければ何も引かない" do
    HttpStub.stub(fn _request -> flunk("引きに行っている") end)
    assert Fame.for_articles(@base, [nil, ""]) == %{}
  end
end
