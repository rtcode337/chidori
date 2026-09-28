defmodule Tazuna.Datasets.ClosedTwins do
  @moduledoc """
  **閉店で消した店の片割れ**を探して、AI に確かめてもらうところ。

  同じ店が辞典に 2 件以上入っていることがあります（辞典違い・同じ辞典の中の重複）。
  閉店として消したのが片方だけだと、**もう片方が生きたまま地図に残ります** ——
  実測で、閉店として消した店と同じ名前の店が、同じ住所で名簿の回から入ったまま
  AI に一度も見られていなかった（別の区画に入っていると、同じ回では目に入らない）。

  消した店の近く（`@radius_m`）で名前の似た生きている店を拾い、**名指しして
  ざっと見るの回に割り込ませます**。消すかどうかは AI が決めます —— 近所に同じ
  チェーンの別の店があるのは普通なので、機械で消すと開いている店まで消える。

  **同じ組は二度頼みません**（`Tazuna.Datasets.ClosedTwinCheck`）。「別の店なので
  残す」と判断された 1 件は生きたまま残るので、控えが無いと毎日頼み直すことになる。

  **場所を知るのは Chiezo の墓標**（消した 1 件の `lat` / `lon`）。墓標は脇書きを
  削りますが、場所は残すようになっています。場所の無い墓標（残すようになる前に
  消したもの）は、次の名簿の回が辞典から書き戻すまで探せません。
  """

  import Ecto.Query

  alias Tazuna.Chiezo
  alias Tazuna.Datasets.ClosedTwinCheck
  alias Tazuna.Repo

  # 片割れを探す半径。**同じ建物の中の点のずれ**が拾えればよい（辞典ごとに置いた
  # 点は数十 m ずれる）。広げると、通りの向かいの同じチェーンばかり拾う
  @radius_m 60
  # 1 回の割り込みで名指しする数。Chiezo が 1 回に受け付ける上限
  # （`Tazuna.Datasets.Meals` の要約と同じ `MAX_FOCUS_TITLES`）
  @per_ask 50
  # 墓標を読む 1 頁の大きさ（Chiezo の上限）
  @page 500
  # 消した理由から閉店を読み取る。**移転は数えない** —— 近所へ移った店は、
  # 近くの似た名前の 1 件こそが生きている本体
  @closed ~r/閉店|閉業|廃業|営業終了|営業を終了/u
  @moved ~r/移転/u

  @doc "消した理由が閉店か。"
  def closed?(reason) when is_binary(reason),
    do: Regex.match?(@closed, reason) and not Regex.match?(@moved, reason)

  def closed?(_reason), do: false

  @doc """
  2 つの名前が同じ店を指していそうか。**見分けの札**（末尾の「 (…)」）を落とし、
  全角半角・大文字小文字・空白と中黒を揃えてから比べます。
  片方がもう片方を含むものも拾います（「エース」と「洋食 エース」）。
  """
  def similar?(a, b) do
    x = normalize(a)
    y = normalize(b)

    cond do
      x == "" or y == "" -> false
      x == y -> true
      # 短い名前の包含は何にでも当たる（「一」は「一蘭」にも「一風堂」にも入る）
      String.length(x) < 3 or String.length(y) < 3 -> false
      true -> String.contains?(x, y) or String.contains?(y, x)
    end
  end

  @doc false
  def normalize(name) do
    name
    |> to_string()
    |> strip_labels()
    |> :unicode.characters_to_nfkc_binary()
    |> String.downcase()
    |> String.replace(~r/[\s・･\-‐－_'’&＆.。、,]/u, "")
  end

  # 「名前 (千代田区)」「名前 (node:123)」「名前 (1772404)」の札を落とす
  defp strip_labels(name) do
    stripped = Regex.replace(~r/\s*[（(][^（）()]*[）)]\s*$/u, name, "")
    if stripped == name or stripped == "", do: String.trim(name), else: strip_labels(stripped)
  end

  @doc """
  まだ頼んでいない片割れを探します。`{:ok, [%{twin:, closed:, reason:, meters:}]}`。

  1 件の生きている店が、近くの閉店 2 件の片割れに当たることがあります（同じ名前の
  店が 2 度閉店している）。そのときは組ごとに並べます（控えも組ごと）。
  """
  def find(base, collection) do
    with {:ok, tombstones} <- closed_tombstones(base, collection) do
      asked = asked(collection)

      pairs =
        for stone <- tombstones,
            twin <- living_near(base, collection, stone),
            similar?(twin["title"], stone.title),
            not MapSet.member?(asked, {twin["title"], stone.title}) do
          %{
            twin: twin["title"],
            closed: stone.title,
            reason: stone.reason,
            meters: round(distance_m(stone, twin["extra"]))
          }
        end

      {:ok, pairs}
    end
  end

  @doc """
  片割れを名指しして、ざっと見るの回に確かめてもらいます。
  `{:ok, 頼んだ数}` / `{:error, 理由}`。頼むものが無ければ `{:ok, 0}`（Chiezo を起こさない）。

  **頼めたものだけ控えます** —— 断られた（取り込みが混んでいた）ぶんは次の回に頼み直す。
  """
  def ask(base, %{collection: collection, survey_sweep: sweep}) do
    with {:ok, pairs} <- find(base, collection) do
      batch = take_batch(pairs)

      if batch == [] do
        {:ok, 0}
      else
        titles = batch |> Enum.map(& &1.twin) |> Enum.uniq()

        case Chiezo.focus(base, collection, note(batch), titles, sweep) do
          :ok ->
            remember(collection, batch)
            {:ok, length(titles)}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  # **名指しする店の数で切る**（組の数ではない。1 店が 2 組に出ることがある）
  defp take_batch(pairs) do
    pairs
    |> Enum.reduce_while({[], MapSet.new()}, fn pair, {kept, twins} ->
      twins = MapSet.put(twins, pair.twin)

      if MapSet.size(twins) > @per_ask,
        do: {:halt, {kept, twins}},
        else: {:cont, {[pair | kept], twins}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc false
  # AI への補足。**消した店と理由を並べて見せる** —— 名指しだけだと、何を
  # 確かめてほしいのかが伝わらない。**消すかどうかは任せる**（近所に同じチェーンの
  # 別の店があるのは普通）
  def note(batch) do
    lines =
      Enum.map(batch, fn pair ->
        "・#{pair.twin} ← 約 #{pair.meters}m 先の「#{pair.closed}」を消しました（理由: #{one_line(pair.reason)}）"
      end)

    """
    次の店は、すぐ近くにある同じ名前（似た名前）の店を、閉店として消したものです。
    同じ店が辞典に 2 件入っていて、片方だけが消えている可能性があります。

    #{Enum.join(lines, "\n")}

    1 軒ずつ確かめてください。
    - 消した店と同じ店（同じ住所・同じ建物の、辞典違いや表記違い）なら、同じく閉店として墓標で消してください（理由も同じように 1 行で）。
    - 別の店（同じチェーンの別の店舗、同じ名前の別の店）で営業しているなら、そのまま残してください。返さなくてかまいません。
    """
  end

  defp one_line(reason), do: reason |> String.split("\n") |> hd() |> String.slice(0, 80)

  defp remember(collection, batch) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(batch, fn pair ->
        %{
          collection: collection,
          twin: pair.twin,
          closed: pair.closed,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(ClosedTwinCheck, rows, on_conflict: :nothing)
  end

  defp asked(collection) do
    ClosedTwinCheck
    |> where([c], c.collection == ^collection)
    |> select([c], {c.twin, c.closed})
    |> Repo.all()
    |> MapSet.new()
  end

  # 閉店で消した墓標のうち、場所を持っているもの
  defp closed_tombstones(base, collection, offset \\ 0, acc \\ []) do
    case Chiezo.spot_docs(base, collection, Chiezo.removed_tag(), offset, @page,
           include_removed: true
         ) do
      {:ok, %{docs: []}} ->
        {:ok, Enum.reverse(acc)}

      {:ok, %{docs: docs, total: total}} ->
        acc =
          Enum.reduce(docs, acc, fn doc, acc ->
            extra = doc["extra"] || %{}
            reason = extra["removed_reason"] || ""

            if closed?(reason) and is_number(extra["lat"]) and is_number(extra["lon"]) do
              [%{title: doc["title"], reason: reason, lat: extra["lat"], lon: extra["lon"]} | acc]
            else
              acc
            end
          end)

        next = offset + length(docs)

        if next >= total,
          do: {:ok, Enum.reverse(acc)},
          else: closed_tombstones(base, collection, next, acc)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # 近くの生きている店。**まだ AI が見ていない店も入れる** —— 片割れはたいてい
  # 名簿の回で入ったまま見られていない（読み口の既定では外れる）
  defp living_near(base, collection, stone) do
    case Chiezo.nearby(base, collection, stone.lat, stone.lon, @radius_m) do
      {:ok, docs} -> Enum.reject(docs, &(Chiezo.removed_tag() in (&1["tags"] || [])))
      {:error, _reason} -> []
    end
  end

  # 2 点の距離（m）。近いところしか比べないので、平面の近似で足りる
  defp distance_m(%{lat: lat1, lon: lon1}, %{"lat" => lat2, "lon" => lon2})
       when is_number(lat2) and is_number(lon2) do
    dy = (lat2 - lat1) * 111_320
    dx = (lon2 - lon1) * 111_320 * :math.cos(lat1 * :math.pi() / 180)
    :math.sqrt(dx * dx + dy * dy)
  end

  defp distance_m(_stone, _extra), do: 0
end
