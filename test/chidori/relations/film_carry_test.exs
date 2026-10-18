defmodule Chidori.Relations.FilmCarryTest do
  @moduledoc """
  最新情報の映画を映画の図へ引き継ぐ時計（`Chidori.Relations.FilmCarry`）。見ているのは、
  **決めた時刻にだけ頼むこと**（時刻が無ければ頼まない・過ぎて 30 分まで・済まなかった回は
  試し直す・画面から足した 1 回で時計の回を飛ばさない）と、**設定と前回の記録が DB に残ること**です。
  """

  use Chidori.DataCase, async: false

  alias Chidori.Relations.CarrySetting
  alias Chidori.Relations.FilmCarry

  # JST 13:00
  @now ~U[2026-10-18 04:00:00Z]
  # JST 12:00 の予定
  @slot ~U[2026-10-18 03:00:00Z]

  defp setting(attrs), do: struct(CarrySetting, Map.merge(%{run_at: "12:00"}, attrs))

  describe "頼む番か" do
    test "時刻を決めていなければ頼まない（既定）" do
      refute FilmCarry.due?(setting(%{run_at: ""}), @now)
      assert FilmCarry.next_at(setting(%{run_at: ""}), @now) == :off
    end

    test "予定を過ぎて 30 分までは拾い、それより過ぎた回は追わない" do
      assert FilmCarry.due?(setting(%{}), DateTime.add(@slot, 29 * 60, :second))
      refute FilmCarry.due?(setting(%{}), DateTime.add(@slot, 31 * 60, :second))
    end

    test "その回を頼めたら、次の予定まで頼まない" do
      done = setting(%{clock_at: DateTime.add(@slot, 60, :second), clock_ok: true})

      refute FilmCarry.due?(done, DateTime.add(@slot, 10 * 60, :second))
      # 次は翌日の JST 12:00
      assert FilmCarry.next_at(done, @now) == {:at, DateTime.add(@slot, 86_400, :second)}
    end

    test "済まなかった回は、次の予定まで試し直す（30 分を過ぎても）" do
      failed = setting(%{clock_at: DateTime.add(@slot, 60, :second), clock_ok: false})

      assert FilmCarry.due?(failed, @now)
      assert FilmCarry.next_at(failed, @now) == :retry
    end

    test "時計の回は、画面から足した 1 回とは別に数える" do
      # 画面から頼んだ記録（last_at）があっても、時計がまだならその回は頼む
      by_hand = setting(%{last_at: DateTime.add(@slot, 60, :second), last_by: "画面"})
      assert FilmCarry.due?(by_hand, DateTime.add(@slot, 5 * 60, :second))
    end
  end

  describe "設定と前回の記録" do
    test "時刻は書き方を揃えて持ち、読めない時刻と選べない数は断る" do
      assert {:ok, saved} = CarrySetting.put(%{run_at: "4:00, 1600", batch: 10})
      assert {saved.run_at, saved.batch} == {"04:00,16:00", 10}
      assert {:error, _changeset} = CarrySetting.put(%{run_at: "25:00"})
      assert {:error, _changeset} = CarrySetting.put(%{batch: 7})
      assert CarrySetting.get().run_at == "04:00,16:00"
    end

    test "頼んだ結果を残す（1 行だけ）。時計の回だけが時計の記録を動かす" do
      {:ok, _} = CarrySetting.record("時計", ["サンプル映画"], :ok)
      {:ok, _} = CarrySetting.record("画面", ["別の映画"], {:error, "混んでいました"})

      last = CarrySetting.get()
      assert {last.last_by, last.last_titles} == {"画面", ["別の映画"]}
      assert last.last_result == "頼めませんでした: 混んでいました"
      refute CarrySetting.ok?(last)
      # 時計の記録は、時計が頼めた回のまま
      assert last.clock_ok
      assert Repo.aggregate(CarrySetting, :count) == 1
    end

    test "まだのものが無かった回も、済んだとして残す" do
      {:ok, _} = CarrySetting.record("時計", [], :nothing)
      last = CarrySetting.get()
      assert last.last_result == "引き継ぐものはありませんでした"
      assert last.clock_ok
    end
  end

  describe "設定ページの行" do
    test "映画の図の収集にだけ、引き継ぎの行が付く（時刻と 1 回の数を直せる）" do
      {:ok, _} = CarrySetting.put(%{run_at: "04:00", batch: 30})

      assert [row] = Chidori.CollectOverview.chidori_rows("chidori_films")
      assert row.name == "最新情報からの引き継ぎ"
      assert row.clock == "Chidori が起こす（04:00）"
      assert row.wake == {:carry, "04:00", 30}
      assert row.virtual

      assert Chidori.CollectOverview.chidori_rows("chidori_people") == []
    end

    test "設定ページの表（定義から組み直した行）にも、引き継ぎの行が残る" do
      rows = Chidori.CollectCatalog.rows_with([], fn _entry, _chiezo -> [] end)
      films = Enum.find(rows, &(&1.name == "chidori_films"))

      assert "最新情報からの引き継ぎ" in Enum.map(films.sweeps, & &1.name)
    end
  end

  describe "引き継ぎ済みの見出し" do
    test "図の作品の見出しと `記録:` の両方を、500 件ずつページを送って全部読む" do
      test_pid = self()

      Chidori.HttpStub.stub(fn %{url: url} ->
        query = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
        send(test_pid, {:asked, query})
        offset = String.to_integer(query["offset"])
        count = if offset == 0, do: 500, else: 2

        docs =
          for i <- 1..count//1 do
            %{"title" => "作品#{offset + i}", "tags" => ["映画", "記録:元の題#{offset + i}"]}
          end

        Chidori.HttpStub.ok(Jason.encode!(%{"results" => docs, "total" => 502}))
      end)

      assert {:ok, carried} = FilmCarry.carried("http://chiezo.example")
      assert MapSet.size(carried) == 1004
      assert MapSet.member?(carried, "作品502")
      assert MapSet.member?(carried, "元の題1")

      assert_received {:asked, %{"limit" => "500", "offset" => "0", "tag" => "映画"}}
      assert_received {:asked, %{"limit" => "500", "offset" => "500"}}
    end
  end

  describe "頼む順と、頼むのをやめる作品" do
    alias Chidori.Relations.Mark

    test "見た作品（見た日の新しい順）→ 注目度の高い作品（公開日の新しい順）。済んだものは外す" do
      marks = %{
        "古く見た" => %Mark{seen_on: ~D[2026-01-01]},
        "最近見た" => %Mark{seen_on: ~D[2026-10-01]},
        "図に居る" => %Mark{seen_on: ~D[2026-10-10]}
      }

      released = [
        %{title: "前の公開", date: ~D[2026-08-01]},
        %{title: "最近の公開", date: ~D[2026-10-01]}
      ]

      items = FilmCarry.order(MapSet.new(["図に居る"]), released, marks, %CarrySetting{})

      assert Enum.map(items, & &1.title) == ["最近見た", "古く見た", "最近の公開", "前の公開"]
    end

    test "何度頼んでも載らなかった作品は、時計の回から外す（枠の頭を占め続けない）" do
      marks = for t <- ["載らない", "次"], into: %{}, do: {t, %Mark{seen_on: nil}}
      setting = %CarrySetting{attempts: %{"載らない" => CarrySetting.max_attempts()}}

      assert [%{title: "次"}] = FilmCarry.order(MapSet.new(), [], marks, setting, 1)
      # 画面には残して、回数を見せる
      assert [%{title: "次", tries: 0}, %{title: "載らない", tries: 3}] =
               FilmCarry.order(MapSet.new(), [], marks, setting) |> Enum.sort_by(& &1.title)
    end

    test "頼んだ回数を数え、載った作品の回数は消す" do
      {:ok, _} = CarrySetting.count_attempts(["甲", "乙"])
      {:ok, _} = CarrySetting.count_attempts(["甲"], MapSet.new(["乙"]))

      assert CarrySetting.get().attempts == %{"甲" => 2}
    end
  end
end
