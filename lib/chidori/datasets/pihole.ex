defmodule Chidori.Datasets.Pihole do
  @moduledoc """
  **家の LAN の DNS で、Pi-hole が止めたドメインと気になる通信**を集めて調べるところ。

  **拾うのは機械、調べるのは AI。** 機械収集の回は Chiezo が Pi-hole から新しい問い合わせを
  読み、**止めたドメインといつもと違う振る舞いのドメインを、ドメインごとの集計として
  積み上げます**（最初と最後に見た時刻・問い合わせと止めた回数・アクセス元ごとの回数。
  Chiezo の巡回「Pi-hole から引く」）。接続先とパスワードは Chiezo の管理画面の
  API キーの面に置き、Chidori は Pi-hole に直接つながりません。整理の回は、
  **何のドメインか・放置してよいかを AI に web で調べさせます**。

  **集計は機械が持つので、AI に書かせません。** 足すだけの回は既にある 1 件の本文と
  タグに触らず、集計（脇書き）だけを入れ替えるので、調べた本文は残ります。
  **タグは最初の 1 回しか付かない**ので、いまの状態（止めているか・気になる通信か）は
  脇書きで読みます。
  """

  alias Chidori.Chiezo
  alias Chidori.SweepNames

  @collection "chidori_pihole"

  # 全文書に付いているタグ（Chiezo の Pi-hole から引く回が付ける）
  @kind_tag "Pi-hole"

  @blocked_tag "ブロック"
  @watch_tag "気になる通信"
  @reason_prefix "理由:"

  # AI が付ける判定のタグの頭と、選べる値（**この 3 つから選ばせる** —— 自由に書かせると
  # 一覧で揃わない）
  @verdict_prefix "判定:"
  @verdicts ["問題なし", "要注意", "不明"]

  # 機械収集の回の間隔。**新しい問い合わせだけを読んで足す**ので、細かく回しても
  # Pi-hole への負担は小さい（AI は呼ばない）
  @pick_minutes 60

  # 整理の 1 回に調べる数。**1 件ずつ web で調べる**ので、多く渡すと調べ切れずに
  # 浅い答えが並ぶ（Chiezo が数を決めて、AI には「載せたものを全部」と頼む）
  @tidy_per_run 10

  # どれから調べるか。**気になる通信を先に、止めたものは回数の多いほうから**
  # （Chiezo のソースが付ける重み）
  @tidy_order "priority"

  # いま止めている通信を 1 回に読む数と、画面に残す行数（500）
  @live_rows 500
  @live_keep 500

  # 一覧に読み込む上限（Chiezo の 1 回の上限 500 ずつ送る）
  @page 500
  @max_rows 5000

  # 「見た」印の置き場での名前（関連図の印と同じ置き場 `chidori_data` を、図の名前の代わりに
  # これで分けて使う。ノードの名前がドメイン）
  @mark_view "pihole"

  @doc "「見た」印の置き場での名前（`Chidori.Relations.Marks` の view）。"
  def mark_view, do: @mark_view

  @doc "全部の文書に付いている印。"
  def kind_tag, do: @kind_tag

  def blocked_tag, do: @blocked_tag
  def watch_tag, do: @watch_tag
  def verdicts, do: @verdicts

  @doc "溜め先の収集の名前（= Chiezo のソース名）。**後から変えない**。"
  def collection do
    case System.get_env("CHIDORI_PIHOLE_COLLECTION", "") |> String.trim() do
      "" -> @collection
      name -> name
    end
  end

  @doc "データ収集の画面に出す 1 タブぶん。"
  def definition do
    %{
      key: "pihole",
      name: "Pi-hole",
      module: __MODULE__,
      eyebrow: "WHAT YOUR HOME NETWORK IS TALKING TO",
      title: "Pi-hole の通信",
      description:
        "Pi-hole が止めたドメインと、いつもと違う振る舞いの通信を集めて、" <>
          "何のドメインか・放置してよいかを AI に調べさせます。",
      collection: collection(),
      reader: "見る人",
      unit: "ドメイン 1 つ 1 文書",
      note:
        "Pi-hole の記録は Chiezo の機械収集の回が読みます（接続先とパスワードは" <>
          " Chiezo の管理画面の API キーの面に「pihole」で登録する）。",
      # **溜まったドメインを一覧で出す**（設定より先に）
      listing: __MODULE__,
      survey_sweep: SweepNames.tidy(),
      partition_sweeps: []
    }
  end

  @doc "1 件ぶんに入る項目。"
  def fields do
    [
      %{field: "ドメイン", stored: "title", who: "Pi-hole（機械）"},
      %{
        field: "最初と最後に見た時刻",
        stored: "extra.first_seen / last_seen",
        who: "Pi-hole（機械。回るたびに積み上げる）"
      },
      %{field: "問い合わせ・止めた回数", stored: "extra.queries / blocked", who: "Pi-hole（機械。累計）"},
      %{
        field: "アクセス元ごとの回数",
        stored: "extra.clients / client_counts / client_names",
        who: "Pi-hole（機械。累計の多い順）"
      },
      %{field: "気になる通信の理由", stored: "extra.reasons / watched_at", who: "Pi-hole（機械。直近 24 時間で判定）"},
      %{field: "何のドメインか・放置してよいか", stored: "body", who: "AI（web で調べる）"},
      %{
        field: "判定",
        stored: "タグ「#{@verdict_prefix}…」",
        who: "AI（#{Enum.join(@verdicts, "・")} から 1 つ）"
      }
    ]
  end

  @doc "巡回 2 本。**拾うのは機械、調べるのは AI**。"
  def sweeps do
    [
      # **Chiezo が Pi-hole から引く回**（AI は呼ばない）。足すだけで、集計だけを入れ替える
      %{
        name: SweepNames.machine(),
        interval_minutes: @pick_minutes,
        use_pihole: true,
        only_new: true
      },
      # **機械収集が 1 回走るまで待つ**（有効にした直後に、空の収集を読ませない）
      %{
        name: SweepNames.tidy(),
        after: SweepNames.machine(),
        interval_minutes: SweepNames.tidy_minutes(),
        prompt: :research,
        unreviewed_per_run: @tidy_per_run,
        unreviewed_by: @tidy_order
      }
    ]
  end

  @doc """
  整理の回の依頼文。**まだ調べていないドメインだけ**を渡し（`{unreviewed}`）、
  1 件ずつ web で調べて本文に書かせます。見出しはもとにした単体のアプリ
  の「詳しく調べる」と同じで、利用者が「放置してよいか、
  止めるべきか」を判断できる形にしています。
  """
  def research_prompt do
    """
    家庭の LAN の Pi-hole が観測した DNS のドメインを溜めています。
    **まだ調べていないドメインについて、利用者が「放置してよいか、止めるべきか」を
    判断できるように調べてください。**

    次に並んでいるのは、まだ誰も調べていないドメインだけです（ここに載せたものは、
    調べられても調べられなくても次からは並びません）。本文には観測した事実
    （止めた回数・問い合わせの回数・最初と最後に見た時刻・候補に挙げた理由）が書いてあります。

    {unreviewed}

    1 件ずつ、web でそのドメインの運営元・用途・既知の評判を調べ、**観測した事実と
    合わせて**判断してください。

    - 「#{@blocked_tag}」のタグがあるものは Pi-hole が止めています。無いものは止めていないので、
      「ブロックされて当然」のような、止めたことを前提にした書き方はしないでください
    - 「#{@watch_tag}」のタグがあるものは、いつもと違う振る舞いとして機械が候補に挙げたものです。
      候補に挙げた理由（はじめて見た・存在しない名前が返り続ける・珍しい種別・規則正しい周期・
      毎回ちがう長い名前）を判断の材料にしてください

    body は次の見出しで、それぞれ 1〜3 文で書いてください（見出し以外の前置き・結びは書かない）。

    ■ ひとことでいうと（一覧に出すので 1〜2 文。何のドメインで、放置してよいか）
    ■ 何のドメインか（運営元と用途）
    ■ どの製品・アプリが使うか（観測した端末と矛盾しないか）
    ■ 通信の中身と頻度から言えること
    ■ 放置してよいか（止める場合の影響も）

    分からないことは推測せず「不明」と書いてください。

    tags には**今のタグをすべて残したうえで**、判定を 1 つだけ足してください:
    #{Enum.map_join(@verdicts, " / ", &"「#{@verdict_prefix}#{&1}」")}
    （放置してよいなら「#{@verdict_prefix}問題なし」、止めるか確かめたほうがよいなら
    「#{@verdict_prefix}要注意」、調べても分からなければ「#{@verdict_prefix}不明」）。
    **title は変えないでください**（ドメインそのものが重複の鍵です）。

    **触ったものだけ返してください。** 調べられなかったものは返さずに残してください。
    """
  end

  @doc "巡回ごとの依頼文（画面に出すため）。"
  def prompts, do: [{SweepNames.tidy(), research_prompt()}]

  @doc "Chiezo へ送る収集の設定ぜんぶ。"
  def attrs(choices \\ %{}) do
    %{
      name: collection(),
      description: "Chidori のデータ収集（Pi-hole が止めたドメインと気になる通信）",
      prompt: research_prompt(),
      interval_minutes: SweepNames.tidy_minutes(),
      # **名簿を引く指定は持たない**（前の版で送ったものを消す。残っていると、
      # 進み具合が空の 1 回目が名簿の回として走る）。**空のオブジェクトで外す** ——
      # Chiezo の更新は null を「触らない」と読む
      extract: %{},
      sweeps: with_choices(sweeps(), choices),
      # **網羅。** 一度調べたドメインは、また出てきたときに読み直さずに済むよう残す
      kind: "stock",
      requested_by: "chidori"
    }
  end

  defp with_choices(sweeps, choices) do
    for sweep <- Enum.map(sweeps, &resolve_prompt/1) do
      case Map.get(choices, sweep.name) do
        nil -> sweep
        picked -> Map.merge(sweep, Map.reject(picked, fn {_k, v} -> is_nil(v) end))
      end
    end
  end

  defp resolve_prompt(%{prompt: :research} = sweep), do: %{sweep | prompt: research_prompt()}
  defp resolve_prompt(sweep), do: sweep

  @doc """
  溜まっているドメインの一覧（**気になる通信を先に、止めた回数の多い順**）。
  本文は冒頭だけ（調べたものは「ひとことでいうと」が先頭に来る）。全文は `doc/2` で取ります。
  """
  def list(base) do
    fetch_pages(base, 0, [])
  end

  defp fetch_pages(base, offset, acc) do
    query =
      URI.encode_query(%{
        "tag" => @kind_tag,
        "fields" => "title,tags,opening,extra",
        "limit" => @page,
        "offset" => offset,
        # **まだ調べていないものも並べる**（Chiezo は既定で外す）。一緒に入ってくる
        # 消えたものはこちらで落とす
        "include_removed" => "true"
      })

    case Chiezo.get(base <> "/v1/" <> collection() <> "/filter?" <> query) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"results" => results}} when is_list(results) ->
            living = Enum.reject(results, &(Chiezo.removed_tag() in List.wrap(&1["tags"])))
            acc = acc ++ Enum.map(living, &to_domain/1)

            if length(results) == @page and offset + @page < @max_rows,
              do: fetch_pages(base, offset + @page, acc),
              else: {:ok, sorted(acc)}

          _other ->
            {:error, :chiezo_unexpected_body}
        end

      # まだ 1 度も焼いていない収集
      {:ok, %{status: 404}} ->
        {:ok, []}

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  defp sorted(domains),
    do: Enum.sort_by(domains, &{!&1.watch, -&1.priority, -&1.blocked_count, &1.domain})

  @doc "1 件ぶんの本文（調べた中身の全文）。"
  def doc(base, domain) do
    query =
      URI.encode_query(%{
        "title" => domain,
        "fields" => "title,body",
        "max_chars" => 8000,
        # まだ調べていないものも開ける（観測した事実だけの本文）
        "include_removed" => "true"
      })

    case Chiezo.get(base <> "/v1/" <> collection() <> "/doc?" <> query) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"body" => text}} when is_binary(text) -> {:ok, text}
          {:ok, _other} -> {:ok, ""}
          _error -> {:error, :chiezo_unexpected_body}
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  @doc """
  **いま止めている通信**（Chiezo の `GET /v1/pihole/blocked`）。`since`（unix 秒）より後に
  止めたものを古い順に 1 件 1 行で返します。鍵は Chiezo が持つので、Chidori は Pi-hole に
  直接つながりません。返すのは `{:ok, %{rows: [...], cursor: 次に渡す since}}`。
  """
  def blocked_since(base, since) do
    query = URI.encode_query(%{"since" => since, "limit" => @live_rows})

    case Chiezo.get(base <> "/v1/pihole/blocked?" <> query) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"queries" => rows, "cursor" => cursor}} when is_list(rows) ->
            {:ok, %{rows: Enum.map(rows, &to_live/1), cursor: cursor}}

          _other ->
            {:error, :chiezo_unexpected_body}
        end

      # 接続先が登録されていない（Chiezo の API キーの面）
      {:ok, %{status: 409}} ->
        {:error, :pihole_not_configured}

      {:ok, %{status: 502}} ->
        {:error, :pihole_unavailable}

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  defp to_live(row) do
    %{
      id: row["id"],
      at: row["at"],
      domain: to_string(row["domain"] || ""),
      client: to_string(row["client"] || ""),
      client_name: if(row["client_name"] in [nil, ""], do: nil, else: row["client_name"]),
      status: to_string(row["status"] || "")
    }
  end

  @doc "流し見で手元に残す行数（古いものから落とす）。"
  def live_keep, do: @live_keep

  @doc false
  def to_domain(result) do
    tags = Enum.filter(List.wrap(result["tags"]), &is_binary/1)
    extra = if is_map(result["extra"]), do: result["extra"], else: %{}

    # **いまの状態は脇書きで読む**（タグは最初の 1 回にしか付かない）
    %{
      domain: to_string(result["title"] || ""),
      blocked: int(extra["blocked"]) > 0 or @blocked_tag in tags,
      watch: is_binary(extra["watched_at"]) or @watch_tag in tags,
      # 一覧の札は理由の種類（タグ）、詳細は観測した事実（脇書き）
      reasons: for(@reason_prefix <> reason <- tags, do: reason),
      observed: Enum.filter(List.wrap(extra["reasons"]), &is_binary/1),
      verdict: Enum.find_value(tags, fn tag -> verdict_of(tag) end),
      # **まだ AI が目を通していない**（Chiezo の印）。調べたかどうかはこれで分かる
      researched: Chiezo.unreviewed_tag() not in tags,
      summary: summary(to_string(result["opening"] || "")),
      blocked_count: int(extra["blocked"]),
      queries: int(extra["queries"]),
      first_seen: extra["first_seen"],
      last_seen: extra["last_seen"],
      watched_at: extra["watched_at"],
      clients: clients(extra),
      priority: int(extra["priority"])
    }
  end

  # アクセス元ごとの回数（並べて持っている 3 本の並びを 1 つにする）
  defp clients(extra) do
    ips = List.wrap(extra["clients"])
    counts = List.wrap(extra["client_counts"])
    names = List.wrap(extra["client_names"]) ++ List.duplicate("", length(ips))

    for {{ip, count}, name} <- Enum.zip(Enum.zip(ips, counts), names), is_binary(ip) do
      %{ip: ip, name: if(is_binary(name) and name != "", do: name), count: int(count)}
    end
  end

  defp verdict_of(@verdict_prefix <> verdict) when verdict in @verdicts, do: verdict
  defp verdict_of(_tag), do: nil

  # 調べたものは「■ ひとことでいうと」の段だけを一覧に出す
  defp summary(text) do
    case Regex.run(~r/■\s*ひとことでいうと[^\n]*\n(.+?)(?=\n■|\z)/s, text) do
      [_, line] -> String.trim(line)
      nil -> String.trim(text)
    end
  end

  defp int(n) when is_integer(n), do: n
  defp int(n) when is_float(n), do: round(n)
  defp int(_n), do: 0
end
