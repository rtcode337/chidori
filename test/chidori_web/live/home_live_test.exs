defmodule ChidoriWeb.HomeLiveTest do
  @moduledoc """
  トップページと、そこに並べる枠の設定。見ているのは、**選んだ枠が大きなタブにまとまり、
  決めた順に並び、最初の枠が開くこと**です。
  """

  use ChidoriWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Chidori.Home

  test "枠は大きなタブにまとまり、決めた順に並び、最初の枠が開く", %{conn: conn} do
    # 選んだ順ではなく、決めた順（ニュース → イベント → 関連図 → データ収集）
    Home.put(["books", "topic:chidori_tech", "relations:painters", "topic:chidori_news"])

    {:ok, _live, html} = live(conn, ~p"/")

    [_before, nav | _rest] = String.split(html, ~s(aria-label="トップページの大きなタブ"))
    [nav | _rest] = String.split(nav, "</nav>")

    [news, relations, datasets] =
      Enum.map(["ニュース", "関連図", "データ収集"], fn label ->
        nav |> :binary.match(label) |> elem(0)
      end)

    assert news < relations and relations < datasets
    refute nav =~ "イベント"

    # 最初の枠（一般ニュース）が開いている。ニュースの中の枠は短い名前で下の段に並ぶ
    assert html =~ ~s(aria-label="一般ニュース")
    [_before, sub | _rest] = String.split(html, ~s(class="home-subtabs"))
    [sub | _rest] = String.split(sub, "</nav>")
    assert :binary.match(sub, "一般") < :binary.match(sub, "技術")
  end

  test "大きなタブを押すと、その中の最初の枠が開く（中の枠が 1 つなら下の段は出さない）", %{conn: conn} do
    Home.put(["topic:chidori_news", "relations:painters"])

    {:ok, live, _html} = live(conn, ~p"/")

    live |> element("#home-tabs a", "関連図") |> render_click()
    assert_patch(live, "/?panel=relations%3Apainters")
    refute render(live) =~ "home-subtabs"
  end

  test "関連図は画面ごと埋め込む（頭のメニューは出さない）", %{conn: conn} do
    Home.put(["relations:painters"])

    {:ok, _live, html} = live(conn, ~p"/")
    assert html =~ ~s(src="/relations?view=painters&amp;embed=1")

    {:ok, _live, embedded} = live(conn, ~p"/relations?view=painters&embed=1")
    refute embedded =~ "主要メニュー"
  end

  test "注目イベントは、注目度が高いものを、これから 2 か月まで近い順に" do
    today = ~D[2026-10-01]
    event = fn title, date, attention -> %{title: title, date: date, attention: attention} end

    list =
      ChidoriWeb.HomeLive.upcoming(
        [
          event.("終わった", ~D[2026-09-30], :high),
          event.("先すぎる", ~D[2026-12-02], :high),
          event.("2 か月後", ~D[2026-12-01], :high),
          event.("来週・中", ~D[2026-10-08], :mid),
          event.("来週・高", ~D[2026-10-08], :high),
          event.("今日・高", ~D[2026-10-01], :high)
        ],
        [:high],
        today
      )

    # 中は出さない（中まで入れると、件数の上限で先の月が見えなくなる）
    assert Enum.map(list, & &1.title) == ["今日・高", "来週・高", "2 か月後"]
  end

  test "注目度が中のものも出す話題では、中も並べる（お笑いイベント）" do
    today = ~D[2026-10-01]
    event = fn title, attention -> %{title: title, date: ~D[2026-10-08], attention: attention} end
    entries = [event.("高", :high), event.("中", :mid), event.("低", :low)]

    comedy = Enum.find(Chidori.Topics.list(), &(&1.collection == "chidori_comedy"))
    tech = Enum.find(Chidori.Topics.list(), &(&1.collection == "chidori_events"))

    assert Enum.map(
             ChidoriWeb.HomeLive.upcoming(entries, Chidori.Topics.home_attention(comedy), today),
             & &1.title
           ) ==
             ["高", "中"]

    assert Enum.map(
             ChidoriWeb.HomeLive.upcoming(entries, Chidori.Topics.home_attention(tech), today),
             & &1.title
           ) ==
             ["高"]
  end

  test "技術書は、押すと詳細が開き、その本を勧めている記事をたどれる", %{conn: conn} do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)

    Chidori.HttpStub.stub(fn
      %{url: "http://chiezo.test:7010/v1/chidori_books/filter?" <> _} ->
        Chidori.HttpStub.ok(
          Jason.encode!(%{
            "results" => [
              %{
                "title" => "本:リーダブルコード",
                "tags" => ["技術書"],
                "opening" => "読みやすいコードの本。",
                "extra" => %{"docs" => 5}
              }
            ]
          })
        )

      %{url: "http://chiezo.test:7010/v1/chidori_book_posts/filter?" <> _} ->
        Chidori.HttpStub.ok(
          Jason.encode!(%{
            "results" => [
              %{
                "title" => "新人に勧めたい本",
                "extra" => %{"url" => "https://example.com/post", "published_at" => "2026-09-01"}
              }
            ]
          })
        )

      %{url: _other} ->
        Chidori.HttpStub.ok(~s({"results":[]}))
    end)

    Home.put(["books"])
    {:ok, live, _html} = live(conn, ~p"/")
    html = render_async(live, 2_000)

    # 見出しは出さない（札そのものが入口）
    refute html =~ "いま勧められている技術書"
    assert html =~ "の詳細を開く"

    live |> element(~s(li[phx-value-title="本:リーダブルコード"])) |> render_click()
    html = render_async(live, 2_000)

    # 技術書の画面と同じ詳細（モーダル）に開く。読んだ記録は最初から開いておく
    assert has_element?(live, ~s([role="dialog"] #book-detail-title), "リーダブルコード")
    assert has_element?(live, ~s(details.seen-mark[open] form#book-mark))
    assert html =~ ~s(href="https://example.com/post")

    live |> element(~s([role="dialog"] button[phx-click="close_book"])) |> render_click()
    refute has_element?(live, ~s([role="dialog"]))
  end

  test "技術書の詳細で読んだ記録を付けると、枠から外れ、総合の順位は繰り上がらない", %{conn: conn} do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)

    Chidori.HttpStub.stub(fn
      %{url: "http://chiezo.test:7010/v1/chidori_books/filter?" <> _} ->
        Chidori.HttpStub.ok(
          Jason.encode!(%{
            "results" => [
              %{"title" => "本:リーダブルコード", "tags" => ["技術書"], "extra" => %{"docs" => 5}},
              %{"title" => "本:達人プログラマー", "tags" => ["技術書"], "extra" => %{"docs" => 3}}
            ]
          })
        )

      %{url: _other} ->
        Chidori.HttpStub.ok(~s({"results":[]}))
    end)

    Home.put(["books"])
    {:ok, live, _html} = live(conn, ~p"/")
    render_async(live, 2_000)

    live |> element(~s(li[phx-value-title="本:リーダブルコード"])) |> render_click()

    html =
      live
      |> form("#book-mark", %{"read" => "on", "read_on" => "2026-10-01", "note" => "命名の章が効いた"})
      |> render_submit()

    mark = Chidori.Datasets.BookMarks.get("本:リーダブルコード")
    assert mark.read
    assert mark.read_on == ~D[2026-10-01]
    assert mark.note == "命名の章が効いた"
    assert html =~ "保存しました。"
    refute has_element?(live, ~s(li[phx-value-title="本:リーダブルコード"]))
    # 残った本の総合の順位は繰り上がらない
    assert html =~ ~r|達人プログラマー</span>\s*<span class="top-book-overall">（総合 2位）</span>|
  end

  test "埋め込んだ関連図は、取得の行と図だけ", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/relations?view=painters&embed=1")

    assert html =~ "最新の情報を取得"
    refute html =~ "<h1"
    refute html =~ "relation-guide"
  end

  test "知らない枠は保存しない", %{conn: _conn} do
    Home.put(["nosuch", "topic:chidori_news"])
    assert Home.selected_keys() == ["topic:chidori_news"]
  end

  test "並べられる枠は、要約を作る話題と関連図と技術書" do
    keys = Enum.map(Home.catalog(), & &1.key)

    assert "topic:chidori_news" in keys
    assert "topic:chidori_movies" in keys

    # 要約を作らずカレンダーを持つ話題（技術イベント）は注目イベントとして並べる
    refute "topic:chidori_events" in keys
    assert "events:chidori_events" in keys

    # 要約を別の収集から読む話題（市況ニュース）は、書き手ごとの要約として同じキーで並べる
    assert %{kind: :ai_digests} = Enum.find(Home.catalog(), &(&1.key == "topic:chidori_market"))
    assert "relations:painters" in keys
    assert "books" in keys
  end

  test "興味トピックの要約は、網を育てる話題のすぐ後ろに「〜興味ニュース」で並ぶ" do
    catalog = Home.catalog()
    keys = Enum.map(catalog, & &1.key)
    at = Enum.find_index(keys, &(&1 == "topic:chidori_tech"))

    assert Enum.at(keys, at + 1) == "interest:chidori_tech"
    assert Enum.find(catalog, &(&1.key == "interest:chidori_tech")).name == "技術興味ニュース"
    # 網を育てない話題（映画）には無い
    refute "interest:chidori_movies" in keys
    assert Home.interest_name("映画") == "映画（興味）"
  end

  test "枠の中を左右に払うと、決めた順で隣の枠へ移る（大きなタブをまたぐ。端より先へは回り込まない）",
       %{conn: conn} do
    Home.put(["books", "relations:painters"])
    {:ok, live, _html} = live(conn, ~p"/")

    render_hook(live, "panel_step", %{"by" => -1})
    refute_patched(live)

    render_hook(live, "panel_step", %{"by" => 1})
    assert_patch(live, "/?panel=books")

    render_hook(live, "panel_step", %{"by" => 1})
    refute_patched(live)
  end

  test "設定ページで選ぶのは出すかどうかだけ（並べ替えはしない）", %{conn: conn} do
    {:ok, live, html} = live(conn, ~p"/settings?tab=home")
    refute html =~ "data-drag-handle"
    # 大きなタブごとに見出しを立てて並べる
    assert html =~ ~s(id="home-group-news")

    render_submit(live, "save_home", %{
      "panels" => %{
        "books" => "true",
        "topic:chidori_news" => "true",
        "topic:chidori_tech" => "false"
      }
    })

    assert Home.selected_keys() == ["topic:chidori_news", "books"]
  end

  test "レシピの枠はレシピ集を出す（名簿の設定は出さない）", %{conn: conn} do
    Home.put(["recipes"])
    {:ok, _live, html} = live(conn, ~p"/")

    assert html =~ ~s(aria-label="レシピ")
    refute html =~ "名簿を引き直す"
  end

  describe "作品を育てる話題の要約の枠" do
    test "始まっている注目作（映画なら公開中）だけを、見出しつきで返す" do
      topic = Enum.find(Chidori.Topics.list(), &(&1[:works] == Chidori.News.Movies))
      today = Chidori.Jst.today()

      entries = [
        %{title: "公開中", date: Date.add(today, -3), attention: :high, tags: []},
        %{title: "これから", date: Date.add(today, 10), attention: :high, tags: []}
      ]

      assert {"公開中", [%{title: "公開中"}]} =
               ChidoriWeb.HomeLive.started_works({:ok, entries}, topic)

      assert ChidoriWeb.HomeLive.started_works(:loading, topic) == nil
    end

    test "見た作品は見た日の新しい順、日付の無いものは後ろに名前順。見ていない記録は入れない" do
      alias Chidori.Relations.Mark

      marks = %{
        "古い" => %Mark{node_name: "古い", seen: true, seen_on: ~D[2026-01-05]},
        "新しい" => %Mark{node_name: "新しい", seen: true, seen_on: ~D[2026-10-01]},
        "日付なしB" => %Mark{node_name: "日付なしB", seen: true},
        "日付なしA" => %Mark{node_name: "日付なしA", seen: true},
        "メモだけ" => %Mark{node_name: "メモだけ", seen: false, note: "気になる"}
      }

      assert Enum.map(ChidoriWeb.HomeLive.seen_works(marks), & &1.node_name) ==
               ["新しい", "古い", "日付なしA", "日付なしB"]

      assert ChidoriWeb.HomeLive.seen_works(nil) == []
    end
  end
end
