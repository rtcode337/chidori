defmodule Chidori.News.TheatersTest do
  @moduledoc """
  映画館を探してお気に入りに入れるところ（`Chidori.News.Theaters`）と、上映時刻を調べるところ
  （`Chidori.News.Showtimes`）。見ているのは、**映画館が主な場所だけを近い順に出すこと**、
  **お気に入りに住所とサイトも残すこと**、**上映時刻の答えを館ごとに読めること**、
  **確かめられなかった館を「分からない」として扱うこと**です。
  """

  use Chidori.DataCase, async: false

  alias Chidori.News.Showtimes
  alias Chidori.News.Theaters

  @base "http://chiezo.example"

  defp cinema(id, name, lat, lon, feature \\ "category=cinema") do
    %{
      "title" => name,
      "extra" => %{
        "overture_id" => id,
        "feature" => feature,
        "lat" => lat,
        "lon" => lon,
        "address" => "東京都千代田区丸の内",
        "website" => "https://example.com/#{id}"
      }
    }
  end

  describe "辞典の映画館" do
    test "試写室と、辞典の確からしさが低い場所は出さず、名前の後ろの英語名と番号は落とす" do
      doc = fn name, confidence ->
        %{
          "title" => name,
          "extra" => %{
            "feature" => "category=cinema",
            "lat" => 35.0,
            "lon" => 139.0,
            "confidence" => confidence
          }
        }
      end

      assert Theaters.to_theater(doc.("サンプル試写室", 0.9)) == []
      assert Theaters.to_theater(doc.("株式会社サンプル", 0.9)) == []
      assert Theaters.to_theater(doc.("サンプル館", 0.5)) == []

      assert [%{name: "TOHOシネマズ 新宿"}] =
               Theaters.to_theater(doc.("TOHOシネマズ 新宿 (TOHO CINEMAS Shinjuku)", 0.9))

      assert [%{name: "P2"}] = Theaters.to_theater(doc.("P2 (133255)", 0.9))
    end
  end

  describe "AI に探させた映画館" do
    alias Chidori.News.TheaterFinder

    @answer """
    探しました。
    {"theaters": [
      {"name": "遠い館", "station": "立川駅", "access": "JR 中央線で 20 分", "minutes": 28,
       "address": "東京都立川市曙町2-1", "website": "https://example.com/far"},
      {"name": "TOHOシネマズ新宿", "station": "新宿駅", "access": "徒歩 5 分", "minutes": 5,
       "address": "東京都新宿区歌舞伎町1-19-1", "website": "https://example.com/toho"},
      {"name": "TOHO シネマズ 新宿", "station": "新宿駅", "access": "徒歩 5 分", "minutes": 6,
       "address": "東京都新宿区歌舞伎町1-19-1", "website": null},
      {"name": "存在しない館", "station": "中野駅", "access": "JR で 1 駅", "minutes": 12,
       "address": "東京都中野区中野5-1", "website": null}
    ]}
    """

    test "答えを読み、同じ館は 1 つにし、着くまでの時間が短い順に並べる" do
      assert ["TOHOシネマズ新宿", "存在しない館", "遠い館"] =
               TheaterFinder.parse(@answer) |> Enum.map(& &1.name)

      assert TheaterFinder.parse("ごめんなさい") == []
    end

    test "辞典の映画館と名前と住所で突き合わせ、合わない館には印を付ける" do
      cinemas = [
        %{
          id: "ov1",
          name: "TOHOシネマズ 新宿",
          address: "歌舞伎町1-19-1 新宿区",
          website: "https://www.tohotheater.jp",
          lat: 35.69,
          lon: 139.70
        },
        %{
          id: "ov2",
          name: "TOHOシネマズ 府中",
          address: "東京都府中市宮町1-50",
          website: nil,
          lat: 35.67,
          lon: 139.47
        }
      ]

      [toho, missing, _far] =
        TheaterFinder.parse(@answer) |> Enum.map(&TheaterFinder.match(&1, cinemas))

      assert %{id: "ov1", verified: true, lat: 35.69} = toho
      assert %{id: "ai:存在しない館", verified: false, lat: nil} = missing
    end

    test "名前は会社の名前だけでは当てない（TOHO の新宿と府中は別の館）" do
      alias Chidori.News.Theaters
      assert Theaters.similar_name?("TOHOシネマズ新宿", "TOHOシネマズ 新宿 (TOHO CINEMAS Shinjuku)")
      refute Theaters.similar_name?("TOHOシネマズ新宿", "TOHOシネマズ 府中")
    end

    test "頼む文に、出発地・時間の上限・時間の短い順・同じ館をまとめることを書く" do
      prompt = TheaterFinder.prompt("新宿駅", 30)
      assert prompt =~ "出発地: 新宿駅"
      assert prompt =~ "30 分以内に着ける映画館"
      assert prompt =~ "着くまでの時間が短い順"
      assert prompt =~ "同じ映画館は 1 つにまとめて"
      assert TheaterFinder.prompt({35.68123, 139.76712}, 15) =~ "出発地: 現在地（35.6812,139.7671）"
    end

    test "web を開いて頼み、辞典で確かめた答えを返す" do
      TheaterFinder.forget_cinemas()
      on_exit(&TheaterFinder.forget_cinemas/0)
      test_pid = self()

      Chidori.HttpStub.stub(fn
        %{method: :post, url: url, body: body} ->
          send(test_pid, {:asked, url, Jason.decode!(body)})
          Chidori.HttpStub.ok(Jason.encode!(%{"content" => @answer}))

        %{method: :get, url: url} ->
          assert url =~ "/v1/overture_japan/filter?"

          Chidori.HttpStub.ok(
            Jason.encode!(%{
              "results" => [
                %{
                  "title" => "TOHOシネマズ 新宿 (TOHO CINEMAS Shinjuku)",
                  "extra" => %{
                    "overture_id" => "ov1",
                    "feature" => "category=cinema",
                    "lat" => 35.69,
                    "lon" => 139.70,
                    "address" => "歌舞伎町1-19-1 新宿区",
                    "confidence" => 0.9
                  }
                }
              ]
            })
          )
      end)

      assert {:ok, %{origin: "新宿駅", minutes: 30, theaters: [toho | _]}} =
               TheaterFinder.ask(@base, "claude", "新宿駅", 30)

      assert %{id: "ov1", verified: true} = toho

      assert_received {:asked, url,
                       %{"backend" => "claude", "web" => true, "requested_by" => "chidori"}}

      assert url == @base <> "/v1/ai/complete"
    end
  end

  describe "お気に入り" do
    test "住所・サイト・座標も残し、同じ館は増えず、外せる" do
      theater = %{
        id: "t1",
        name: "サンプル館",
        address: "東京都千代田区丸の内",
        website: "https://example.com/t1",
        lat: 35.68,
        lon: 139.76
      }

      {:ok, first} = Theaters.add(theater)
      {:ok, second} = Theaters.add(theater)
      assert first == second

      assert [
               %{
                 id: "t1",
                 name: "サンプル館",
                 address: "東京都千代田区丸の内",
                 website: "https://example.com/t1"
               }
             ] =
               Theaters.favorites()

      assert MapSet.member?(Theaters.favorite_ids(), "t1")
      assert :ok = Theaters.remove("t1")
      assert Theaters.favorites() == []
    end
  end

  describe "上映時刻" do
    @answer """
    調べました。
    {"theaters": [
      {"name": "サンプル館", "found": true,
       "showings": [{"start": "19:30", "end": "21:40", "format": "IMAX"}, {"start": "18:00", "end": "", "format": ""}],
       "source": "https://example.com/t1/schedule", "note": ""},
      {"name": "別の館", "found": false, "showings": [], "source": null, "note": "上映予定なし"}
    ]}
    """

    test "答えを館ごとに読み、回は始まる順に並べる（前後に文が付いても読む）" do
      assert [one, other] = Showtimes.parse(@answer)

      assert one.found
      assert Enum.map(one.showings, & &1.start) == ["18:00", "19:30"]
      assert one.source == "https://example.com/t1/schedule"
      refute other.found
      assert other.note == "上映予定なし"
    end

    test "found でも回が無ければ「分からない」として扱い、読めない答えは空" do
      assert [%{found: false}] =
               Showtimes.parse(~s({"theaters": [{"name": "館", "found": true, "showings": []}]}))

      assert Showtimes.parse("ごめんなさい、分かりませんでした") == []
    end

    test "頼む文に、館の住所とサイト・日付と曜日・時刻を書き、推し量らないよう頼む" do
      prompt =
        Showtimes.prompt(
          "サンプル映画",
          [%{name: "サンプル館", address: "東京都千代田区丸の内", website: "https://example.com/t1"}],
          ~D[2026-10-19],
          {18, 0}
        )

      assert prompt =~ "映画「サンプル映画」"
      assert prompt =~ "2026-10-19（月曜）"
      assert prompt =~ "18:00 より後"
      assert prompt =~ "- サンプル館（東京都千代田区丸の内 / https://example.com/t1）"
      assert prompt =~ "推し量らずに"
    end

    test "頼める相手は web を持つ相手だけ（ワーカーは外す）" do
      Chidori.HttpStub.stub(fn _req ->
        Chidori.HttpStub.ok(
          Jason.encode!(%{
            "backends" => [
              %{
                "id" => "claude",
                "label" => "Claude Code CLI",
                "kind" => "backend",
                "web" => true
              },
              %{"id" => "local", "label" => "推論サーバ", "kind" => "backend", "web" => false},
              %{"id" => "worker:x", "label" => "ワーカー", "kind" => "worker", "web" => true}
            ]
          })
        )
      end)

      assert {:ok, [%{id: "claude", label: "Claude Code CLI"}]} = Showtimes.backends(@base)
    end

    test "web を開いて、名乗って、館ごとの答えを返す" do
      test_pid = self()

      Chidori.HttpStub.stub(fn %{method: :post, url: url, body: body} ->
        send(test_pid, {:asked, url, Jason.decode!(body)})
        Chidori.HttpStub.ok(Jason.encode!(%{"content" => @answer}))
      end)

      assert {:ok, %{theaters: [_, _]}} =
               Showtimes.ask(
                 @base,
                 "claude",
                 "サンプル映画",
                 [%{name: "サンプル館"}],
                 ~D[2026-10-19],
                 {18, 0}
               )

      assert_received {:asked, url,
                       %{"backend" => "claude", "web" => true, "requested_by" => "chidori"}}

      assert url == @base <> "/v1/ai/complete"
    end
  end

  describe "調べた結果の置き場" do
    alias Chidori.News.AskStore

    test "答えは画面ではなく置き場に残り、知らせも届く（調べている最中に画面を移っても読める）" do
      # 置き場はテストどうしで共有なので、空に戻しておく（残すと別のテストの画面が読む）
      on_exit(fn -> AskStore.finished(:showtimes, nil) end)
      Phoenix.PubSub.subscribe(Chidori.PubSub, AskStore.topic(:showtimes))

      AskStore.started(:showtimes, %{"title" => "サンプル映画"})
      assert_receive {:showtimes, :loading}
      assert %{state: :loading, form: %{"title" => "サンプル映画"}} = AskStore.get(:showtimes)

      AskStore.finished(
        :showtimes,
        {:ok, %{theaters: [], raw: "", title: "サンプル映画", date: "2026-10-19", from: "18:00"}}
      )

      assert_receive {:showtimes, {:ok, _}}

      # 頼んだときのフォームの値は残す（戻ってきた画面に同じ選び方を出す）
      assert %{state: {:ok, %{title: "サンプル映画"}}, form: %{"title" => "サンプル映画"}} =
               AskStore.get(:showtimes)
    end
  end

  describe "画面" do
    import Phoenix.LiveViewTest

    test "探した館に印、お気に入りと上映時刻の表、確かめられなかった館の一言を出す" do
      html =
        render_component(&ChidoriWeb.TheaterPanel.panel/1,
          search:
            {:ok,
             %{
               origin: "新宿駅",
               minutes: 30,
               raw: "",
               theaters: [
                 %{
                   id: "t1",
                   name: "サンプル館",
                   station: "新宿駅",
                   access: "徒歩 5 分",
                   minutes: 5,
                   address: nil,
                   website: nil,
                   lat: 35.69,
                   lon: 139.70,
                   verified: true
                 },
                 %{
                   id: "ai:別の館",
                   name: "別の館",
                   station: "中野駅",
                   access: "JR で 1 駅",
                   minutes: 12,
                   address: nil,
                   website: nil,
                   lat: nil,
                   lon: nil,
                   verified: false
                 }
               ]
             }},
          favorites: [%{id: "t1", name: "サンプル館", address: nil, website: nil}],
          showing: [%{title: "サンプル映画"}],
          backends: {:ok, [%{id: "claude", label: "Claude Code CLI"}]},
          showtimes:
            {:ok,
             %{
               title: "サンプル映画",
               date: "2026-10-19",
               from: "18:00",
               raw: "",
               theaters: [
                 %{
                   name: "サンプル館",
                   found: true,
                   showings: [%{start: "19:30", end: "21:40", format: "IMAX"}],
                   source: nil,
                   note: ""
                 },
                 %{name: "別の館", found: false, showings: [], source: nil, note: ""}
               ]
             }}
        )

      assert html =~ "新宿駅から 30 分以内に着ける映画館（2 館。着くまでの時間が短い順）"
      assert html =~ "約 5 分"
      assert html =~ "JR で 1 駅"
      assert html =~ "辞典で確かめられない"
      assert html =~ ~s(phx-value-id="ai:別の館")
      assert html =~ "お気に入りの館で調べる"
      assert html =~ "19:30"
      assert html =~ "確かめられませんでした"
    end

    test "上映時刻を調べる作品は、公開中か 1 週間以内に公開されるもの" do
      today = Chidori.Jst.today()

      works = [
        %{title: "公開中", date: Date.add(today, -5), attention: :mid},
        %{title: "来週", date: Date.add(today, 5), attention: :high},
        %{title: "来月", date: Date.add(today, 40), attention: :high}
      ]

      assert ["来週", "公開中"] = Enum.map(ChidoriWeb.NewsLive.showing_works({:ok, works}), & &1.title)
      assert ChidoriWeb.NewsLive.showing_works(:loading) == []
    end
  end

  describe "作品の詳細の上映スケジュール" do
    import Phoenix.LiveViewTest

    @result {:ok,
             %{
               title: "サンプル映画",
               date: "2026-10-19",
               from: "18:00",
               raw: "",
               theaters: [
                 %{
                   name: "サンプル館",
                   found: true,
                   showings: [%{start: "19:30", end: "", format: ""}],
                   source: nil,
                   note: ""
                 }
               ]
             }}

    defp box(title, state, favorites \\ [%{id: "t1", name: "サンプル館"}]) do
      render_component(&ChidoriWeb.TheaterPanel.showtime_box/1,
        title: title,
        favorites: favorites,
        backends: {:ok, [%{id: "claude", label: "Claude Code CLI"}]},
        state: state,
        form: %{"title" => "サンプル映画"}
      )
    end

    test "その作品を調べる欄と、その作品の答えを出す" do
      html = box("サンプル映画", @result)

      assert html =~ ~s(name="title" value="サンプル映画")
      assert html =~ "お気に入りの館で調べる"
      assert html =~ "19:30"
    end

    test "ほかの作品の答えは出さず、お気に入りが無ければ映画の画面へ案内する" do
      refute box("別の映画", @result) =~ "19:30"
      assert box("別の映画", nil, []) =~ "お気に入りの映画館を入れると"
    end
  end

  describe "上映の始まる順と、館の場所" do
    test "館をまたいで、上映の始まる順に 1 本に並べる（確かめられなかった館は入れない）" do
      rows =
        ChidoriWeb.TheaterPanel.timeline([
          %{
            name: "B館",
            found: true,
            showings: [
              %{start: "21:00", end: "", format: ""},
              %{start: "18:30", end: "", format: ""}
            ]
          },
          %{
            name: "A館",
            found: true,
            showings: [
              %{start: "19:15", end: "", format: "IMAX"},
              %{start: "9:05", end: "", format: ""}
            ]
          },
          %{name: "C館", found: false, showings: []}
        ])

      assert Enum.map(rows, &{&1.start, &1.theater}) ==
               [{"9:05", "A館"}, {"18:30", "B館"}, {"19:15", "A館"}, {"21:00", "B館"}]
    end

    test "いちばん近い駅を、同じ名前の点のうち最も近いもので測り、徒歩の分で言う" do
      Chidori.HttpStub.stub(fn _req ->
        Chidori.HttpStub.ok(
          Jason.encode!(%{
            "results" => [
              %{"title" => "新宿 (node:1)", "extra" => %{"lat" => 35.6905, "lon" => 139.7005}},
              %{"title" => "新宿三丁目", "extra" => %{"lat" => 35.6920, "lon" => 139.7060}},
              %{"title" => "遠い駅", "extra" => %{"lat" => 35.75, "lon" => 139.80}}
            ]
          })
        )
      end)

      assert %{name: "新宿駅", distance: d} = Theaters.nearest_station(@base, 35.6909, 139.7003)
      assert d < 100
      assert Theaters.station_label(%{station: "新宿駅", station_distance: 240}) == "新宿駅 徒歩約 3 分"
      assert Theaters.station_label(%{station: nil, station_distance: nil}) == nil
    end

    test "前から入っているお気に入りに、最寄り駅を足す" do
      {:ok, _} = Theaters.add(%{id: "t1", name: "サンプル館", lat: 35.6909, lon: 139.7003})

      Chidori.HttpStub.stub(fn _req ->
        Chidori.HttpStub.ok(
          Jason.encode!(%{
            "results" => [%{"title" => "新宿", "extra" => %{"lat" => 35.6905, "lon" => 139.7005}}]
          })
        )
      end)

      assert Theaters.fill_stations(@base) == 1
      assert [%{station: "新宿駅"}] = Theaters.favorites()
      # 足し終えたものには、もう引きに行かない
      assert Theaters.fill_stations(@base) == 0
    end

    test "頼む文に、館の最寄り駅も書く（同じ名前の別の館と取り違えないように）" do
      prompt =
        Showtimes.prompt("サンプル映画", [%{name: "サンプル館", station: "新宿駅"}], ~D[2026-10-19], {18, 0})

      assert prompt =~ "- サンプル館（最寄り 新宿駅）"
    end
  end
end
