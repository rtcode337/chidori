defmodule ChidoriWeb.DatasetsGourmetLiveTest do
  @moduledoc """
  データ収集の「ご当地グルメ」のタブ。区画が県なので、区画の地図の代わりに県の地図と県ごとの数を
  並べ、地図の県か表の「選ぶ」で県を選んで 1 回頼める。溜まったもの（料理の名前）は出さない。
  """

  use ChidoriWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @base "http://chiezo.test:7010"

  @collection %{
    "name" => "chidori_gourmet",
    "description" => "Chidori のデータ収集（ご当地グルメ / travel-log 向け）",
    "enabled" => false,
    "interval_minutes" => 720,
    "kind" => "stock",
    "partitions_total" => 2,
    "partitions" => [
      %{"key" => "地域:東京都", "count" => 2, "visits" => %{"情報収集" => "2026-10-01T00:00:00Z"}},
      %{"key" => "地域:神奈川県", "count" => 0, "visits" => %{}}
    ],
    "sweeps" => [
      %{"name" => "機械収集", "interval_minutes" => 10_080, "use_extract" => true},
      %{"name" => "情報収集", "interval_minutes" => 720, "partitions_per_run" => 1},
      %{"name" => "整理", "interval_minutes" => 720, "partitions_per_run" => 1}
    ]
  }

  @docs [
    %{
      "doc_id" => 1,
      "title" => "東京のうどん（秘密の名前）",
      "tags" => ["ご当地グルメ", "地域:東京都"],
      "extra" => %{"lat" => 35.68, "lon" => 139.76}
    },
    %{
      "doc_id" => 2,
      "title" => "東京の菓子（秘密の名前）",
      "tags" => ["ご当地グルメ", "地域:東京都", "_chiezo_unreviewed"],
      "extra" => %{}
    }
  ]

  setup do
    System.put_env("CHIEZO_BASE_URL", @base)
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
    test_pid = self()

    Chidori.HttpStub.stub(fn
      %{method: :get, url: @base <> "/v1/collect"} ->
        Chidori.HttpStub.ok(Jason.encode!(%{"collections" => [@collection]}))

      %{method: :get, url: @base <> "/v1/collect/chidori_gourmet/unresolved" <> _} ->
        Chidori.HttpStub.ok(
          Jason.encode!(%{"total" => 1, "unresolved" => [%{"title" => "東京の菓子（秘密の名前）"}]})
        )

      %{method: :get, url: @base <> "/v1/collect/chidori_gourmet" <> _} ->
        Chidori.HttpStub.ok(Jason.encode!(@collection))

      %{method: :get, url: @base <> "/v1/chidori_gourmet/filter?" <> _} ->
        Chidori.HttpStub.ok(Jason.encode!(%{"total" => length(@docs), "results" => @docs}))

      %{method: :get, url: @base <> "/v1/collect/changes" <> _} ->
        Chidori.HttpStub.ok(Jason.encode!(%{"changes" => []}))

      %{method: :post, url: url, body: body} ->
        send(test_pid, {:posted, url, Jason.decode!(body)})
        Chidori.HttpStub.ok(~s({}))

      %{method: :get} ->
        Chidori.HttpStub.ok(Jason.encode!(%{"backends" => [], "sources" => []}))
    end)

    :ok
  end

  test "県ごとに料理・代表店あり・代表店まだ・代表店なしを出し、料理の名前は出さない", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/datasets?view=gourmet")
    html = render_async(live)

    assert html =~ "県ごとの進み具合"

    assert html =~
             "料理 2 品・代表店が決まって地図に置ける 1 品・代表店まだ 1 品（うち引き当てできず 1 品）・代表店なし 0 品"

    # 県の並びは東京都から（区画の 1 周目の順）
    [_, table] = String.split(html, "prefecture-table", parts: 2)

    assert table =~
             ~r/<td>東京都<\/td>\s*<td>2<\/td>\s*<td>1<\/td>\s*<td>\s*1<span[^>]*>（うち引き当てできず 1）<\/span>\s*<\/td>\s*<td>0<\/td>/

    # 「AI が見たか」の列は出さない（代表店がまだでも 0 になり紛らわしい）
    refute table =~ "未確認"
    assert String.split(table, "<td>東京都</td>") |> hd() |> String.contains?("<td>") == false

    # 溜まったものそのものは見せない（読むのは travel-log）
    refute html =~ "秘密の名前"
    # 区画の地図は出さない（鍵が矩形ではない）
    refute html =~ "partition-map"
    # travel-log 用の ZIP は出す
    assert html =~ "/datasets/gourmet/travel-log.zip"
  end

  test "県を選ぶと、その県を選んだ巡回で 1 回走らせられる（押しただけでは走らない）", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/datasets?view=gourmet")
    render_async(live)

    html =
      live
      |> element(~s|button[phx-click="pick_partition"][phx-value-key="地域:東京都"]|)
      |> render_click()

    refute_received {:posted, _url, _body}
    assert html =~ "選んだ区画"
    assert html =~ "この区画で 1 回走らせる"
    assert html =~ ~s(<option value="情報収集")
    assert html =~ ~s(<option value="整理")

    live
    |> form(~s|form[phx-submit="run_partition"]|, %{"sweep" => "情報収集"})
    |> render_submit()

    render_async(live)
    assert_receive {:posted, url, body}, 2_000
    assert url =~ "/v1/collect/chidori_gourmet/run"
    assert url =~ "manual=true"
    assert url =~ URI.encode_query(%{"sweep" => "情報収集"})
    assert body["partitions"] == ["地域:東京都"]
  end

  test "県の地図を出し、塗りの段と引き当てできずの印と凡例を添える", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/datasets?view=gourmet")
    html = render_async(live)

    assert html =~ ~s(id="prefecture-canvas")
    assert html =~ ~s(phx-hook="PrefectureMap")
    # 47 県ぶんの県の形（押す口）
    assert length(Regex.scan(~r/<path[^>]*class="pref /, html)) == 47

    # 東京都は料理 2・代表店あり 1（50 %）で 3 段目、引き当てできずがあるので印が 1 つ
    assert html =~ ~r/class="pref pref-step-3"[^>]*phx-value-key="地域:東京都"/
    assert length(Regex.scan(~r/<circle[^>]*data-flag/, html)) == 1
    # 料理の無い県は「料理がまだ無い」の色
    assert html =~ ~r/class="pref pref-empty"[^>]*phx-value-key="地域:北海道"/
    # 色だけに頼らない（県名と数が読める）
    assert html =~ "東京都：料理 2・代表店あり 1（50 %）・代表店まだ 1（うち引き当てできず 1）・代表店なし 0"
    assert html =~ "代表店ありの割合（料理のうち）"
    assert html =~ "引き当てできずがある"
    assert html =~ "Natural Earth"
    # 料理の名前は地図にも出さない
    refute html =~ "秘密の名前"
  end

  test "地図の県を押すと選ばれ、フォームがその県になる（押しただけでは走らない）", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/datasets?view=gourmet")
    render_async(live)

    html =
      live
      |> element(~s|path.pref[phx-value-key="地域:東京都"]|)
      |> render_click()

    refute_received {:posted, _url, _body}
    assert html =~ "選んだ区画"
    assert html =~ "この区画で 1 回走らせる"
    assert html =~ ~s(<input type="hidden" name="key" value="地域:東京都")
    # 選んだ県の数
    [_, picked] = String.split(html, "選んだ区画", parts: 2)
    assert picked =~ ~r/<dt>料理<\/dt>\s*<dd>2 品<\/dd>/
    assert picked =~ ~r/<dt>代表店あり<\/dt>\s*<dd>1 品<\/dd>/
    # 地図の上でも選んだ県が分かる（表の行と同じ状態）
    assert html =~ ~r/class="pref-picked"[^>]*phx-value-key="地域:東京都"/
    assert html =~ ~r/<tr class="is-picked">\s*<td>東京都<\/td>/

    # もう一度押すと選びやめる
    html =
      live
      |> element(~s|path.pref-picked[phx-value-key="地域:東京都"]|)
      |> render_click()

    refute html =~ "この区画で 1 回走らせる"
    refute_received {:posted, _url, _body}
  end

  test "区画がまだ無い県を地図で押しても、フォームは出さずにそう言う", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/datasets?view=gourmet")
    render_async(live)

    html =
      live
      |> element(~s|path.pref[phx-value-key="地域:沖縄県"]|)
      |> render_click()

    refute html =~ "この区画で 1 回走らせる"
    assert html =~ "沖縄県はまだ区画がありません"
    refute_received {:posted, _url, _body}
  end

  test "依頼文と、引き当て・書式の指定が読める", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/datasets?view=gourmet")
    html = render_async(live)

    assert html =~ "辞典への引き当てと書式"
    assert html =~ "osm_japan"
    assert html =~ "available_months"
    assert html =~ "県の名前が付いた"
  end
end
