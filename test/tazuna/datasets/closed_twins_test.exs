defmodule Tazuna.Datasets.ClosedTwinsTest do
  @moduledoc """
  閉店で消した店の片割れを探して、ざっと見るの回に確かめてもらうところ。
  見ているのは 4 つ —— **消した店の近くの似た名前の店を拾うこと**、
  **移転や別の名前は拾わないこと**、**名指しして割り込みを頼むこと**、
  **同じ組は二度頼まないこと**です。
  """

  use Tazuna.DataCase, async: false

  alias Tazuna.Datasets.ClosedTwins
  alias Tazuna.HttpStub

  @base "http://chiezo.test"
  @dataset %{collection: "tazuna_meals", survey_sweep: "ざっと見る"}

  # 閉店で消した店（場所つき）と、移転で消した店
  @tombstones [
    %{
      "title" => "Ninja Akasaka",
      "tags" => ["食事処", "_chiezo_removed"],
      "extra" => %{"removed_reason" => "2024年に閉店したため", "lat" => 35.6772, "lon" => 139.7374}
    },
    %{
      "title" => "移った店",
      "tags" => ["食事処", "_chiezo_removed"],
      "extra" => %{"removed_reason" => "近くへ移転したため", "lat" => 35.60, "lon" => 139.60}
    },
    %{
      "title" => "場所の無い店",
      "tags" => ["食事処", "_chiezo_removed"],
      "extra" => %{"removed_reason" => "閉店"}
    }
  ]

  # 閉店した店の近くに居るもの
  @near [
    %{
      "title" => "Ninja Akasaka (1772404)",
      "tags" => ["食事処"],
      "extra" => %{"lat" => 35.6773, "lon" => 139.7375}
    },
    %{"title" => "隣の蕎麦屋", "tags" => ["食事処"], "extra" => %{"lat" => 35.6771, "lon" => 139.7373}},
    # 消えたものは片割れに数えない（消した本人）
    %{
      "title" => "Ninja Akasaka",
      "tags" => ["食事処", "_chiezo_removed"],
      "extra" => %{"lat" => 35.6772, "lon" => 139.7374}
    }
  ]

  defp stub(focus \\ fn _body -> HttpStub.ok("{}") end) do
    parent = self()

    HttpStub.stub(fn
      %{method: :get, url: url} ->
        cond do
          String.contains?(url, "tag=_chiezo_removed") ->
            HttpStub.ok(
              Jason.encode!(%{"results" => @tombstones, "total" => length(@tombstones)})
            )

          String.contains?(url, "bbox=") ->
            send(parent, {:nearby, url})
            HttpStub.ok(Jason.encode!(%{"results" => @near}))
        end

      %{method: :post, url: url, body: body} ->
        send(parent, {:focus, url, Jason.decode!(body)})
        focus.(body)
    end)
  end

  describe "名前の見比べ" do
    test "見分けの札だけが違う名前は同じ店" do
      assert ClosedTwins.similar?("Ninja Akasaka (1772404)", "Ninja Akasaka")
      assert ClosedTwins.similar?("むとう (日本橋 08f2a1b3)", "むとう (2156584)")
      assert ClosedTwins.similar?("駅前のラーメン店", "afuri 新宿")
    end

    test "片方がもう片方を含むものも拾う" do
      assert ClosedTwins.similar?("洋食 エース", "エース")
    end

    test "短い名前の包含は拾わない（何にでも当たる）" do
      refute ClosedTwins.similar?("一蘭", "一")
      refute ClosedTwins.similar?("隣の蕎麦屋", "Ninja Akasaka")
    end

    test "移転は閉店に数えない（近くの 1 件こそが生きている本体）" do
      assert ClosedTwins.closed?("2024年に閉店したため")
      assert ClosedTwins.closed?("2021年3月31日に営業を終了")
      refute ClosedTwins.closed?("近くへ移転したため（旧店舗は閉店）")
      refute ClosedTwins.closed?("「はしご」に統合。")
    end
  end

  describe "探して頼む" do
    test "閉店した店の近くの、似た名前の生きている店だけを拾う" do
      stub()

      assert {:ok, [pair]} = ClosedTwins.find(@base, @dataset.collection)
      assert pair.twin == "Ninja Akasaka (1772404)"
      assert pair.closed == "Ninja Akasaka"
      assert pair.meters < 20

      # 場所を持つ閉店の墓標だけを探しに行く（移転・場所の無いものは探さない）
      assert_received {:nearby, _url}
      refute_received {:nearby, _url}
    end

    test "現地から営業中の報告で戻した店は、片割れとして頼まない" do
      # 頼むと、AI は消した店の理由（閉店）を信じて、現地で営業を見た店をもう一度消した
      reported = %{
        "title" => "Ninja Akasaka (1772404)",
        "tags" => ["食事処"],
        "opening" => "所在地: 東京都港区\n現地から営業中の報告。忍者屋敷風のレストラン。",
        "extra" => %{"lat" => 35.6773, "lon" => 139.7375}
      }

      HttpStub.stub(fn %{method: :get, url: url} ->
        if String.contains?(url, "tag=_chiezo_removed"),
          do:
            HttpStub.ok(
              Jason.encode!(%{"results" => @tombstones, "total" => length(@tombstones)})
            ),
          else: HttpStub.ok(Jason.encode!(%{"results" => [reported]}))
      end)

      assert {:ok, []} = ClosedTwins.find(@base, @dataset.collection)
      # AI にも、報告のある店は消さないよう頼んである
      assert ClosedTwins.note([%{twin: "A", closed: "B", reason: "閉店", meters: 5}]) =~
               "現地から営業中の報告"
    end

    test "まだ AI が見ていない店も探す（片割れはたいていそこに居る）" do
      stub()
      {:ok, _pairs} = ClosedTwins.find(@base, @dataset.collection)

      assert_received {:nearby, url}
      assert url =~ "include_removed=true"
    end

    test "名指しして、ざっと見るの回に割り込ませる" do
      stub()

      assert {:ok, 1} = ClosedTwins.ask(@base, @dataset)
      assert_received {:focus, url, body}
      assert url == @base <> "/v1/collect/tazuna_meals/focus"
      assert body["titles"] == ["Ninja Akasaka (1772404)"]
      assert body["sweep"] == "ざっと見る"
      # 何を確かめてほしいのか（消した店と理由）を添える
      assert body["note"] =~ "Ninja Akasaka"
      assert body["note"] =~ "2024年に閉店"
    end

    test "同じ組は二度頼まない" do
      stub()
      assert {:ok, 1} = ClosedTwins.ask(@base, @dataset)
      assert_received {:focus, _url, _body}

      assert {:ok, 0} = ClosedTwins.ask(@base, @dataset)
      refute_received {:focus, _url, _body}
    end

    test "断られたら控えず、次の回に頼み直す" do
      stub(fn _body -> {:ok, %{status: 409, body: ~s({"error":"busy"})}} end)
      assert {:error, :chiezo_busy} = ClosedTwins.ask(@base, @dataset)

      stub()
      assert {:ok, 1} = ClosedTwins.ask(@base, @dataset)
    end
  end
end
