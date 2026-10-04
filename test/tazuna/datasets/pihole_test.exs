defmodule Tazuna.Datasets.PiholeTest do
  @moduledoc """
  Pi-hole の止めたドメインと気になる通信。見ているのは、**名簿を機械で足すだけで引くこと**
  （調べた本文を名簿の文で上書きしない）、**整理の回が判定を決まった語で付けること**、
  **一覧がまだ調べていないものも並べ、消えたものは落とすこと**です。
  """

  use ExUnit.Case, async: false

  alias Tazuna.Datasets.Pihole
  alias Tazuna.HttpStub

  describe "依頼の中身" do
    test "名簿は Chiezo の取り込み（pihole）から、足すだけで引く" do
      [spec] = Pihole.extract()

      assert spec.source == "pihole"
      assert spec.tag == "Pi-hole"

      # 回数や端末は引き直すたびに最新へ（脇書きは Chiezo が入れ替える）
      assert "blocked_count" in spec.extra and "clients" in spec.extra
      # Chiezo が 1 本の指定で運べる脇書きは 10 個まで
      assert length(spec.extra) <= 10

      machine = Enum.find(Pihole.sweeps(), &(&1.name == Tazuna.SweepNames.machine()))
      assert machine.use_extract and machine.only_new
    end

    test "整理は web で調べ、まだ調べていないものを決まった数ずつ、重みの順に渡す" do
      tidy = Enum.find(Pihole.sweeps(), &(&1.name == Tazuna.SweepNames.tidy()))

      assert tidy.web
      assert tidy.unreviewed_per_run > 0
      assert tidy.unreviewed_by == "priority"
      assert tidy.after == Tazuna.SweepNames.machine()

      %{sweeps: sweeps} = Pihole.attrs()
      prompt = Enum.find(sweeps, &(&1.name == Tazuna.SweepNames.tidy())).prompt
      assert prompt =~ "{unreviewed}"
      # 判定は 3 つの語から選ばせる（自由に書かせると一覧で揃わない）
      for verdict <- Pihole.verdicts(), do: assert(prompt =~ "判定:#{verdict}")
    end

    test "画面で選んだ相手は巡回に重ねる" do
      choices = %{Tazuna.SweepNames.tidy() => %{backend: "codex", model: nil}}
      %{sweeps: sweeps} = Pihole.attrs(choices)

      assert Enum.find(sweeps, &(&1.name == Tazuna.SweepNames.tidy())).backend == "codex"
    end
  end

  describe "1 件を読む" do
    test "タグと脇書きから、一覧の 1 行を作る" do
      domain =
        Pihole.to_domain(%{
          "title" => "beacon.example.com",
          "tags" => ["Pi-hole", "気になる通信", "理由:規則正しい周期", "判定:要注意"],
          "opening" => "■ ひとことでいうと\n見知らぬ機器の定期通信。確かめたほうがよい。\n■ 何のドメインか\n不明",
          "extra" => %{"queries" => 12, "clients" => ["192.0.2.10: 12 回"], "priority" => 600}
        })

      assert domain.watch and not domain.blocked
      assert domain.reasons == ["規則正しい周期"]
      assert domain.verdict == "要注意"
      assert domain.researched
      # 調べたものは「ひとことでいうと」の段だけを一覧に出す
      assert domain.summary == "見知らぬ機器の定期通信。確かめたほうがよい。"
    end

    test "まだ調べていないものは観測の文のまま、判定も無い" do
      domain =
        Pihole.to_domain(%{
          "title" => "ads.example.com",
          "tags" => ["Pi-hole", "ブロック", "判定:たぶん平気", Tazuna.Chiezo.unreviewed_tag()],
          "opening" => "Pi-hole がこの 30 日に 120 回止めた。",
          "extra" => %{"blocked_count" => 120}
        })

      refute domain.researched
      # 決まった語でない判定は拾わない
      assert domain.verdict == nil
      assert domain.blocked_count == 120
      assert domain.summary == "Pi-hole がこの 30 日に 120 回止めた。"
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
                    "extra" => %{"blocked_count" => 5, "priority" => 100}
                  },
                  %{
                    "title" => "new.example.net",
                    "tags" => ["Pi-hole", "気になる通信"],
                    "extra" => %{"priority" => 600}
                  },
                  %{
                    "title" => "gone.example.org",
                    "tags" => ["Pi-hole", Tazuna.Chiezo.removed_tag()]
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
end
