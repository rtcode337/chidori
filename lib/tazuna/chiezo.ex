defmodule Tazuna.Chiezo do
  @moduledoc """
  Chiezo とのやり取りのうち、**どの話題でも同じ部分**をまとめたところです。

  収集の定義を読む、依頼する、走らせる —— どれもニュースでも関連図でも同じ形なので、
  ここに 1 つだけ置きます。2 か所に分かれると、片方だけ直す事故が起きます。

  **話題ごとに違うもの**（何を集めるかの指示文、溜まったものをどう見せるか）は
  呼ぶ側が持ちます。
  """

  alias Tazuna.Http

  @user_agent "tazuna"
  @timeout 15_000
  @connect_timeout 5_000
  # 1 回に引ける上限（Chiezo 側の決まり。これより大きいと 422 で断られる）
  @page_limit 500
  # 取り込みが空くのを待つあいだ、確かめ直す間隔
  @busy_poll_ms 60_000
  # 地名を引く辞典と、候補の数
  @place_source "osm_japan"
  @place_limit 8

  @doc """
  Chiezo のルートURL。未設定ならこの機能は使えません。
  """
  def base_url do
    case System.get_env("CHIEZO_BASE_URL") do
      nil -> nil
      "" -> nil
      value -> value |> String.trim() |> String.trim_trailing("/")
    end
  end

  @doc """
  墓標のタグ。**これを付けて返した 1 件は、消えた扱いになります**。

  Chiezo が決めている名前なので、**tazuna 側では 1 か所だけで持ちます** ——
  依頼文はニュースにも関連図にもあり、どちらにも書き写すと、片方だけ直したときに
  そちらの回だけ黙って消せなくなります（返した墓標がただのタグとして溜まる）。

  頭の `_` は「機械が意味を持たせる印」の目印で、Chiezo 側が付けています。
  """
  def tombstone_tag, do: "_chiezo_tombstone"

  @doc """
  消えたものの印。**読み口は既定でこれを外します**が、未レビューのものも一緒に
  外れるので、未レビューを見たい読み手は `include_removed` で両方を受け取り、
  こちらで消えたものだけを落とします。
  """
  def removed_tag, do: "_chiezo_removed"

  @doc """
  消えたものを戻す印。**戻るのは AI がこの印を付けて返したときだけ**です
  （消えた印を外して返しても戻りません）。頼む指示文から名指しするために置きます。
  """
  def restore_tag, do: "_chiezo_restore"

  @doc "AI がまだ目を通していないものの印（機械で入ったばかりのもの）。"
  def unreviewed_tag, do: "_chiezo_unreviewed"

  @doc """
  人が確かめた座標を持つ 1 件の印（Chiezo の `LOCKED_TAG`）。**座標は焼くたびに
  確かめた値へ戻る**ので、AI に「この印の店の座標は直さない」と頼める。
  """
  def locked_tag, do: "座標確認済み"

  @doc "Chiezo の画面へのリンク。相対パスをルートURLに繋ぐだけです。"
  def url(path) when is_binary(path) do
    case base_url() do
      nil -> nil
      base -> base <> path
    end
  end

  def url(_path), do: nil

  @doc """
  収集の状態を読みます。**まだ依頼していなければ `nil`**（失敗ではない）。

  一覧を先に見るのは、404 の意味を切り分けるためです —— 収集の口が無い Chiezo と、
  まだ依頼していないだけの状態は、1 件の口だけでは同じ 404 に見えます。
  """
  def collection(base, name, samples \\ 0) do
    with {:ok, collections} <- list(base) do
      case Enum.find(collections, &(&1["name"] == name)) do
        nil -> {:ok, nil}
        found -> detail(base, name, found, samples)
      end
    end
  end

  @doc """
  溜まった 1 件。**見出しで引きます**（Chiezo の中で 1 件を指す鍵は見出しです）。

  `fields` で欲しい欄を頼みます —— `"title,body"` なら本文、`"title,extra"` なら
  原文の URL や絵。**一覧に付いてくる要約は冒頭だけ**（実測で 240 文字）なので、
  通しで読ませるものはここから取り直します。

  無い見出しは 404 です（誤りではなく「持っていない」）。
  """
  def doc(base, source, title, fields \\ "title,body")
      when is_binary(source) and is_binary(title) do
    query = URI.encode_query(%{"fields" => fields, "title" => title})

    case get(base <> "/v1/" <> source <> "/doc?" <> query) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"title" => _title} = doc} -> {:ok, doc}
          _other -> {:error, :chiezo_unexpected_body}
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
  溜まったもののうち、**目印のタグを持つ 1 ページ**。書き出し（travel-log 用の ZIP）で使います。

  **座標の矩形（世界全体）では引きません。** 矩形は収集の全文書（数十万件）を座標の表から
  拾い直すので、1 ページごとに 4 秒ほどかかっていた（6,000 件で 13 ページ = 1 分近く）。
  目印のタグなら索引の中で済み、同じ件数で 1 ページ 1 秒ほどになる。
  座標を持たないものは呼ぶ側で落とします。

  **返るのは AI が目を通したものだけ**です（Chiezo の読み口が、まだ目を通していない
  ものと消したものを既定で外します）。機械で入れたばかりのものには宣伝も的外れも
  混ざるので、地図に並べる前の関門がここになります。

  1 回の上限は Chiezo 側で 500 件なので、呼ぶ側が `offset` を進めます。

  `include_removed: true` で、外されていたもの（消えたもの・未レビューのもの）も
  受け取ります。**目印に消えたものの印を渡して使います** —— 収集の目印で引くと
  未レビューまで返り、件数が桁違いに増える（食事処で 2.8 万件 → 59.7 万件）。
  """
  def spot_docs(base, name, tag, offset \\ 0, limit \\ @page_limit, opts \\ [])
      when is_binary(name) and is_binary(tag) and is_integer(offset) do
    query =
      %{
        "tag" => tag,
        "limit" => limit,
        "offset" => offset,
        # **本文は名指ししたときだけ**（冒頭は 240 字で切れているので、全文が要る画面がある）
        "fields" =>
          if(opts[:body],
            do: "doc_id,title,tags,extra,opening,body",
            else: "doc_id,title,tags,extra,opening"
          )
      }
      |> then(fn q ->
        if opts[:include_removed], do: Map.put(q, "include_removed", "true"), else: q
      end)
      |> URI.encode_query()

    case get(base <> "/v1/" <> URI.encode(name) <> "/filter?" <> query) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"results" => results} = decoded} when is_list(results) ->
            {:ok, %{total: decoded["total"] || length(results), docs: results}}

          _other ->
            {:error, :chiezo_unexpected_body}
        end

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  @doc """
  四角（`[南, 西, 北, 東]`）の中で、そのタグを持つ文書の数。`{:ok, 数}` か `{:error, 理由}`。
  **1 件も読まずに数だけ**（範囲を描きながら、広すぎないかをその場で確かめるため）。
  """
  def count_in(base, source, tag, [_s, _w, _n, _e] = box) do
    query =
      URI.encode_query(%{
        "tag" => tag,
        "bbox" => Enum.join(box, ","),
        "limit" => 1,
        "fields" => "title"
      })

    case get(base <> "/v1/" <> URI.encode(source) <> "/filter?" <> query) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"total" => total}} when is_integer(total) -> {:ok, total}
          _other -> {:error, :chiezo_unexpected_body}
        end

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  @doc """
  巡回 1 本の**間隔だけ**を変えます（`PATCH /v1/collect/{name}/sweeps/{sweep}`）。
  **相手や依頼文には触りません** —— 巡回を並びごと送り直すと、画面で選んだ相手まで
  送り直すことになる。**一周の日数も同じ比で伸ばしてもらいます**（`keep_per_run`）。
  1 回に見る区画の数は一周の日数から逆算されるので、間隔だけでは使う枠が変わらない。
  """
  def set_sweep_clock(base, name, sweep, minutes) do
    patch_sweep(base, name, sweep, %{interval_minutes: minutes, keep_per_run: true})
  end

  @doc """
  巡回 1 本の**時計を外す / 戻す**（`by_caller`。同じ口）。外した巡回は Chiezo の
  時計では走らず、名指しの 1 回（`run/3` の `sweep`）や割り込みの行き先としては
  今までどおり走る。AI の枠を節約したい収集の整理を止めるのに使う
  （`Tazuna.CollectPace.stop_tidy/3`）。
  """
  def set_sweep_by_caller(base, name, sweep, on) when is_boolean(on) do
    patch_sweep(base, name, sweep, %{by_caller: on})
  end

  @doc """
  巡回 1 本の**頼む相手だけ**を選び直します（依頼文も時計も触らない）。
  `backend` は相手の一覧の id（ワーカーは `worker:<id>`）。空なら収集の既定へ戻す。
  """
  def set_sweep_backend(base, name, sweep, backend, model) do
    patch_sweep(base, name, sweep, %{backend: backend || "", model: model})
  end

  defp patch_sweep(base, name, sweep, attrs) do
    body = Jason.encode!(attrs)

    url =
      base <>
        "/v1/collect/" <>
        URI.encode(name) <> "/sweeps/" <> URI.encode(sweep, &URI.char_unreserved?/1)

    case Http.patch(url, body,
           headers: [{"user-agent", @user_agent}],
           content_type: "application/json",
           timeout: @timeout,
           connect_timeout: @connect_timeout
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: raw}} -> {:error, {:chiezo_refused, status, reason_of(raw)}}
      {:error, _reason} -> {:error, :chiezo_unavailable}
    end
  end

  @doc """
  ある点のまわり（`meters` 四方）の文書。`{:ok, [文書]}` か `{:error, 理由}`。

  **消えたものも、まだ AI が見ていないものも返します**（`include_removed`）——
  読み口の既定では両方外れるが、近くに何が残っているかを探す側は、見られて
  いないものこそ知りたい。消えたものを落とすのは呼ぶ側です。
  """
  def nearby(base, name, lat, lon, meters) when is_number(lat) and is_number(lon) do
    dlat = meters / 111_320
    dlon = meters / (111_320 * max(:math.cos(lat * :math.pi() / 180), 0.01))
    bbox = Enum.join([lat - dlat, lon - dlon, lat + dlat, lon + dlon], ",")
    nearby_pages(base, name, bbox, 0, [])
  end

  # total に届くまでページを送る。1 ページで打ち切ると、駅前のように店が密集した
  # 場所では近くの店が上限の外にこぼれ、そこにある店を「無い」と取り違える
  # （並びは名前順なので、こぼれるのは名前の後ろのほう）。
  @nearby_page 200
  defp nearby_pages(base, name, bbox, offset, acc) do
    query =
      URI.encode_query(%{
        "bbox" => bbox,
        "limit" => @nearby_page,
        "offset" => offset,
        # 冒頭（`opening`）も読む —— 呼ぶ側が本文の頭で見分けられるように
        "fields" => "title,tags,extra,opening",
        "include_removed" => "true"
      })

    case get(base <> "/v1/" <> URI.encode(name) <> "/filter?" <> query) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"results" => results} = page} when is_list(results) ->
            acc = acc ++ results
            total = page["total"]

            if results != [] and is_integer(total) and length(acc) < total,
              do: nearby_pages(base, name, bbox, offset + length(results), acc),
              else: {:ok, acc}

          _other ->
            {:error, :chiezo_unexpected_body}
        end

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  @doc """
  1 件の座標を固定します（`POST /v1/collect/{name}/locks`）。**次に焼くときから効き**、
  AI の回が動かしても名簿を引き直しても、その座標に戻ります。
  """
  def lock(base, name, title, lat, lon) do
    body = Jason.encode!(%{title: title, lat: lat, lon: lon})

    case post(base <> "/v1/collect/" <> URI.encode(name) <> "/locks", body) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: raw}} -> {:error, {:chiezo_refused, status, reason_of(raw)}}
      {:error, _reason} -> {:error, :chiezo_unavailable}
    end
  end

  @doc """
  収集の 1 件が持つ URL を、Chiezo が開いて確かめた結果（`GET /v1/collect/{name}/links`）。
  `{:ok, URL → %{"status", "final_url", "title"}}`。**まだ確かめていない URL は入りません**。
  口を持たない Chiezo・読めないときは `{:error, 理由}`（呼ぶ側は空として扱う）。
  """
  def link_checks(base, name) do
    case get(base <> "/v1/collect/" <> URI.encode(name) <> "/links") do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"links" => links}} when is_map(links) -> {:ok, links}
          _other -> {:error, :chiezo_unexpected_body}
        end

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  @doc """
  1 件の座標の固定を外します（`POST /v1/collect/{name}/locks` に緯度・経度を書かない）。
  **次に焼くときから効き**、その 1 件はまた AI の回で消せるようになります。
  """
  def unlock(base, name, title) do
    body = Jason.encode!(%{title: title})

    case post(base <> "/v1/collect/" <> URI.encode(name) <> "/locks", body) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: raw}} -> {:error, {:chiezo_refused, status, reason_of(raw)}}
      {:error, _reason} -> {:error, :chiezo_unavailable}
    end
  end

  @doc """
  収集を依頼します。**作られるのは止まった状態**なので、これで AI が動き出すことは
  ありません。すでにあれば何もしません（409 は成功として扱う）。
  """
  def request(base, attrs) do
    # 整理を自動で回さないと決めた収集は、作るときから時計を外して送る
    attrs = Tazuna.CollectPace.with_stops(attrs[:name] || attrs["name"], attrs)

    case post(base <> "/v1/collect", Jason.encode!(attrs)) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 409}} -> :ok
      {:ok, %{status: 404}} -> {:error, :collect_unsupported}
      {:ok, %{status: 503}} -> {:error, :collect_disabled}
      # **断られた理由はそのまま通す。** 数字だけ出しても、押した人には
      # 次に何をすればよいか分からない（実際に「400」とだけ出て、Chiezo の版が
      # 古くて新しい集め方を知らない、という理由に辿り着けなかった）
      {:ok, %{status: status, body: body}} -> {:error, {:chiezo_refused, status, reason_of(body)}}
      {:error, _reason} -> {:error, :chiezo_unavailable}
    end
  end

  @doc """
  収集の設定の一部を差し替えます（渡した項目だけ）。
  """
  def patch(base, name, attrs) do
    url = base <> "/v1/collect/" <> name

    # **巡回を並びごと送るときは、整理を自動で回さないことも載せ直す**（載せないと時計が戻る）
    attrs = Tazuna.CollectPace.with_stops(name, attrs)

    case Http.patch(url, Jason.encode!(attrs),
           headers: [{"user-agent", @user_agent}],
           content_type: "application/json",
           timeout: @timeout,
           connect_timeout: @connect_timeout
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> {:error, :not_requested}
      {:ok, %{status: status, body: raw}} -> {:error, {:chiezo_refused, status, reason_of(raw)}}
      {:error, _reason} -> {:error, :chiezo_unavailable}
    end
  end

  @doc """
  **この部分を集中的に直して**、を Chiezo へ割り込ませます。

  定時の巡回とは別の道で、進み具合にも次の予定にも触りません。名指しした画家は
  必ず AI に見せられます（区画を渡すだけでは、直してほしい 1 人が差し込みに載る
  保証がない）。
  """
  def focus(base, name, note, titles, sweep \\ nil, partition \\ nil, prompt \\ nil) do
    # **どの巡回として走らせるかを名指しできる。** 相手も考える量も依頼文も
    # 巡回ごとに違うので、名指ししないと「どの設定で走ったのか」が言えない。
    # **区画を名指しすると、その区画に印が付く**（先に見てほしいと頼んだのだから、
    # 巡回が同じところをもう一度見る必要は無い）
    body =
      %{note: note, titles: titles, requested_by: "tazuna"}
      |> then(&if(sweep, do: Map.put(&1, :sweep, sweep), else: &1))
      |> then(&if(partition, do: Map.put(&1, :partition, partition), else: &1))
      # **その回だけの依頼文**。材料（数えたタグなど）を作れるのは tazuna の側なので、
      # 定義の文では渡せない。Chiezo は保存しないので、定時の回は元の文のまま
      |> then(&if(prompt, do: Map.put(&1, :prompt, prompt), else: &1))
      |> Jason.encode!()

    case post(base <> "/v1/collect/" <> name <> "/focus" <> manual_query("?"), body, @timeout) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 403}} -> {:error, :collection_disabled}
      {:ok, %{status: 404}} -> {:error, :not_requested}
      {:ok, %{status: 409}} -> {:error, :chiezo_busy}
      {:ok, %{status: 503}} -> {:error, :collect_disabled}
      {:ok, %{status: status, body: raw}} -> {:error, {:chiezo_refused, status, reason_of(raw)}}
      {:error, _reason} -> {:error, :chiezo_unavailable}
    end
  end

  @doc false
  # Chiezo は理由を `{"error": "..."}` で返す。読めなければ nil
  def reason_of(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} when is_binary(error) -> error
      {:ok, %{"detail" => %{"error" => error}}} when is_binary(error) -> error
      _ -> nil
    end
  end

  # 人が押した操作の印を置く場所（`by_hand/1`）
  @by_hand_key {__MODULE__, :by_hand}

  @doc """
  **人が押した操作として頼みます**（中で呼んだ `run/3` と `focus/7` に `manual=true` を付ける）。
  Chiezo は、止めている収集でも人が押した 1 回は走らせます —— AI の使い過ぎを気にして
  収集を止めていても、区画を名指しした 1 回や travel-log からの依頼は頼みたいため。

  **定時の時計（要約）は囲まない**約束です。止めた収集が
  時計で動かないことが、止めた意味なので。印はプロセスに置くので、**囲むのは Chiezo を
  呼ぶプロセスの中**（Task を起こすなら Task の中で囲む）。
  """
  def by_hand(fun) when is_function(fun, 0) do
    previous = Process.put(@by_hand_key, true)

    try do
      fun.()
    after
      if previous, do: Process.put(@by_hand_key, previous), else: Process.delete(@by_hand_key)
    end
  end

  @doc "人が押した操作として頼んでいる最中か（`by_hand/1` の中か）。"
  def by_hand?, do: Process.get(@by_hand_key) == true

  defp manual_query(joint), do: if(by_hand?(), do: joint <> "manual=true", else: "")

  @doc """
  予定を待たずに1回走らせます。**止まっている収集は Chiezo が断ります**（403）。
  人が押した操作（`by_hand/1` の中）なら、止まっていても走らせます。
  """
  def run(base, name, opts \\ []) do
    # **巡回を名指しできる。** 相手も 1 回に見る量も巡回ごとに違うので、
    # 「この回だけ今すぐ」を頼めないと、分けてある意味が半分になる。
    # **時計を持たない巡回は Chiezo が断る**（あれは割り込みからしか走らない）
    query = if sweep = opts[:sweep], do: "?" <> URI.encode_query(%{"sweep" => sweep}), else: ""
    query = query <> manual_query(if query == "", do: "?", else: "&")

    # **区画と相手は、その 1 回だけの上書き**（`once`）。書かなければ
    # ふつうの回がふつうの設定で走る —— 区画の地図から「ここを 1 回見て」と
    # 頼むときだけ書きます。**ふつうの回として走る**ので、印も進み具合も進みます
    once =
      %{
        "partitions" => List.wrap(opts[:partitions] || opts[:partition]),
        "backend" => opts[:backend],
        "model" => opts[:model],
        "worker" => opts[:worker],
        # **その回だけの補足**（travel-log から届いた依頼など）。Chiezo が依頼文の
        # 後ろに足す。保存はされないので、定時の回は元の依頼文のまま走る。
        # `note` は全部の区画に同じもの、`notes` は区画ごと（その区画を聞く回にだけ載る）
        "note" => opts[:note],
        "notes" => opts[:notes]
      }
      |> Enum.reject(fn {_k, v} -> v in [nil, "", [], %{}] end)
      |> Map.new()

    body = if once == %{}, do: "", else: Jason.encode!(once)

    case post(base <> "/v1/collect/" <> name <> "/run" <> query, body, opts[:timeout] || 600_000) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 403}} -> {:error, :collection_disabled}
      {:ok, %{status: 404}} -> {:error, :not_requested}
      {:ok, %{status: 409}} -> {:error, :chiezo_busy}
      {:ok, %{status: 503}} -> {:error, :collect_disabled}
      {:ok, %{status: status}} -> {:error, {:chiezo_status, status}}
      {:error, _reason} -> {:error, :chiezo_unavailable}
    end
  end

  @doc """
  Chiezo でいま取り込みが走っているか。走っている間は「いま集めて」を断られます。

  **押してから断られるのと、押せないことが見えているのとでは別物**なので、
  押す前に確かめられるようにしてあります。読めなければ「走っていない」に倒します
  （この問い合わせが失敗しただけで押せなくなるほうが困る）。
  """
  def ingesting?(base) do
    case get(base <> "/v1/ingest/status") do
      {:ok, %{status: 200, body: body}} ->
        match?({:ok, %{"running" => true}}, Jason.decode(body))

      _ ->
        false
    end
  end

  @doc """
  **取り込みが空くまで待ってから**頼みます。`ask` が `{:error, :chiezo_busy}` を
  返すあいだは待って頼み直し、`deadline`（`System.monotonic_time(:millisecond)`
  の値）を過ぎたらそこで諦めて `{:error, :chiezo_busy}` を返します。

  **Chiezo は取り込み中の依頼を積まずに断ります**（409）。定時の回が取り込みと
  重なるたびにその回を落としていると、混む時間帯に当たる回はいつまでも走らない ——
  次の予定まで待てば、同じ回を二重に走らせることもありません。
  """
  def when_free(ask, deadline) when is_function(ask, 0) do
    case ask.() do
      {:error, :chiezo_busy} = busy ->
        if System.monotonic_time(:millisecond) >= deadline do
          busy
        else
          Process.sleep(Application.get_env(:tazuna, :chiezo_busy_poll_ms, @busy_poll_ms))
          when_free(ask, deadline)
        end

      other ->
        other
    end
  end

  @doc """
  地名の候補（`%{name, title, lat, lon, area, feature}` の並び）。**地図の地名検索と、範囲を描くのに使います**。

  地図辞典（`#{@place_source}`）で引き、見出しごとに座標を取り直します ——
  検索の結果には座標が付いてこないためです。座標を持たないものは落とします。
  """
  def places(base, q) when is_binary(q) do
    # **「〇〇駅」は「駅」を外した語でも探し、駅を先に並べる。** 地図辞典（OSM）は駅名に
    # 「駅」を付けない決まりで、本物の東京駅は「東京」として入っている —— 「東京駅」で
    # 引けるのは、名前に「駅」の付いた別のもの（日光の模型や、駅前の店）だけだった
    stem = String.replace_suffix(q, "駅", "")

    with {:ok, titles} <- place_titles(base, q),
         {:ok, stations} <- station_titles(base, q, stem) do
      found =
        (stations ++ titles)
        |> Enum.uniq()
        |> Task.async_stream(&place_of(base, &1), max_concurrency: 4, timeout: @timeout)
        |> Enum.flat_map(fn
          {:ok, {:ok, place}} -> [place]
          _other -> []
        end)
        # 「駅」を外した語で引いたものは、駅だけを残す（「東京」で引くと区や会社も並ぶ）
        |> Enum.reject(&(&1.title in stations and not station?(&1)))
        # **同じ名前・地域・種別は 1 つにまとめる。** 駅はホームや路線ごとに別の地物に
        # なっていて、「銀座 東京都・駅」が 3 つ並んでも選び分けようがない
        |> Enum.uniq_by(&{&1.name, &1.area, &1.feature})

      {:ok, found}
    end
  end

  defp station_titles(_base, q, q), do: {:ok, []}
  defp station_titles(_base, _q, ""), do: {:ok, []}
  defp station_titles(base, _q, stem), do: place_titles(base, stem)

  defp station?(%{feature: feature}),
    do: feature in ["railway=station", "public_transport=station", "railway=halt"]

  defp place_titles(base, q) do
    query = URI.encode_query(%{"q" => q, "limit" => @place_limit})

    with {:ok, %{status: 200, body: body}} <-
           get(base <> "/v1/" <> @place_source <> "/search?" <> query),
         {:ok, %{"results" => results}} when is_list(results) <- Jason.decode(body) do
      {:ok, results |> Enum.map(& &1["title"]) |> Enum.filter(&is_binary/1)}
    else
      {:ok, %{status: status}} -> {:error, {:chiezo_status, status}}
      {:error, _reason} -> {:error, :chiezo_unavailable}
      _other -> {:error, :chiezo_unexpected_body}
    end
  end

  defp place_of(base, title) do
    with {:ok, %{"extra" => %{"lat" => lat, "lon" => lon} = extra}} <-
           doc(base, @place_source, title, "title,extra"),
         true <- is_number(lat) and is_number(lon) do
      {:ok,
       %{
         # 見出しの重複を避ける番号（`銀座 (node:6271990033)`）は見せない
         name: String.replace(title, ~r/\s*\((?:node|way|relation):\d+\)$/u, ""),
         title: title,
         lat: lat,
         lon: lon,
         area: extra["area"],
         feature: extra["feature"]
       }}
    else
      _other -> :none
    end
  end

  @doc """
  収集の変更履歴（新しい順。1 回 = 1 行）。`sweep` で回を絞れます。

  1 行に入るのは、いつ・どの巡回が・どの区画（`scope`）を見て、何を足し・直し・
  消したか（件数と、見出しの頭のほう）。引けなければ `{:error, 理由}`。
  """
  def changes(base, name, opts \\ []) do
    query =
      %{"name" => name, "limit" => opts[:limit] || 30, "sweep" => opts[:sweep]}
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> URI.encode_query()

    case get(base <> "/v1/collect/changes?" <> query) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"changes" => rows}} when is_list(rows) -> {:ok, Enum.map(rows, &change_of/1)}
          _other -> {:error, :chiezo_unexpected_body}
        end

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  defp change_of(row) do
    %{
      at: parse_time(row["at"]),
      status: row["status"],
      sweep: row["sweep"],
      scope: list_of(row["scope"]),
      # **実際に見終えた区画**（`scope` は見る予定だった区画）。途中で止まった回も
      # 状態は ok なので、見分けるにはこちらを読む。記録の無い古い Chiezo では nil
      visited: if(is_list(row["visited"]), do: list_of(row["visited"])),
      added: row["added"] || 0,
      updated: row["updated"] || 0,
      removed: row["removed"] || 0,
      added_titles: list_of(row["added_titles"]),
      updated_titles: list_of(row["updated_titles"]),
      removed_titles: list_of(row["removed_titles"]),
      error: row["error"] || "",
      backend: row["backend"],
      model: row["model"],
      ms: row["ms"]
    }
  end

  defp list_of(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp list_of(_values), do: []

  defp parse_time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _other -> nil
    end
  end

  defp parse_time(_text), do: nil

  @doc """
  Chiezo の画面で、1 件の「直す前との違い」を開く URL（収集の 1 件のページ）。
  """
  def doc_page_url(name, title) when is_binary(name) and is_binary(title) do
    url(
      "/admin/collect/" <>
        URI.encode(name, &URI.char_unreserved?/1) <>
        "/doc?" <>
        URI.encode_query(%{"title" => title})
    )
  end

  @doc "溜まった件数。集めたものは長期記憶側にあるので、ソース表から取ります。"
  def docs_count(base, name) do
    with {:ok, %{status: 200, body: body}} <- get(base <> "/v1/sources"),
         {:ok, %{"sources" => sources}} <- Jason.decode(body),
         %{"docs" => docs} <- Enum.find(sources, &(&1["name"] == name)) do
      docs
    else
      _ -> 0
    end
  end

  def get(url, opts \\ []) do
    Http.get(
      url,
      Keyword.merge(
        [
          headers: [{"user-agent", @user_agent}],
          timeout: @timeout,
          connect_timeout: @connect_timeout
        ],
        opts
      )
    )
  end

  def post(url, body, timeout \\ @timeout) do
    Http.post(url, body,
      headers: [{"user-agent", @user_agent}],
      content_type: "application/json",
      timeout: timeout,
      connect_timeout: @connect_timeout
    )
  end

  @doc """
  収集の一覧（全部）。`{:ok, [収集の生の JSON]}` か `{:error, 理由}`。
  """
  def collections(base), do: list(base)

  @doc """
  ワーカーと取り込みの待ち行列（`GET /v1/collect/queue`）。**読むだけ**。
  口を持たない古い Chiezo では `{:error, :queue_unsupported}`。
  """
  def queue(base) do
    case get(base <> "/v1/collect/queue") do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"workers" => workers} = decoded} when is_list(workers) -> {:ok, decoded}
          _ -> {:error, :chiezo_unexpected_body}
        end

      # 口が無い（足す前の版）。**収集の名前として読まれて 404 になる**
      {:ok, %{status: 404}} ->
        {:error, :queue_unsupported}

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  defp list(base) do
    case get(base <> "/v1/collect") do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"collections" => collections}} when is_list(collections) -> {:ok, collections}
          _ -> {:error, :chiezo_unexpected_body}
        end

      # 収集の口そのものが無い Chiezo（層を足す前の版）
      {:ok, %{status: 404}} ->
        {:error, :collect_unsupported}

      # 溜め先が設定されていない Chiezo
      {:ok, %{status: 503}} ->
        {:error, :collect_disabled}

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  defp detail(base, name, fallback, samples) do
    case get(base <> "/v1/collect/" <> name <> "?samples=#{samples}") do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{} = detail} ->
            {:ok,
             detail
             |> to_map()
             |> Map.put(:docs, docs_count(base, name))
             |> Map.put(:recent, detail["recent"] || [])}

          _ ->
            {:error, :chiezo_unexpected_body}
        end

      # 一覧には出ていたのに引けないときは、一覧のぶんだけで出す
      {:ok, %{status: _status}} ->
        {:ok, to_map(fallback)}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  @doc false
  # 画面が要る項目だけ取り出す。**Chiezo が持っているものが正** —— 依頼した後は
  # 向こうの画面から変えられるので、tazuna 側の雛形を映すと嘘になりうる
  def to_map(%{} = item) do
    %{
      name: item["name"],
      description: item["description"] || "",
      enabled: item["enabled"] == true,
      interval_minutes: item["interval_minutes"],
      next_run_at: item["next_run_at"],
      last_run_at: item["last_run_at"],
      last_status: item["last_status"],
      last_error: item["last_error"],
      last_added: item["last_added"] || 0,
      last_removed: item["last_removed"] || 0,
      # 収集の種類（流れ / 網羅）。その収集が何を集めているのか
      # （返ってきた 1 件で何ができるかは、Chiezo が巡回ごとに決める）
      kind: item["kind"] || "stock",
      keep_days: item["keep_days"] || 0,
      prompt: item["prompt"] || "",
      cursor: item["cursor"] || "",
      # 最初の 1 回を機械的に埋める指定（持っていなければ nil）。
      # 何で埋まったのかは画面に出したいので、状態と一緒に持ち回る
      extract: item["extract"],
      backend: item["backend"],
      model: item["model"],
      effort: item["effort"],
      # 巡回（ざっと見る / 整理）。**相手も区画の進み具合も巡回ごとに違う**ので、
      # 収集に 1 つだけ持たせると、そこに出る値はどちらか片方のものにしかならない
      sweeps: sweeps_of(item),
      partitions_total: item["partitions_total"] || 0,
      # 区画の一覧。**どこがまだ見られていないかは、ここにしか無い** ——
      # 先に見てほしいところを頼むのに要る
      partitions: partitions_of(item),
      # **固定したのに、まだ焼いていない店の数**（Chiezo の `locks_pending`）。これがあれば
      # 「AI を使わずにいま反映する」を出す。固定の記録そのものは反映したあとも残るので、
      # 記録の数で出すと、反映が済んでも消えない。返さない古い Chiezo では固定の記録の数
      # （0 にするとボタンが出ず、固定を反映する手段が画面から消える）
      locks_pending: locks_pending(item),
      docs: 0,
      recent: [],
      requested_by: item["requested_by"] || "",
      url: url(item["url"])
    }
  end

  def to_map(_item), do: nil

  defp locks_pending(%{"locks_pending" => pending}) when is_integer(pending), do: pending
  defp locks_pending(%{"locks" => locks}) when is_map(locks), do: map_size(locks)
  defp locks_pending(_item), do: 0

  @doc """
  巡回の一覧。**Chiezo が持っているものが正**（依頼したあとは向こうの画面から
  変えられるので、tazuna が送った設定を映しても嘘になりえます）。
  """
  def worker_prefix, do: "worker:"

  @doc """
  その巡回の「頼む相手」。**ワーカーを名指ししていればそちらを返します**
  （`worker:<id>`）。Chiezo の相手の一覧でも同じ値で並ぶので、セレクトは
  1 つで足ります。

  **名指しは id で、名前ではありません。** 画面に出る札（`label`）は Chiezo 側で
  いつでも直せるので、名前で結ぶと改名した瞬間に指し先を見失います。
  """
  def backend_of(%{} = sweep) do
    case sweep["worker"] do
      ref when is_binary(ref) and ref != "" -> worker_prefix() <> ref
      _ -> sweep["backend"]
    end
  end

  def sweeps_of(%{"sweeps" => list}) when is_list(list) do
    for s <- list, is_map(s) do
      %{
        name: s["name"] || "",
        # 巡回の依頼文（書いていなければ収集の依頼文が返る）。`{cursor}` を使うかを見る
        prompt: s["prompt"] || "",
        # **ワーカーに頼む回は、相手の欄がワーカーを指します。** Chiezo は
        # 別の項目（`worker`）で返すので、こちらで相手の欄の値へ直します ——
        # セレクトは 1 つしか無いので、どちらが入っているかを画面に持ち込まない
        backend: backend_of(s),
        model: s["model"],
        interval_minutes: s["interval_minutes"],
        cover_days: s["cover_days"],
        partitions_per_run: s["partitions_per_run"],
        # 時計を持たない巡回（割り込み用）。定時には走らず、頼まれたときだけ動く
        on_demand: s["on_demand"] == true,
        # **機械で引く回。** AI を呼ばないので、相手を選ばせても何も起きない
        use_extract: s["use_extract"] == true,
        use_feed: s["use_feed"] == true,
        # **Pi-hole から引く回。** これも AI を呼ばない（Chiezo が Pi-hole を読んで足すだけ）
        use_pihole: s["use_pihole"] == true,
        # **手で回す回。** Chiezo が依頼文をファイルに書き出し、人が web の画面から
        # 使う AI に渡して、答えのファイルを読み込ませる —— こちらから走らせる道は
        # 無いので、相手も選ばせないし「この区画で 1 回」の相手にもしない
        by_hand: s["by_hand"] == true,
        enabled: s["enabled"] != false,
        next_run_at: s["next_run_at"],
        last_run_at: s["last_run_at"],
        last_status: s["last_status"],
        last_error: s["last_error"],
        partitions_visited: s["partitions_visited"] || 0,
        # **なぜ定時に走らないか**（走るなら空）。Chiezo が言う ——
        # 予定を持っていないだけの回と、先の回を待っている回は、どちらも予定が空。
        # こちらで場合分けを書き写すと、向こうの決まりが変わったときに食い違う
        blocked: s["blocked"] || ""
      }
    end
  end

  def sweeps_of(_item), do: []

  @doc """
  区画の一覧（鍵・母集団の数・見終えた巡回）。

  **巡回ごとに別々の印を持ちます** —— ざっと見るが見終えた区画を整理はまだ見ていない、
  が普通に起きます。
  """
  def partitions_of(%{"partitions" => list}) when is_list(list) do
    for p <- list, is_map(p), is_binary(p["key"]) do
      %{
        key: p["key"],
        count: p["count"] || 0,
        visits: if(is_map(p["visits"]), do: p["visits"], else: %{})
      }
    end
  end

  def partitions_of(_item), do: []

  @doc """
  Chiezo で頼める相手の一覧。**画面の選択肢に使う**ので、向こうが有効にしている
  ものだけが返ります（無効な相手を選べても、走らせた瞬間に断られる）。

  引けなければ空。**選べないだけで、図は出ます**。
  """
  def backends(base) do
    case get(base <> "/v1/ai/backends") do
      {:ok, %{status: 200, body: raw}} ->
        case Jason.decode(raw) do
          {:ok, %{"backends" => list}} when is_list(list) ->
            for b <- list, is_map(b), b["id"] do
              %{
                id: b["id"],
                label: b["label"] || b["id"],
                models: b["models"] || [],
                # 相手か、ワーカーか。**足されたのは後から**なので、
                # 書いていない相手は相手として読む
                kind: b["kind"] || "backend"
              }
            end

          _ ->
            []
        end

      _ ->
        []
    end
  end
end
