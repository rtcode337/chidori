defmodule Antenna.Relations.Graph do
  @moduledoc """
  Chiezo に溜まった文書を、ネットワーク図の形に読み直します。

  **Chiezo には図の構造を持ち込みません。** 向こうにあるのは「1 画家 = 1 文書」の
  普通のソースで、属性と関係はタグに載せてあります。ノードとエッジという読み方を
  与えるのは antenna 側の仕事です。判断や見せ方を Chiezo に持たせない、という
  線を崩さないための形です。

  タグの書き方は 3 つ。値に `:` を含められるよう、先頭の 1〜2 個で区切ります。

      様式:ポスト印象派
      年代:1880-1890
      代表作:ひまわり (絵画)         … その画家の絵を出すときの手掛かり
      影響元:クロード・モネ          … その画家から影響を受けた
      影響元:クロード・モネ:光と色彩  … 説明を添える（線の上に出る）

  **「影響元」（受けた側から見る）にしてあります。** 1 つの文書はその画家自身を
  説明するものなので、「誰から受けたか」は自分の属性として書けます。
  「誰に与えたか」にすると、他人の文書を書き換えないと関係を足せません。
  """

  # 図を描く面。ノード数から幅を決めるので、ここは最小の大きさ
  @canvas_width 980
  @canvas_height 560

  @kind_tag "画家"
  @style_prefix "様式"
  @years_prefix "年代"
  @work_prefix "代表作"
  @influence_prefix "影響元"
  # 記事どうしが相互にリンクしている、というだけの線。**Chiezo が機械的に付ける**ので、
  # AI を待たずに図がつながる。何の関係かまでは分からないので、影響の線とは分けて描く
  @related_prefix "関連"

  # 丸の大きさ。**知名度で変える** —— どれが中心的な画家かが、読む前に分かる。
  # 知名度そのものは jawiki の月次ページビュー（`Antenna.Fame`）
  @min_radius 26
  @max_radius 60

  @doc "代表作を載せるタグの頭。"
  def work_tag, do: @work_prefix

  @doc "相互リンクの相手を載せるタグの頭。"
  def related_tag, do: @related_prefix

  @doc "Chiezo の `filter` が返した文書の並びを、図のデータにします。"
  def from_docs(docs) when is_list(docs) do
    nodes =
      docs
      |> Enum.flat_map(&to_node/1)
      |> Enum.uniq_by(& &1.name)
      |> Enum.sort_by(&sort_key/1)
      |> Enum.with_index()
      |> Enum.map(fn {node, index} -> Map.put(node, :id, "n#{index}") end)

    by_name = Map.new(nodes, &{&1.name, &1})

    placed = layout(nodes)

    %{
      nodes: placed,
      edges: edges(docs, by_name),
      ticks: ticks(placed),
      width: canvas_width(length(nodes)),
      height: canvas_height(length(nodes))
    }
  end

  def from_docs(_docs), do: empty()

  def empty,
    do: %{nodes: [], edges: [], ticks: [], width: @canvas_width, height: @canvas_height}

  @doc """
  縦軸に置く年表の目盛り。`%{year:, y:}` を古い順に返します。

  **等間隔には置きません。** 丸は年代の順に等間隔で並べてあって、年代そのものに
  比例してはいない（比例させると、画家が集中する 19 世紀後半だけ団子になり、
  空いている世紀に何もない余白ができる）。目盛りは前後の丸の年代から位置を割り出して
  置くので、**人が多い年代ほど間隔が広がります**。混み合った時代ほど紙面を取る、
  という読み方になります。

  刻みは、図が収める幅に合わせて 50 年か 100 年のどちらかにします。
  """
  def ticks(nodes) do
    dated = for node <- nodes, year = year_of(node), do: {year, node.y}

    case dated do
      [] ->
        []

      [_single] ->
        []

      _ ->
        {first, _} = List.first(dated)
        {last, _} = List.last(dated)
        step = tick_step(last - first)

        Stream.iterate(ceil_to(first, step), &(&1 + step))
        |> Enum.take_while(&(&1 <= last))
        |> Enum.map(&%{year: &1, y: y_at(&1, dated)})
    end
  end

  # 前後の丸のあいだを比例で割って、その年が来る高さを出す
  defp y_at(year, dated) do
    {before, rest} = Enum.split_while(dated, fn {y, _} -> y <= year end)

    case {List.last(before), List.first(rest)} do
      {nil, {_year, y}} -> y
      {{_year, y}, nil} -> y
      {{y1, top}, {y2, bottom}} when y2 > y1 -> top + (bottom - top) * (year - y1) / (y2 - y1)
      {{_y1, top}, _} -> top
    end
  end

  defp tick_step(span) when span > 400, do: 100
  defp tick_step(span) when span > 120, do: 50
  defp tick_step(_span), do: 25

  defp ceil_to(year, step), do: ceil(year / step) * step

  defp year_of(node) do
    case node.years && Regex.run(~r/\d{3,4}/, node.years) do
      [year] -> String.to_integer(year)
      _ -> nil
    end
  end

  @doc "この図に取り込む文書かどうかの目印。Chiezo からはこのタグで引きます。"
  def kind_tag, do: @kind_tag

  @doc """
  知名度を丸の大きさに変えます。**いちばん有名な人を基準にした比**で決めます。

  絶対値で決めると、題材が変わったときに全部が大きくなったり小さくなったりします。
  平方根を挟むのは、ページビューが桁で開くため —— そのまま面積に使うと、
  1 人だけが巨大になって他が点になります。
  """
  def sized(nodes, fame) when is_map(fame) do
    top = fame |> Map.values() |> Enum.max(fn -> 0 end)

    Enum.map(nodes, fn node ->
      Map.put(node, :radius, radius(Map.get(fame, node.article, 0), top))
    end)
  end

  def sized(nodes, _fame), do: Enum.map(nodes, &Map.put(&1, :radius, @min_radius))

  defp radius(_views, top) when top <= 0, do: @min_radius

  defp radius(views, top) when is_integer(views) and views > 0 do
    ratio = :math.sqrt(views / top)
    round(@min_radius + (@max_radius - @min_radius) * ratio)
  end

  defp radius(_views, _top), do: @min_radius

  # 出典が Wikipedia の記事なら、その記事名。知名度も絵もここから辿る
  defp article_title(%{"extra" => %{"url" => url}}) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host, path: "/wiki/" <> title} when is_binary(host) ->
        if String.ends_with?(host, "wikipedia.org"), do: URI.decode(title), else: nil

      _ ->
        nil
    end
  end

  defp article_title(_doc), do: nil

  defp to_node(%{"title" => title} = doc) when is_binary(title) do
    name = String.trim(title)
    tags = tags_of(doc)

    if name == "" or @kind_tag not in tags do
      []
    else
      [
        %{
          name: name,
          note: tag_value(tags, @style_prefix),
          years: tag_value(tags, @years_prefix),
          work: tag_value(tags, @work_prefix),
          # 出典（Wikipedia の記事）。知名度を引くのと、絵を探すのに使う
          article: article_title(doc),
          kind: :artist
        }
      ]
    end
  end

  defp to_node(_doc), do: []

  # 年代の始まりで並べる。左から右へ時代が流れる図なので、並びがそのまま意味になる
  defp sort_key(node), do: {year_of(node) || 9999, node.name}

  defp edges(docs, by_name) do
    influence =
      for doc <- docs,
          to = by_name[String.trim(to_string(doc["title"] || ""))],
          to != nil,
          {from_name, label} <- influences(tags_of(doc)),
          from = by_name[from_name],
          from != nil,
          from.id != to.id do
        %{from: from.id, to: to.id, label: label, kind: :influence}
      end
      # 同じ向きの線は 1 本に畳む（同じ相手を 2 つのタグで挙げても重ならない）
      |> Enum.uniq_by(&{&1.from, &1.to})

    influence ++ related(docs, by_name, influence)
  end

  # 相互リンクの線。**古いほうから新しいほうへ向ける** —— 記事どうしのリンクに
  # 向きは無いが、時代の流れは分かっているので、こちらで向きを与える。
  #
  # **影響の線がある組には引かない。** AI が「何を受けたか」まで書いた組は、
  # そちらのほうが濃い情報なので、上に薄い線を重ねない。
  defp related(docs, by_name, influence) do
    known = MapSet.new(influence, fn edge -> Enum.sort([edge.from, edge.to]) end)

    for doc <- docs,
        node = by_name[String.trim(to_string(doc["title"] || ""))],
        node != nil,
        other_name <- tag_values(tags_of(doc), @related_prefix),
        other = by_name[other_name],
        other != nil,
        other.id != node.id,
        not MapSet.member?(known, Enum.sort([node.id, other.id])),
        # 古い側から新しい側へ 1 本だけ（相互リンクなので両方の文書に出てくる）
        {from, to} = order_by_age(node, other),
        from.id == node.id do
      %{from: from.id, to: to.id, label: nil, kind: :related}
    end
    |> Enum.uniq_by(&{&1.from, &1.to})
  end

  defp order_by_age(a, b) do
    if (year_of(a) || 9999) <= (year_of(b) || 9999), do: {a, b}, else: {b, a}
  end

  defp tag_values(tags, prefix) do
    for tag <- tags, String.starts_with?(tag, prefix <> ":") do
      tag |> String.split(":", parts: 2) |> List.last() |> String.trim()
    end
  end

  defp influences(tags) do
    for tag <- tags, String.starts_with?(tag, @influence_prefix <> ":") do
      case String.split(tag, ":", parts: 3) do
        [_, name, label] -> {String.trim(name), trimmed(label)}
        [_, name] -> {String.trim(name), nil}
      end
    end
  end

  defp tags_of(%{"tags" => tags}) when is_list(tags), do: Enum.map(tags, &to_string/1)
  defp tags_of(_doc), do: []

  defp tag_value(tags, prefix) do
    tags
    |> Enum.find(&String.starts_with?(&1, prefix <> ":"))
    |> case do
      nil -> nil
      tag -> tag |> String.split(":", parts: 2) |> List.last() |> trimmed()
    end
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_value), do: nil

  # **時代は縦に流す。** 人数が増えても幅が要らないので、たくさん並べられる
  # （横に流していた頃は 12 人で幅 2400 になり、画面に収まらなかった）。
  # 左右は重なりを避けるためだけに振る
  defp layout([]), do: []

  defp layout(nodes) do
    count = length(nodes)
    cell = canvas_height(count) / count

    Enum.with_index(nodes, fn node, index ->
      Map.merge(node, %{
        x: column_x(index),
        y: cell * (index + 0.5)
      })
    end)
  end

  # 3 列に振り分ける。同じ列に隣り合う年代を置かないので、線が縦に潰れない
  defp column_x(index), do: 220 + rem(index, 3) * 270

  defp canvas_width(_count), do: @canvas_width

  # 1 人ぶんの高さを確保する。詰めると丸と札が重なる
  defp canvas_height(count) when count > 0, do: max(@canvas_height, 130 * count)
  defp canvas_height(_count), do: @canvas_height
end
