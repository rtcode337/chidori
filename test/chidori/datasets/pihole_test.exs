defmodule Chidori.Datasets.PiholeTest do
  @moduledoc """
  Pi-hole の止めたドメインと気になる通信。見ているのは、**機械収集が Chiezo の
  Pi-hole から引く回で足すだけなこと**（調べた本文を上書きしない）、**集計を脇書きから読むこと**、**整理の回が判定を決まった語で付けること**、
  **一覧がまだ調べていないものも並べ、消えたものは落とすこと**です。
  """

  use ExUnit.Case, async: false

  alias Chidori.Datasets.Pihole
  alias Chidori.HttpStub

  describe "依頼の中身" do
    test "機械収集は Chiezo が Pi-hole から引く回で、足すだけ" do
      machine = Enum.find(Pihole.sweeps(), &(&1.name == Chidori.SweepNames.machine()))
      assert machine.use_pihole and machine.only_new

      # 前の版で送った名簿の指定は消す（残ると 1 回目が名簿の回として走る）
      attrs = Pihole.attrs()
      # null は Chiezo が「触らない」と読むので、空のオブジェクトで外す
      assert attrs.extract == %{}
    end

    test "整理は、まだ調べていないものを決まった数ずつ、重みの順に渡す" do
      tidy = Enum.find(Pihole.sweeps(), &(&1.name == Chidori.SweepNames.tidy()))

      # web 検索は巡回ごとには決められない（Chiezo の収集ぜんたいの設定）ので送らない
      refute Map.has_key?(tidy, :web)
      assert tidy.unreviewed_per_run > 0
      assert tidy.unreviewed_by == "priority"
      assert tidy.after == Chidori.SweepNames.machine()

      %{sweeps: sweeps} = Pihole.attrs()
      prompt = Enum.find(sweeps, &(&1.name == Chidori.SweepNames.tidy())).prompt
      assert prompt =~ "{unreviewed}"
      # 判定は 3 つの語から選ばせる（自由に書かせると一覧で揃わない）
      for verdict <- Pihole.verdicts(), do: assert(prompt =~ "判定:#{verdict}")
    end

    test "画面で選んだ相手は巡回に重ねる" do
      choices = %{Chidori.SweepNames.tidy() => %{backend: "codex", model: nil}}
      %{sweeps: sweeps} = Pihole.attrs(choices)

      assert Enum.find(sweeps, &(&1.name == Chidori.SweepNames.tidy())).backend == "codex"
    end
  end

  describe "1 件を読む" do
    test "タグと脇書きから、一覧の 1 行を作る" do
      domain =
        Pihole.to_domain(%{
          "title" => "beacon.example.com",
          "tags" => ["Pi-hole", "気になる通信", "理由:規則正しい周期", "判定:要注意"],
          "opening" => "■ ひとことでいうと\n見知らぬ機器の定期通信。確かめたほうがよい。\n■ 何のドメインか\n不明",
          "extra" => %{
            "first_seen" => "2026-10-01T00:00:00+00:00",
            "last_seen" => "2026-10-04T12:00:00+00:00",
            "queries" => 12,
            "clients" => ["192.0.2.10", "192.0.2.20"],
            "client_counts" => [10, 2],
            "client_names" => ["tablet", ""],
            "reasons" => ["192.0.2.10 が 5 分おきに 8 回、規則正しく引いている"],
            "watched_at" => "2026-10-04T12:00:00+00:00",
            "priority" => 600
          }
        })

      assert domain.watch and not domain.blocked
      assert domain.reasons == ["規則正しい周期"]
      assert domain.observed == ["192.0.2.10 が 5 分おきに 8 回、規則正しく引いている"]
      assert domain.verdict == "要注意"
      assert domain.researched
      assert domain.first_seen == "2026-10-01T00:00:00+00:00"

      # アクセス元ごとの回数は 1 つの並びにする（名前の無いものは nil）
      assert domain.clients == [
               %{ip: "192.0.2.10", name: "tablet", count: 10},
               %{ip: "192.0.2.20", name: nil, count: 2}
             ]

      # 調べたものは「ひとことでいうと」の段だけを一覧に出す
      assert domain.summary == "見知らぬ機器の定期通信。確かめたほうがよい。"
    end

    test "いまの状態は脇書きで読む（タグは最初の 1 回にしか付かない）" do
      # 普通の通信として溜まり始め、あとで止めるようになったドメイン
      domain =
        Pihole.to_domain(%{
          "title" => "ads.example.com",
          "tags" => ["Pi-hole", "判定:たぶん平気", Chidori.Chiezo.unreviewed_tag()],
          "opening" => "Pi-hole が 120 回止めた。",
          "extra" => %{"blocked" => 120, "watched_at" => "2026-10-04T12:00:00+00:00"}
        })

      assert domain.blocked and domain.watch
      refute domain.researched
      # 決まった語でない判定は拾わない
      assert domain.verdict == nil
      assert domain.blocked_count == 120
      assert domain.summary == "Pi-hole が 120 回止めた。"
    end
  end

  describe "一覧" do
    setup do
      parent = self()

      HttpStub.stub(fn %{method: :get, url: url} ->
        send(parent, {:asked, url})
        query = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

        HttpStub.ok(
          Jason.encode!(%{
            "results" =>
              if query["offset"] == "0" do
                [
                  %{
                    "title" => "ads.example.com",
                    "tags" => ["Pi-hole", "ブロック"],
                    "extra" => %{"blocked" => 5, "priority" => 100}
                  },
                  %{
                    "title" => "new.example.net",
                    "tags" => ["Pi-hole", "気になる通信"],
                    "extra" => %{"priority" => 600}
                  },
                  %{
                    "title" => "gone.example.org",
                    "tags" => ["Pi-hole", Chidori.Chiezo.removed_tag()]
                  }
                ]
              else
                []
              end
          })
        )
      end)

      :ok
    end

    test "まだ調べていないものも並べ、消えたものは落とし、気になる通信を先にする" do
      assert {:ok, domains} = Pihole.list("http://chiezo.test")

      assert Enum.map(domains, & &1.domain) == ["new.example.net", "ads.example.com"]
      assert_received {:asked, url}
      assert url =~ "/v1/tazuna_pihole/filter?"
      assert url =~ "include_removed=true"
    end
  end

  describe "いま止めている通信" do
    test "Chiezo から続きを読み、行にする" do
      parent = self()

      HttpStub.stub(fn %{method: :get, url: url} ->
        send(parent, {:asked, url})

        HttpStub.ok(
          Jason.encode!(%{
            "now" => 1_759_600_010.0,
            "cursor" => 1_759_600_005.0,
            "queries" => [
              %{
                "id" => 1,
                "at" => "2026-10-04T12:00:05+00:00",
                "domain" => "ads.example.com",
                "client" => "192.0.2.10",
                "client_name" => "tablet",
                "status" => "GRAVITY"
              }
            ]
          })
        )
      end)

      assert {:ok, %{rows: [row], cursor: 1_759_600_005.0}} =
               Pihole.blocked_since("http://chiezo.test", 1_759_600_000)

      assert row.domain == "ads.example.com" and row.client_name == "tablet"
      assert_received {:asked, url}
      assert url =~ "/v1/pihole/blocked?"
      assert url =~ "since=1759600000"
    end

    test "接続先が無ければ、そう言う" do
      HttpStub.stub(fn %{method: :get} -> {:ok, %{status: 409, body: "{}"}} end)

      assert Pihole.blocked_since("http://chiezo.test", 0) == {:error, :pihole_not_configured}
    end
  end
end
