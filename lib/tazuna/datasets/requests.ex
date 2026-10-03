defmodule Tazuna.Datasets.Requests do
  @moduledoc """
  travel-log から届いた「修正・追加の依頼」を、**その場所を含む区画の情報収集**として
  Chiezo に頼むところ。

  travel-log の管理画面の「渡すテキスト」をそのまま貼る前提です
  （`- [修正] 名前 (緯度,経度): 理由` / `- [追加] (緯度,経度): 理由`）。
  **座標から区画を引く** —— 追加の依頼は名前を持たないので場所は座標でしか言えず、
  名前だけでは同名の店を取り違えます。

  **割り込みではなく、ふつうの回として走らせます**（`Chiezo.run/3` の `partitions` と
  `notes`）。区画をいつもどおり見たうえで、依頼を補足として読んでもらう形で、
  区画には印が付きます。割り込みは「書かれたものだけを直す」回なので、
  足りないスポットを探しに行く仕事には向きません。

  **補足は区画ごとに分けて渡します。** Chiezo は区画ごとに AI を呼び、見せるのは
  その区画の中身だけです —— 全部の区画に同じ依頼を渡すと、その店を見ていない AI まで
  答えようとして、中身を知らないまま書き換えることがあります。
  """

  import Ecto.Query

  alias Tazuna.Chiezo
  alias Tazuna.Datasets
  alias Tazuna.Datasets.RequestLog
  alias Tazuna.Repo

  # Chiezo が 1 回で受ける区画の数の天井（`MAX_TRIAL_PARTITIONS`）。**超えたら断る** ——
  # 黙って切ると、切られた区画の依頼だけが誰にも読まれない
  @max_partitions 20

  # 座標の書き方は travel-log のテキストの `(35.68123,139.76712)`。空白は許す
  @point ~r/\(\s*(-?\d{1,2}(?:\.\d+)?)\s*,\s*(-?\d{1,3}(?:\.\d+)?)\s*\)/u

  # 「位置は正しい」の行（travel-log の `- [位置確認] 名前 (緯度,経度)`）。**AI には渡さない**
  # —— 頼むだけでは守れないので、Chiezo に座標を固定させる（`hold/2`）
  @confirm_mark "[位置確認]"
  # 位置確認の行の店を探す広さ（メートル）。地図に出ている座標そのものなので狭くてよい
  @hold_meters 60

  @doc """
  「位置は正しい」の行（`- [位置確認] 名前 (緯度,経度)`）。`%{name, lat, lon}` の並び。
  """
  def confirms(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, @confirm_mark))
    |> Enum.flat_map(fn line ->
      with {lat, lon} <- point_of(line),
           name when name != "" <- confirm_name(line) do
        [%{name: name, lat: lat, lon: lon}]
      else
        _none -> []
      end
    end)
  end

  def confirms(_text), do: []

  @doc "「位置は正しい」の行を除いたテキスト（AI に渡す依頼のぶん）。"
  def without_confirms(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&String.contains?(&1, @confirm_mark))
    |> Enum.join("\n")
  end

  def without_confirms(_text), do: ""

  defp confirm_name(line) do
    line
    |> String.split(@confirm_mark, parts: 2)
    |> List.last()
    |> String.split("(", parts: 2)
    |> List.first()
    |> String.trim()
  end

  @doc """
  「位置は正しい」の店の座標を、Chiezo に固定させます（AI を通さない）。

  店は**その座標の近くにある、同じ名前の 1 件**で探します（`Tazuna.Datasets.ClosedTwins`
  と同じ名前の比べ方。travel-log は見分けの番号「 (1470114)」を落として出すので、
  名前だけでは引けない）。見つからなかった・断られた店も黙って落とさずに返します。

  返すのは `{:ok, %{held: [名前], missed: [名前], failed: [{名前, 理由}]}}` か
  `{:error, 理由}`（Chiezo の場所が無いなど）。
  """
  def hold(%{collection: name}, confirms) when is_list(confirms) do
    with {:ok, base} <- Datasets.base_url() do
      results =
        Enum.map(confirms, fn %{name: shop, lat: lat, lon: lon} ->
          with {:ok, docs} <- Chiezo.nearby(base, name, lat, lon, @hold_meters),
               %{"title" => title} <- same_shop(docs, shop, lat, lon) || :missed,
               :ok <- Chiezo.lock(base, name, title, lat, lon) do
            {:held, shop}
          else
            :missed -> {:missed, shop}
            {:error, reason} -> {:failed, {shop, reason}}
          end
        end)

      {:ok,
       %{
         held: for({:held, shop} <- results, do: shop),
         missed: for({:missed, shop} <- results, do: shop),
         failed: for({:failed, one} <- results, do: one)
       }}
    end
  end

  # 近くの同じ名前の 1 件（消えたものは除く。いちばん近いもの）
  defp same_shop(docs, shop, lat, lon) do
    want = Tazuna.Datasets.ClosedTwins.normalize(shop)

    docs
    |> Enum.reject(&(Chiezo.removed_tag() in (&1["tags"] || [])))
    |> Enum.filter(&(Tazuna.Datasets.ClosedTwins.normalize(&1["title"]) == want))
    |> Enum.min_by(&distance(&1, lat, lon), fn -> nil end)
  end

  defp distance(%{"extra" => %{"lat" => la, "lon" => lo}}, lat, lon)
       when is_number(la) and is_number(lo),
       do: :math.pow(la - lat, 2) + :math.pow(lo - lon, 2)

  defp distance(_doc, _lat, _lon), do: 1.0e9

  @doc "1 回に頼める区画の数。"
  def max_partitions, do: @max_partitions

  @doc """
  テキストに書かれた座標（`{緯度, 経度}` の並び。書かれた順・重複なし。1 行に 1 つ）。
  """
  def points(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.flat_map(&List.wrap(point_of(&1)))
    |> Enum.uniq()
  end

  def points(_text), do: []

  # 1 行の座標（最初の 1 つ）。無ければ nil
  defp point_of(line) do
    with [lat, lon] <- Regex.run(@point, line, capture: :all_but_first),
         {lat, lon} = {to_float(lat), to_float(lon)},
         true <- abs(lat) <= 90 and abs(lon) <= 180 do
      {lat, lon}
    else
      _none -> nil
    end
  end

  defp to_float(text) do
    {value, ""} = Float.parse(if String.contains?(text, "."), do: text, else: text <> ".0")
    value
  end

  @doc """
  頼む前の見積もり。`{:ok, %{keys, notes, points, missed}}` か `{:error, 理由}`。

  1 行ずつ座標を読み、**その行を座標の入る区画の補足に振り分けます**（`notes` は
  区画の鍵 → その区画のぶんのテキスト）。

  - **最初の座標より前の行**（見出し）は、どの区画の補足にも付けます
  - **座標の無い行**（理由の続き）は、直前の座標の行と同じ区画に付けます
  - **どの区画にも入らない座標の行**は渡さず、`missed` に出します（黙って落とすと、
    その依頼だけが誰にも読まれない）

  区画は矩形（`南,西/北,東`）のものだけを見ます。辺の上にある点は先に並んでいる区画に
  入れます（どちらで見ても同じ場所なので、1 つに決まればよい）。
  **Chiezo に問い合わせずに決めます**（画面が読み込んである区画の一覧を使う）——
  押した直後に「何区画で頼むか」「どれが外れたか」を出せるようにするためです。
  """
  def plan(text, partitions) when is_list(partitions) do
    boxes = boxes(partitions)

    acc =
      (text || "")
      |> String.split("\n")
      |> Enum.reduce(
        %{header: [], order: [], lines: %{}, at: :header, points: [], missed: []},
        &take_line(&1, &2, boxes)
      )

    cond do
      acc.points == [] ->
        {:error, :no_points}

      acc.order == [] ->
        {:error, :no_partition}

      length(acc.order) > @max_partitions ->
        {:error, {:too_many_partitions, length(acc.order)}}

      true ->
        notes =
          Map.new(acc.order, fn key ->
            {key, (acc.header ++ acc.lines[key]) |> Enum.join("\n") |> String.trim()}
          end)

        {:ok,
         %{
           keys: acc.order,
           notes: notes,
           points: Enum.uniq(acc.points),
           missed: Enum.uniq(acc.missed)
         }}
    end
  end

  defp take_line(line, acc, boxes) do
    case point_of(line) do
      nil ->
        case acc.at do
          :header -> %{acc | header: acc.header ++ [line]}
          # 区画の外の依頼の続きは、その依頼と一緒に外す
          :outside -> acc
          key -> put_line(acc, key, line)
        end

      point ->
        acc = %{acc | points: acc.points ++ [point]}

        case Enum.find(boxes, fn {_key, box} -> inside?(point, box) end) do
          nil -> %{acc | at: :outside, missed: acc.missed ++ [point]}
          {key, _box} -> put_line(%{acc | at: key}, key, line)
        end
    end
  end

  defp put_line(acc, key, line) do
    order = if key in acc.order, do: acc.order, else: acc.order ++ [key]
    %{acc | order: order, lines: Map.update(acc.lines, key, [line], &(&1 ++ [line]))}
  end

  defp boxes(partitions) do
    Enum.flat_map(partitions, fn %{key: key} ->
      case box(key) do
        nil -> []
        box -> [{key, box}]
      end
    end)
  end

  defp box(key) when is_binary(key) do
    with [sw, ne] <- String.split(key, "/"),
         [s, w] <- String.split(sw, ","),
         [n, e] <- String.split(ne, ","),
         {s, ""} <- Float.parse(s),
         {w, ""} <- Float.parse(w),
         {n, ""} <- Float.parse(n),
         {e, ""} <- Float.parse(e) do
      {s, w, n, e}
    else
      _not_a_box -> nil
    end
  end

  defp box(_key), do: nil

  defp inside?({lat, lon}, {s, w, n, e}), do: lat >= s and lat <= n and lon >= w and lon <= e

  @doc """
  区画を名指しして、情報収集の巡回を 1 回走らせます。**区画ごとの補足を載せます**
  （`plan/2` の `keys` と `notes`）。

  取り込み中なら空くまで待ちます（`deadline` は `System.monotonic_time(:millisecond)` の値）。
  """
  def run(%{collection: name} = dataset, %{keys: keys, notes: notes}, deadline) do
    sweep = sweep(dataset)
    notes = Map.new(notes, fn {key, text} -> {key, with_preface(text)} end)

    with {:ok, base} <- Datasets.base_url() do
      Chiezo.when_free(
        fn -> Chiezo.run(base, name, sweep: sweep, partitions: keys, notes: notes) end,
        deadline
      )
    end
  end

  @doc """
  依頼を走らせる巡回。**範囲の収集は整理、全国版は情報収集**（対象の定義の
  `request_sweep`）。どちらも「確かめて直す・消す・足す」を引き受ける回です。
  """
  def sweep(dataset), do: dataset[:request_sweep] || dataset[:survey_plan_sweep]

  @doc """
  依頼の頭に付ける前置き。**依頼を、情報収集のいつもの仕事より先に済ませてもらう**
  ための文です。

  情報収集の依頼文は「足りない店を足す」を主な仕事と言い切っていて、Chiezo は依頼を
  その後ろに「いつもの仕事に加えて」「確かめてから反映」と足します。これだと、
  **閉店の報告は後回しになり、しかも web で閉店を確かめられない小さな店は
  「確かめられなかった」として残ります** —— 実際、現地で潰れていると報告した店の
  半分近くが残りました。報告してくるのは現地を見た人なので、閉店の報告は
  **営業中だと確かめられない限り消す**、に倒します。

  **答えたあとも、いつもの仕事を続けてもらいます。** 「先に答えて」とだけ書いて
  いた頃は、補足が依頼文のいちばん最後に付くこともあって、AI が報告への回答を
  その回の仕事の全部と受け取り、2 区画・14 分の整理の回で報告のぶんしか返さな
  かった（まだ目を通していない店も、足りない店も、閉店の見直しも手付かず）。

  **名前の末尾の番号も断っておきます。** travel-log へ書き出すときに、同じ名前を
  見分けるための「 (1470114)」を落としているので、依頼の名前は見出しと一字違いに
  なることがあります。
  """
  def preface do
    """
    この補足は、**地図を使っている人が現地で見て書いた報告**です。
    **この区画では、足りない店を探すより先に、この報告に答えてください。**
    **答えたら、そのあと上の依頼文のいつもの仕事も続けてください**（まだ目を通して
    いない店・足りない店・閉店の見直し）—— 報告に答えただけで終えないでください。

    - 「閉店」「潰れた」「無い」「存在しない」と書かれたものは、**営業していると
      確かめられない限り、墓標で消してください**（body に「現地から閉店の報告」と、
      確かめたことがあれば添える）。小さな店の閉店は web に出ないことが多いので、
      **「閉店を確かめられなかった」は残す理由になりません**。最近の口コミや公式の
      告知で営業中だと確かめられたときだけ残し、そのことを body に書いてください
    - **報告された店は、いま消えていても戻さないでください**（戻す印を付けない）
    - 名前は地図に出している名前です。見出しの末尾の「 (数字)」が落ちていることが
      あります —— **座標の近い、同じ名前の 1 件**を指しています
    - 座標のずれ・種類の違いの報告は、正しい値を自分で調べて直してください
    - 「ある」と書かれたものは、確かめてから足してください（座標を必ず入れる）
    """
    |> String.trim_trailing()
  end

  defp with_preface(text), do: preface() <> "\n\n" <> text

  # 画面に並べる依頼の数
  @shown_logs 5
  # 画面に並べる最近の回の数（自動の回も含む）
  @shown_runs 10
  # 焼くところで落ちて戻した行が、もとの回からどこまで遅れて残るか。焼くのは集め終えた
  # 直後なので数十分で足りるが、取り込みが混んでいる日を見込んで広めに取る
  @rewind_window_s 3 * 60 * 60

  @doc """
  依頼を控えます（**頼む前に**。取り込みが空くのを最長 1 時間待つので、その間も
  画面に「待っている」と出せるように）。返すのは控えの行。
  """
  def record(%{collection: name}, %{keys: keys, points: points, missed: missed}, text) do
    %RequestLog{}
    |> RequestLog.changeset(%{
      collection: name,
      keys: keys,
      text: String.trim(text),
      points: length(points),
      missed: length(missed),
      requested_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert()
  end

  @doc "頼んだ結果（Chiezo が受けたか・断ったか）を控えます。"
  def mark(%RequestLog{} = log, :ok),
    do: log |> RequestLog.changeset(%{status: "sent"}) |> Repo.update()

  def mark(%RequestLog{} = log, {:error, reason}),
    do: log |> RequestLog.changeset(%{status: "failed", error: inspect(reason)}) |> Repo.update()

  @doc "直近の依頼（新しい順）。"
  def recent(collection, limit \\ @shown_logs) do
    RequestLog
    |> where([r], r.collection == ^collection)
    |> order_by([r], desc: r.requested_at, desc: r.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  依頼ごとに、**その結果になった回**を引き当てます（`result`。まだ無ければ nil）。

  Chiezo の変更履歴は、その回がどの依頼から走ったのかを持ちません。そこで
  **頼んだ時刻より後に、頼んだ区画をちょうど見た回**のうち、いちばん早いものを
  結果とみなします（区画の並びは問わない）。定時の回は Chiezo が選んだ区画を
  見るので、区画の組がそっくり一致することは、まずありません。
  """
  def with_results(logs, changes) do
    Enum.map(logs, fn log ->
      wanted = MapSet.new(log.keys)

      result =
        changes
        |> Enum.filter(fn change ->
          change.at != nil and DateTime.compare(change.at, log.requested_at) != :lt and
            MapSet.new(change.scope) == wanted
        end)
        |> Enum.min_by(& &1.at, DateTime, fn -> nil end)
        |> rewound(changes)

      %{log: log, result: result, unfinished: unfinished(log, result)}
    end)
  end

  # **焼くところで落ちた回は、戻されている。** Chiezo は集め終えた時点で ok の行を
  # 残し、焼くところで落ちたと分かると進み具合を戻して、**見ていた区画を名指しした
  # 失敗の行をあとから足す**（ok の行は消えない）。ok の行だけを読むと、何も残らな
  # かった回が「動いた」ことになる
  defp rewound(%{status: "ok", at: at} = result, changes) do
    seen = MapSet.new(Map.get(result, :visited) || result.scope)

    changes
    |> Enum.filter(fn change ->
      change.status != "ok" and change.at != nil and
        DateTime.compare(change.at, at) == :gt and
        DateTime.diff(change.at, at) <= @rewind_window_s and
        MapSet.size(seen) > 0 and MapSet.new(change.scope) == seen
    end)
    |> Enum.min_by(& &1.at, DateTime, fn -> result end)
  end

  defp rewound(result, _changes), do: result

  @doc """
  頼んだ区画のうち、**その回が見終えなかったもの**。途中で相手に繋がらなくなった回は
  残りの区画を見送って ok で終わるので、見る予定の区画（`scope`）が揃っていても、
  全部を見たとは限らない。見終えた区画を持たない古い Chiezo の行では空（分からない）。
  """
  def unfinished(_log, nil), do: []
  def unfinished(_log, %{status: status}) when status != "ok", do: []

  def unfinished(log, result) do
    case Map.get(result, :visited) do
      nil ->
        []

      visited ->
        done = MapSet.new(visited)
        Enum.reject(log.keys, &MapSet.member?(done, &1))
    end
  end

  @doc """
  直近の依頼と、その結果。Chiezo を引くので、呼ぶのは画面の裏から。
  """
  def results(%{collection: name} = dataset) do
    logs = recent(name)

    changes =
      with {:ok, base} <- Datasets.base_url(),
           {:ok, rows} <- Chiezo.changes(base, name, sweep: sweep(dataset), limit: 50) do
        rows
      else
        _unavailable -> []
      end

    with_results(logs, changes)
  end

  @doc """
  最近の回（**自動で回った回も、依頼で走った回も**）。新しい順に `limit` 件。
  `{:ok, [%{change: 回, by_request: 依頼で走った回か}]}` か `{:error, 理由}`。

  依頼の結果（`results/1`）は、tazuna が控えた依頼ごとに回を引き当てるので、
  自動の回は出てこない —— 整理やざっと見るが何を直したのかを見るには、Chiezo の
  画面まで行くしかなかった。**依頼で走った回は見分けて印を付ける**（同じ回が
  依頼の結果にも出るので、どちらで見ているのかが分かるように）。
  """
  def runs(%{collection: name} = dataset, limit \\ @shown_runs) do
    logs = recent(name, @shown_runs * 2)
    sweep = sweep(dataset)

    with {:ok, base} <- Datasets.base_url(),
         {:ok, rows} <- Chiezo.changes(base, name, limit: limit) do
      {:ok, Enum.map(rows, &%{change: &1, by_request: by_request?(&1, logs, sweep)})}
    end
  end

  # 依頼で走った回か。**頼んだ区画の組がそっくり同じで、頼んだあとの回**
  # （`with_results/2` と同じ引き当て方）
  defp by_request?(%{at: %DateTime{} = at, scope: scope, sweep: run_sweep}, logs, sweep)
       when scope != [] do
    run_sweep == sweep and
      Enum.any?(logs, fn log ->
        MapSet.new(log.keys) == MapSet.new(scope) and
          DateTime.compare(at, log.requested_at) != :lt
      end)
  end

  defp by_request?(_change, _logs, _sweep), do: false

  @doc "見積もりの段で断った理由の言い方（Chiezo が断った理由は画面の側が言う）。"
  def error_text(:no_points),
    do: "座標が見つかりませんでした。travel-log の「渡すテキスト」をそのまま貼ってください。"

  def error_text(:no_partition),
    do: "どの座標も、いまの区画のどれにも入りませんでした（区画の外の場所です）。"

  def error_text({:too_many_partitions, count}),
    do: "区画が #{count} あります。1 回に頼めるのは #{@max_partitions} までなので、分けて貼ってください。"
end
