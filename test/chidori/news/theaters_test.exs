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

  describe "近くの映画館" do
    test "映画館が主な場所だけを、近い順に（商業施設は外す）" do
      test_pid = self()

      Chidori.HttpStub.stub(fn %{url: url} ->
        send(test_pid, {:asked, url |> URI.parse() |> Map.get(:query) |> URI.decode_query()})

        Chidori.HttpStub.ok(
          Jason.encode!(%{
            "results" => [
              cinema("far", "遠い館", 35.70, 139.77),
              cinema("near", "近い館", 35.6815, 139.7670),
              cinema("mall", "商業施設", 35.6813, 139.7668, "category=shopping_center")
            ]
          })
        )
      end)

      assert {:ok, [near, far]} = Theaters.near(@base, 35.6812, 139.7671)
      assert {near.name, far.name} == {"近い館", "遠い館"}
      assert near.distance < far.distance
      assert near.website == "https://example.com/near"
      assert_received {:asked, %{"tag" => "cinema", "bbox" => _bbox}}
    end

    test "距離は大円距離（m）" do
      # 東京駅から有楽町駅のあたりまで、おおよそ 800m
      assert Theaters.distance(35.6812, 139.7671, 35.6751, 139.7630) in 700..900
    end
  end

  describe "同じ館をまとめる" do
    defp t(name, lat, lon, opts \\ []) do
      %{
        id: name,
        name: name,
        lat: lat,
        lon: lon,
        website: opts[:website],
        address: nil,
        confidence: opts[:confidence] || 0.9
      }
    end

    test "英語名の写し・同じサイト・名前の重なりは 1 つにし、日本語名でサイトのあるほうを残す" do
      kept =
        Theaters.dedupe([
          t("TOHO Cinemas Shinjuku", 35.6950, 139.7020, website: "http://hlo.tohotheater.jp/x"),
          t("TOHOシネマズ 新宿", 35.6951, 139.7021, website: "https://www.tohotheater.jp"),
          t("White Cine Quinto", 35.6610, 139.6985, website: "https://www.cinequinto.com"),
          t("シネクイント", 35.6615, 139.6990, website: "http://www.cinequinto.com"),
          t("ポレポレ東中野", 35.7070, 139.6830),
          t("東中野ポレポレ座", 35.7075, 139.6834)
        ])

      assert Enum.sort(Enum.map(kept, & &1.name)) ==
               ["シネクイント", "ポレポレ東中野", "TOHOシネマズ 新宿"] |> Enum.sort()
    end

    test "同じ建物の別の館（どちらも日本語名で、サイトも名前も違う）はまとめない" do
      kept =
        Theaters.dedupe([
          t("シネマート新宿", 35.6905, 139.7040, website: "http://www.cinemart.co.jp/theater/shinjuku/"),
          t("角川シネマ新宿", 35.6906, 139.7041, website: "https://ej-anime-t.jp/shinjuku/")
        ])

      assert length(kept) == 2
    end

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

  describe "地域の候補" do
    test "駅 → 市区町村 → そのほかの順に、都道府県を添えて並べる" do
      Chidori.HttpStub.stub(fn %{url: url} ->
        uri = URI.parse(url)
        query = URI.decode_query(uri.query || "")

        cond do
          String.ends_with?(uri.path, "/search") ->
            Chidori.HttpStub.ok(
              Jason.encode!(%{
                "results" => [%{"title" => "川崎"}, %{"title" => "川崎市"}, %{"title" => "川崎駅前"}]
              })
            )

          query["title"] == "川崎" ->
            Chidori.HttpStub.ok(
              Jason.encode!(%{
                "title" => "川崎",
                "extra" => %{
                  "lat" => 35.9,
                  "lon" => 139.5,
                  "area" => "埼玉県",
                  "feature" => "place=quarter"
                }
              })
            )

          query["title"] == "川崎市" ->
            Chidori.HttpStub.ok(
              Jason.encode!(%{
                "title" => "川崎市",
                "extra" => %{
                  "lat" => 35.53,
                  "lon" => 139.7,
                  "area" => "神奈川県",
                  "feature" => "place=city"
                }
              })
            )

          true ->
            {:ok, %{status: 404, body: "{}"}}
        end
      end)

      assert {:ok, [first, second]} = Theaters.places(@base, "川崎")
      assert first.label == "川崎市（神奈川県）"
      assert second.label == "川崎（埼玉県）"
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
    alias Chidori.News.ShowtimeStore

    test "答えは画面ではなく置き場に残り、知らせも届く（調べている最中に画面を移っても読める）" do
      # 置き場はテストどうしで共有なので、空に戻しておく（残すと別のテストの画面が読む）
      on_exit(fn -> ShowtimeStore.finished(nil) end)
      Phoenix.PubSub.subscribe(Chidori.PubSub, ShowtimeStore.topic())

      ShowtimeStore.started(%{"title" => "サンプル映画"})
      assert_receive {:showtimes, :loading}
      assert %{state: :loading, form: %{"title" => "サンプル映画"}} = ShowtimeStore.get()

      ShowtimeStore.finished(
        {:ok, %{theaters: [], raw: "", title: "サンプル映画", date: "2026-10-19", from: "18:00"}}
      )

      assert_receive {:showtimes, {:ok, _}}

      # 頼んだときのフォームの値は残す（戻ってきた画面に同じ選び方を出す）
      assert %{state: {:ok, %{title: "サンプル映画"}}, form: %{"title" => "サンプル映画"}} =
               ShowtimeStore.get()
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
               place: "東京駅",
               lat: 35.68,
               lon: 139.76,
               radius: 5_000,
               theaters: [
                 %{id: "t1", name: "サンプル館", address: nil, website: nil, distance: 420},
                 %{id: "t2", name: "別の館", address: nil, website: nil, distance: 1530}
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

      assert html =~ "東京駅から 5km 以内の映画館（2 館。近い順。同じ館の重なりはまとめています）"
      assert html =~ "420m"
      assert html =~ "1.5km"
      assert html =~ ~s(phx-value-id="t2")
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
end
