defmodule Tazuna.Datasets.Pihole do
  @moduledoc """
  **家の LAN の DNS で、Pi-hole が止めたドメインと気になる通信**を集めて調べるところ。

  **拾うのは機械、調べるのは AI。** Pi-hole から記録を引くのは Chiezo の取り込み
  （ソース `pihole`。接続先とパスワードは Chiezo の管理画面の API キーの面に置く）で、
  止めたドメインと「いつもと違う振る舞い」のドメインを 1 ドメイン 1 文書で焼いてくれます。
  ここではそれを名簿として引き（機械収集）、**何のドメインか・放置してよいかを
  AI に web で調べさせます**（整理）。観測した事実（回数・端末・候補に挙げた理由）は
  機械が持つので、AI に書かせません。

  **名簿は足すだけ**（`only_new`）。調べた中身は AI が本文に書くので、名簿を引き直した
  回に元の観測の文で上書きされないように。回数のような脇書きは、引き直すたびに
  最新の値へ入れ替わります（Chiezo が機械の運んだ値で入れ替える）。
  """

  alias Tazuna.Chiezo
  alias Tazuna.SweepNames

  @collection "tazuna_pihole"

  # 引く先（Chiezo の取り込みのソース）と、その全文書に付いているタグ
  @source "pihole"
  @kind_tag "Pi-hole"

  @blocked_tag "ブロック"
  @watch_tag "気になる通信"
  @reason_prefix "理由:"

  # AI が付ける判定のタグの頭と、選べる値（**この 3 つから選ばせる** —— 自由に書かせると
  # 一覧で揃わない）
  @verdict_prefix "判定:"
  @verdicts ["問題なし", "要注意", "不明"]

  # 運ぶ脇書き（観測した事実）。`priority` は調べる順の鍵。**Chiezo が 1 本の指定で
  # 運べるのは 10 個まで**なので、窓の長さのような決まった値（30 日・24 時間）は運ばない
  @extra ~w(blocked_count queries queries_blocked first_query_at last_query_at
            clients reasons reason_kinds priority)

  # 名簿の回の間隔。**Chiezo の取り込み（Pi-hole の記録）は日に 1 回焼く**ので、
  # それより細かく引いても同じものが返るだけ
  @pick_minutes 1440

  # 整理の 1 回に調べる数。**1 件ずつ web で調べる**ので、多く渡すと調べ切れずに
  # 浅い答えが並ぶ（Chiezo が数を決めて、AI には「載せたものを全部」と頼む）
  @tidy_per_run 10

  # どれから調べるか。**気になる通信を先に、止めたものは回数の多いほうから**
  # （Chiezo のソースが付ける重み）
  @tidy_order "priority"

  # 一覧に読み込む上限（Chiezo の 1 回の上限 500 ずつ送る）
  @page 500
  @max_rows 5000

  @doc "全部の文書に付いている印。"
  def kind_tag, do: @kind_tag

  def blocked_tag, do: @blocked_tag
  def watch_tag, do: @watch_tag
  def verdicts, do: @verdicts

  @doc "溜め先の収集の名前（= Chiezo のソース名）。**後から変えない**。"
  def collection do
    case System.get_env("TAZUNA_PIHOLE_COLLECTION", "") |> String.trim() do
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
        "Pi-hole の記録は Chiezo が取り込みます（ソース「#{@source}」。接続先とパスワードは" <>
          " Chiezo の管理画面の API キーの面で登録し、定期再構築を 1 日おきにしておく）。",
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
      %{field: "止めた・気になる通信か", stored: "タグ「#{@blocked_tag}」「#{@watch_tag}」", who: "Pi-hole（機械）"},
      %{field: "候補に挙げた理由", stored: "タグ「#{@reason_prefix}…」・extra.reasons", who: "Pi-hole（機械）"},
      %{
        field: "回数・端末",
        stored: "extra.blocked_count / queries / clients",
        who: "Pi-hole（機械。引き直すたびに最新へ）"
      },
      %{field: "何のドメインか・放置してよいか", stored: "body", who: "AI（web で調べる）"},
      %{
        field: "判定",
        stored: "タグ「#{@verdict_prefix}…」",
        who: "AI（#{Enum.join(@verdicts, "・")} から 1 つ）"
      }
    ]
  end

  @doc """
  名簿の指定。Chiezo のソース `#{@source}` の全部を引き、タグと観測の脇書きを運びます。
  """
  def extract do
    [
      %{
        source: @source,
        tag: @kind_tag,
        # 本文は**最初の 1 回だけ**入る（足すだけの回なので、調べた後は AI の本文が残る）
        body: "opening",
        extra: @extra,
        tags: [
          %{const: @kind_tag},
          %{pattern: "^(#{@blocked_tag}|#{@watch_tag})$", format: "{1}"},
          %{pattern: "^#{@reason_prefix}(.+)$", format: "#{@reason_prefix}{1}"}
        ]
      }
    ]
  end

  @doc "巡回 2 本。**拾うのは機械、調べるのは AI**。"
  def sweeps do
    [
      %{
        name: SweepNames.machine(),
        interval_minutes: @pick_minutes,
        use_extract: true,
        only_new: true
      },
      # **機械収集が 1 回走るまで待つ**（有効にした直後に、空の収集を読ませない）
      %{
        name: SweepNames.tidy(),
        after: SweepNames.machine(),
        interval_minutes: SweepNames.tidy_minutes(),
        web: true,
        prompt: :research,
        unreviewed_per_run: @tidy_per_run,
        unreviewed_by: @tidy_order
      }
    ]
  end

  @doc """
  整理の回の依頼文。**まだ調べていないドメインだけ**を渡し（`{unreviewed}`）、
  1 件ずつ web で調べて本文に書かせます。見出しはもとにした単体のアプリ
  （Pi-hole の監視アプリ）の「詳しく調べる」と同じで、利用者が「放置してよいか、
  止めるべきか」を判断できる形にしています。
  """
  def research_prompt do
    """
    家庭の LAN の Pi-hole が観測した DNS のドメインを溜めています。
    **まだ調べていないドメインについて、利用者が「放置してよいか、止めるべきか」を
    判断できるように調べてください。**

    次に並んでいるのは、まだ誰も調べていないドメインだけです（ここに載せたものは、
    調べられても調べられなくても次からは並びません）。本文には観測した事実
    （止めた回数・問い合わせの回数・引いた端末・候補に挙げた理由）が書いてあります。

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
      description: "tazuna のデータ収集（Pi-hole が止めたドメインと気になる通信）",
      prompt: research_prompt(),
      interval_minutes: SweepNames.tidy_minutes(),
      extract: extract(),
      sweeps: with_choices(sweeps(), choices),
      # **網羅。** 一度調べたドメインは、また出てきたときに読み直さずに済むよう残す
      kind: "stock",
      requested_by: "tazuna"
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

  @doc false
  def to_domain(result) do
    tags = Enum.filter(List.wrap(result["tags"]), &is_binary/1)
    extra = if is_map(result["extra"]), do: result["extra"], else: %{}

    %{
      domain: to_string(result["title"] || ""),
      blocked: @blocked_tag in tags,
      watch: @watch_tag in tags,
      reasons: for("#{@reason_prefix}" <> reason <- tags, do: reason),
      verdict: Enum.find_value(tags, fn tag -> verdict_of(tag) end),
      # **まだ AI が目を通していない**（Chiezo の印）。調べたかどうかはこれで分かる
      researched: Chiezo.unreviewed_tag() not in tags,
      summary: summary(to_string(result["opening"] || "")),
      blocked_count: int(extra["blocked_count"]),
      queries: int(extra["queries"]),
      clients: Enum.filter(List.wrap(extra["clients"]), &is_binary/1),
      observed: Enum.filter(List.wrap(extra["reasons"]), &is_binary/1),
      last_query_at: extra["last_query_at"],
      priority: int(extra["priority"])
    }
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
