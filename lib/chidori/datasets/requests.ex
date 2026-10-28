defmodule Chidori.Datasets.Requests do
  @moduledoc """
  travel-log から届いた「修正・追加の依頼」を、**その場所を含む区画の整理**として
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

  alias Chidori.Chiezo
  alias Chidori.Datasets
  alias Chidori.Datasets.PendingRequest
  alias Chidori.Datasets.RequestLog
  alias Chidori.Repo

  # Chiezo が 1 回で受ける区画の数の天井（`MAX_TRIAL_PARTITIONS`）。**超えたら断る** ——
  # 黙って切ると、切られた区画の依頼だけが誰にも読まれない
  @max_partitions 20

  # 座標の書き方は travel-log のテキストの `(35.68123,139.76712)`。空白は許す
  @point ~r/\(\s*(-?\d{1,2}(?:\.\d+)?)\s*,\s*(-?\d{1,3}(?:\.\d+)?)\s*\)/u

  # 「位置OK」の行（travel-log の `- [位置確認] 名前 (緯度,経度)`）。**AI には渡さない**
  # —— 頼むだけでは守れないので、Chiezo に座標を固定させる（`hold/2`）
  @confirm_mark "[位置確認]"
  # 「この位置へ直して」の行（travel-log の `- [位置修正] 名前 (緯度,経度) → (緯度,経度)`）。
  # これも **AI には渡さない** —— 正しい位置は人が地図で指してあるので、調べさせる理由が無い。
  # 前の座標で店を探し、後ろの座標で固定させる（`hold/2`）
  @move_mark "[位置修正]"
  # 位置確認の行の店を探す広さ（メートル）。地図に出ている座標そのものなので狭くてよい
  @hold_meters 60

  # 「閉店している」の報告（`- [修正] 名前 (緯度,経度): 理由`）。**位置を固定した店は
  # AI の墓標では消えない**（Chiezo の `locked_doubt_tag`）ので、人が現地で見た報告は
  # 頼む前に固定を外す（`release_closed/2`）—— 外さないと「閉店の可能性あり」が付くだけで残る
  @fix_mark "[修正]"
  @closed ~r/閉店|閉業|廃業|潰れ|つぶれ|なくなって|無くなって|営業して(い)?ない|やってい?ない|存在しない|見当たらない/u

  @doc """
  AI を通さずに座標を固定させる行。`%{name, lat, lon}` の並び（`lat` / `lon` は店を探す
  いまの座標）。

  - 「位置OK」（`- [位置確認] 名前 (緯度,経度)`）—— その座標で固定する
  - 「この位置へ直して」（`- [位置修正] 名前 (緯度,経度) → (緯度,経度)`）—— 後ろの座標で
    固定する（`to: {緯度, 経度}` が付く）
  """
  def confirms(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      cond do
        String.contains?(line, @move_mark) -> held_line(line, @move_mark)
        String.contains?(line, @confirm_mark) -> held_line(line, @confirm_mark)
        true -> []
      end
    end)
  end

  def confirms(_text), do: []

  defp held_line(line, mark) do
    points =
      for [_all, lat, lon] <- Regex.scan(@point, line),
          {lat, lon} = {to_float(lat), to_float(lon)},
          abs(lat) <= 90 and abs(lon) <= 180,
          do: {lat, lon}

    name = confirm_name(line, mark)

    case {mark, points} do
      {_mark, _points} when name == "" -> []
      {@move_mark, [{lat, lon}, to | _]} -> [%{name: name, lat: lat, lon: lon, to: to}]
      {@move_mark, _points} -> []
      {_confirm, [{lat, lon} | _]} -> [%{name: name, lat: lat, lon: lon}]
      _none -> []
    end
  end

  @doc "AI を通さない行（位置OK・位置修正）を除いたテキスト（AI に渡す依頼のぶん）。"
  def without_confirms(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&(String.contains?(&1, @confirm_mark) or String.contains?(&1, @move_mark)))
    |> Enum.join("\n")
  end

  def without_confirms(_text), do: ""

  defp confirm_name(line, mark) do
    line
    |> String.split(mark, parts: 2)
    |> List.last()
    |> String.split("(", parts: 2)
    |> List.first()
    |> String.trim()
  end

  @doc """
  「位置OK」「この位置へ直して」の店の座標を、Chiezo に固定させます（AI を通さない）。
  直す先（`to`）があればその座標で、無ければいまの座標で固定します。

  店は**その座標の近くにある、同じ名前の 1 件**で探します（`same_name/1`
  と同じ名前の比べ方。travel-log は見分けの番号「 (1470114)」を落として出すので、
  名前だけでは引けない）。見つからなかった・断られた店も黙って落とさずに返します。

  返すのは `{:ok, %{held: [名前], missed: [名前], failed: [{名前, 理由}]}}` か
  `{:error, 理由}`（Chiezo の場所が無いなど）。
  """
  def hold(%{collection: name}, confirms) when is_list(confirms) do
    with {:ok, base} <- Datasets.base_url() do
      results =
        Enum.map(confirms, fn %{name: shop, lat: lat, lon: lon} = confirm ->
          {to_lat, to_lon} = confirm[:to] || {lat, lon}

          with {:ok, docs} <- Chiezo.nearby(base, name, lat, lon, @hold_meters),
               %{"title" => title} <- same_shop(docs, shop, lat, lon) || :missed,
               :ok <- Chiezo.lock(base, name, title, to_lat, to_lon) do
            {:held, if(confirm[:to], do: shop <> "（位置を直した）", else: shop)}
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

  @doc """
  人が「閉店している」と報告した店（`%{name, lat, lon}` の並び）。`[修正]` の行のうち、
  理由が閉店を言っているものだけ。
  """
  def closures(text) when is_binary(text) do
    for line <- String.split(text, "\n"),
        String.contains?(line, @fix_mark),
        [_head, reason] <- [String.split(line, "):", parts: 2)],
        Regex.match?(@closed, reason),
        %{name: name, lat: lat, lon: lon} <- held_line(line, @fix_mark),
        do: %{name: name, lat: lat, lon: lon}
  end

  def closures(_text), do: []

  @doc """
  閉店を報告された店のうち、**位置を固定している店の固定を外します**（`Chiezo.unlock/3`）。
  固定した店は AI の墓標では消えず「閉店の可能性あり」が付くだけなので、人が現地で
  見た報告まで残ってしまう。外した店の名前を返す（固定していない店・見つからない店は触らない）。
  """
  def release_closed(_dataset, []), do: []

  def release_closed(%{collection: name}, closures) do
    case Datasets.base_url() do
      {:ok, base} ->
        for %{name: shop, lat: lat, lon: lon} <- closures,
            {:ok, docs} <- [Chiezo.nearby(base, name, lat, lon, @hold_meters)],
            %{"title" => title} = doc <- [same_shop(docs, shop, lat, lon)],
            Chiezo.locked_tag() in (doc["tags"] || []),
            :ok <- [Chiezo.unlock(base, name, title)],
            do: shop

      _error ->
        []
    end
  end

  @doc """
  **AI を使わずに、固定した座標をいま反映させます**（機械収集の回を 1 回走らせる）。

  固定（`hold/2`）は次に焼くときから効くので、そのままだと次の AI の回まで
  travel-log へ出せない。名簿を引く回は AI を呼ばずに焼くので、これで反映される
  （名簿は足すだけなので、ほかは変わらない）。止まっている収集は Chiezo が断る。
  """
  def apply_now(%{collection: name, module: module}) do
    with {:ok, base} <- Datasets.base_url() do
      # 押したのは人（止めている収集でも走らせる。`Chiezo.by_hand/1`）
      Chiezo.by_hand(fn ->
        Chiezo.run(base, name, sweep: module.roster_sweep_name(), timeout: 60_000)
      end)
    end
  end

  # 近くの同じ名前の 1 件（消えたものは除く。いちばん近いもの）
  defp same_shop(docs, shop, lat, lon) do
    want = same_name(shop)

    docs
    |> Enum.reject(&(Chiezo.removed_tag() in (&1["tags"] || [])))
    |> Enum.filter(&(same_name(&1["title"]) == want))
    |> Enum.min_by(&distance(&1, lat, lon), fn -> nil end)
  end

  @doc false
  # 店の名前を、比べられる形に均す（見分けの札・空白・記号・全角半角・大小を落とす）。
  # travel-log は見分けの番号「 (1470114)」を落として出すので、名前だけでは引けない
  def same_name(name) do
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

  defp distance(%{"extra" => %{"lat" => la, "lon" => lo}}, lat, lon)
       when is_number(la) and is_number(lo),
       do: :math.pow(la - lat, 2) + :math.pow(lo - lon, 2)

  defp distance(_doc, _lat, _lon), do: 1.0e9

  @doc """
  依頼のテキストを、**1 件ずつ**に分けます（`%{text, lat, lon}` の並び）。1 件は座標の行と、
  その続きの行（座標を持たない行）。**最初の座標より前の行（見出し）は捨てます** ——
  控えは 1 件ずつ区画に振り分けるので、どの依頼にも属さない行は持てない。
  """
  def items(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      case {point_of(line), acc} do
        {{lat, lon}, acc} ->
          [%{text: String.trim_trailing(line), lat: lat, lon: lon} | acc]

        {nil, []} ->
          acc

        {nil, [last | rest]} ->
          [%{last | text: last.text <> "\n" <> String.trim_trailing(line)} | rest]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&%{&1 | text: String.trim(&1.text)})
  end

  def items(_text), do: []

  @doc """
  依頼のテキストを、**範囲ごとに振り分けます**（食事処の範囲の画面から）。travel-log は
  いくつもの範囲を 1 つの画面で扱うので、依頼のテキストにはどの範囲の店かが書いていない ——
  **1 件ずつ、座標の入る範囲**へ回す。

  返すのは `%{areas: [%{area, confirms, items}], outside: %{confirms, items}}`。
  `confirms` は位置OK・位置修正（`confirms/1` の形）、`items` は AI に頼む依頼
  （`items/1` の形）。**位置修正は店が今いる座標（前の座標）で振り分ける** —— 直す先が
  境目の向こうでも、店を探すのは今いる範囲の収集。どの範囲にも入らないものは `outside` に
  まとめて返す（黙って落とさない）。

  **範囲が重なっていたら、いちばん狭い範囲へ**（より絞った範囲を作ったのは、そこを
  細かく見たいからなので）。`areas` は範囲（`south` / `west` / `north` / `east` を持つもの）。
  """
  def route(text, areas) when is_binary(text) and is_list(areas) do
    confirms = confirms(text)
    items = items(without_confirms(text))
    where = fn %{lat: lat, lon: lon} -> area_of(lat, lon, areas) end

    confirms_by = Enum.group_by(confirms, where)
    items_by = Enum.group_by(items, where)

    routed =
      areas
      |> Enum.filter(&(Map.has_key?(confirms_by, &1) or Map.has_key?(items_by, &1)))
      |> Enum.map(fn area ->
        %{
          area: area,
          confirms: Map.get(confirms_by, area, []),
          items: Map.get(items_by, area, [])
        }
      end)

    %{
      areas: routed,
      outside: %{confirms: Map.get(confirms_by, nil, []), items: Map.get(items_by, nil, [])}
    }
  end

  @doc "座標の入る範囲（重なっていれば、いちばん狭いもの）。どこにも入らなければ nil。"
  def area_of(lat, lon, areas) do
    areas
    |> Enum.filter(&(&1.south <= lat and lat <= &1.north and &1.west <= lon and lon <= &1.east))
    |> Enum.min_by(&((&1.north - &1.south) * (&1.east - &1.west)), fn -> nil end)
  end

  @doc """
  依頼を**控えます**（すぐには頼まない）。貼ったその場で頼むと、1 件しか依頼の無い
  区画にも AI の回が 1 回走り、枠を使い潰す —— 区画ごとに溜まった件数を見てから頼む。

  **同じ依頼を貼り直しても 1 件のまま**（テキストが同じものは足さない）。
  返すのは `{:ok, %{added: 件数, skipped: 件数}}`。

  **報告に名前の出てくる店が近くで消えていたら、その店のいる区画で頼みます**
  （`revive_point/2`）。`nearby` は依頼 1 件の近くの文書を返す関数（テストで差し替える）。
  """
  def stash(%{collection: name} = dataset, text, nearby \\ nil) do
    nearby = nearby || (&chiezo_nearby(dataset, &1))

    results =
      for item <- items(text) do
        item = item |> revive_point(nearby.(item)) |> with_partition_key(dataset)

        %PendingRequest{}
        |> PendingRequest.changeset(Map.put(item, :collection, name))
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:collection, :text])
        |> case do
          {:ok, %{id: id}} when not is_nil(id) -> :added
          _skipped -> :skipped
        end
      end

    {:ok,
     %{
       added: Enum.count(results, &(&1 == :added)),
       skipped: Enum.count(results, &(&1 == :skipped))
     }}
  end

  # **座標で区画を引けない対象は、控えるときに区画の鍵を決めて残す**（対象の
  # `request_partition/1`。ご当地グルメは料理の県）。決まらなければ鍵を持たずに控え、
  # 「どの区画にも入らない」に並ぶ
  defp with_partition_key(item, %{module: module}) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :request_partition, 1),
      do: Map.put(item, :partition_key, module.request_partition(item)),
      else: item
  end

  defp with_partition_key(item, _dataset), do: item

  @doc """
  依頼を振り分ける座標。**報告に名前の出てくる店が近くで消えていたら、その店の座標**、
  そうでなければ報告の座標のままです（`item` の `lat` / `lon` を差し替えて返す。
  依頼のテキストは変えない —— AI に入れさせる座標は報告のもの）。

  消えた店は、それがいる区画の「消したもの」にしか並ばない。報告の座標は辞典の座標と
  数百 m ずれることがあり、報告の座標の区画で頼むと、AI は消えたことを知らずに同じ
  見出しで足し直し、Chiezo は「見せていない既存の 1 件」として弾く（何度頼んでも
  入らない）。消えた店の区画で頼めば、AI に消えたものとして見え、戻す印を付けて戻せる。

  **近くに同じ名前の生きている店があれば差し替えない**（戻すものが無い）。名前は
  3 文字以上のものだけを見る —— 短い名前は理由の文の中に紛れて、別の店を指しかねない。
  `docs` は近くの文書（消えたものを含む）。
  """
  def revive_point(%{text: text, lat: lat, lon: lon} = item, docs) when is_list(docs) do
    said = squash(text)

    {gone, alive} =
      docs
      |> Enum.filter(fn doc ->
        name = same_name(doc["title"] || "")
        String.length(name) >= 3 and String.contains?(said, name)
      end)
      |> Enum.split_with(&(Chiezo.removed_tag() in (&1["tags"] || [])))

    case {alive, Enum.min_by(gone, &distance(&1, lat, lon), fn -> nil end)} do
      {[], %{"extra" => %{"lat" => la, "lon" => lo}}} when is_number(la) and is_number(lo) ->
        %{item | lat: la, lon: lo}

      _keep ->
        item
    end
  end

  def revive_point(item, _docs), do: item

  # 消えた店を探す広さ（メートル）。報告の座標と辞典の座標は数百 m ずれることがある
  @revive_meters 1000

  # 依頼 1 件の近くの文書（消えたものを含む）。Chiezo を読めなければ空（報告の座標のまま）
  defp chiezo_nearby(%{collection: name}, %{lat: lat, lon: lon}) do
    with {:ok, base} <- Datasets.base_url(),
         {:ok, docs} <- Chiezo.nearby(base, name, lat, lon, @revive_meters) do
      docs
    else
      _error -> []
    end
  end

  # 報告の文を、店の名前と同じ形に揃える（`same_name/1` の札を落とさない版）
  defp squash(text) do
    text
    |> :unicode.characters_to_nfkc_binary()
    |> String.downcase()
    |> String.replace(~r/[\s・･\-‐－_'’&＆.。、,]/u, "")
  end

  @doc """
  控えている依頼を、**いまの区画ごとに**まとめます。`[%{key, items, since}]` を
  件数の多い順に（同じなら古い順）。どの区画にも入らない依頼は鍵 `nil` の 1 組に。

  **区画は見るたびに座標から引く**（控えは座標で持っている）—— 区画が割り直されても、
  控えた依頼は新しい区画に入り直す。
  """
  def pending(%{collection: name}, partitions) when is_list(partitions) do
    boxes = boxes(partitions)
    keys = MapSet.new(partitions, & &1.key)

    PendingRequest
    |> where([p], p.collection == ^name)
    |> order_by([p], asc: p.inserted_at, asc: p.id)
    |> Repo.all()
    |> Enum.group_by(&partition_of(&1, boxes, keys))
    |> Enum.map(fn {key, items} -> %{key: key, items: items, since: hd(items).inserted_at} end)
    |> Enum.sort_by(&{&1.key == nil, -length(&1.items), DateTime.to_unix(&1.since)})
  end

  def pending(_dataset, _partitions), do: []

  @doc "控えている依頼の数（区画に関係なく）。"
  def pending_count(%{collection: name}) do
    PendingRequest |> where([p], p.collection == ^name) |> select([p], count(p.id)) |> Repo.one()
  end

  @doc """
  1 つの区画に溜まった依頼を頼みます（`items` はその区画の控え）。**頼む前に控えを
  依頼の記録へ移し**（結果を依頼と並べて見せるため）、Chiezo が受けたら控えから消す。
  断られたら控えに残す（次にまた頼める）。

  **区画は頼む直前に読み直し、控えを振り分け直します**（`regroup/2`）。押したときの区画の
  まま頼むと、待っている間に割り直されていたとき（範囲を広げて保存した直後の回など）に、
  台帳に無い鍵を名指しすることになる。Chiezo はそれを断るが、断られたまま待ち続けても
  鍵は戻らない。振り分け直せば、新しい区画で頼める（区画が分かれていれば補足も分けて）。
  どの区画にも入らなくなった控えは頼まずに残す。

  取り込み中なら空くまで待ちます（`deadline`）。返すのは `{記録, 結果, 頼んだ組}`
  （頼んだ組は `regroup/2` の形。頼めなかったときは押したときの区画のまま）。
  """
  def send_partition(dataset, key, items, deadline, opts \\ [])
      when is_binary(key) and items != [] do
    text = Enum.map_join(items, "\n", & &1.text)
    plan = %{keys: [key], notes: %{key => text}, points: items, missed: []}
    {:ok, log} = record(dataset, plan, text)

    # **頼む直前に外す**（控えたまま取り消された報告では、固定を外さない）
    release_closed(dataset, closures(text))

    case run_regrouped(dataset, items, deadline, opts) do
      {:ok, sent} ->
        # 依頼の結果は区画の鍵で引き当てるので、実際に頼んだ鍵に直しておく
        {:ok, log} = log |> RequestLog.changeset(%{keys: sent.keys}) |> Repo.update()
        mark(log, :ok)
        drop(dataset, Enum.map(sent.points, & &1.id))
        {log, :ok, sent}

      error ->
        mark(log, error)
        {log, error, plan}
    end
  end

  @doc """
  控え（`items`）を、渡した区画で振り分け直します。返すのは
  `%{keys, notes, points, missed}`（`keys` は区画の並びの順、`notes` は区画ごとの補足、
  `points` は区画に入った控え、`missed` はどの区画にも入らなかった控えの座標）。
  """
  def regroup(items, partitions) when is_list(partitions) do
    boxes = boxes(partitions)
    known = MapSet.new(partitions, & &1.key)

    {inside, outside} =
      items
      |> Enum.map(&{partition_of(&1, boxes, known), &1})
      |> Enum.split_with(fn {key, _item} -> key != nil end)

    by_key = Enum.group_by(inside, &elem(&1, 0), &elem(&1, 1))
    keys = for %{key: key} <- partitions, Map.has_key?(by_key, key), do: key

    %{
      keys: keys,
      notes: Map.new(keys, &{&1, Enum.map_join(by_key[&1], "\n", fn item -> item.text end)}),
      points: Enum.flat_map(keys, &by_key[&1]),
      missed: Enum.map(outside, fn {nil, item} -> {item.lat, item.lon} end)
    }
  end

  # 控え 1 件の区画。**鍵を持っていれば、いまの台帳にあるときだけその鍵**（区画が
  # 消えていれば迷子として残す）、持っていなければ座標の入る矩形の区画
  defp partition_of(item, boxes, known) do
    case Map.get(item, :partition_key) do
      key when is_binary(key) and key != "" ->
        if MapSet.member?(known, key), do: key

      _none ->
        Enum.find_value(boxes, fn {key, box} ->
          if inside?({item.lat, item.lon}, box), do: key
        end)
    end
  end

  # 取り込みが空くのを待ちながら、**空いたその回の直前に**区画を読み直して頼む。
  # 待つ間に割り直されても、読み直した区画で頼み直せる
  defp run_regrouped(%{collection: name} = dataset, items, deadline, opts) do
    with {:ok, base} <- Datasets.base_url() do
      Chiezo.when_free(
        fn ->
          with {:ok, partitions} <- current_partitions(base, name),
               %{keys: [_ | _]} = plan <- regroup(items, partitions),
               :ok <- ask(base, dataset, plan, opts) do
            {:ok, plan}
          else
            %{keys: []} -> {:error, :partitions_moved}
            error -> error
          end
        end,
        deadline
      )
    end
  end

  defp current_partitions(base, name) do
    case Chiezo.collection(base, name) do
      {:ok, %{partitions: partitions}} -> {:ok, partitions}
      {:ok, nil} -> {:error, :not_requested}
      error -> error
    end
  end

  @doc "控えを消します（頼んだあと・取り消したとき）。消した件数を返す。"
  def drop(%{collection: name}, ids) when is_list(ids) do
    {count, _} =
      PendingRequest
      |> where([p], p.collection == ^name and p.id in ^ids)
      |> Repo.delete_all()

    count
  end

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

  # 区画を名指しして、依頼を引き受ける巡回（`sweep/1`）を 1 回走らせる。**区画ごとの補足を載せる**
  # （`regroup/2` の `keys` と `notes`）。`opts` は頼む相手（`backend`・`model`・`worker`。
  # その 1 回だけの上書きで、書かなければ巡回の設定のまま）
  defp ask(base, %{collection: name} = dataset, %{keys: keys, notes: notes}, opts) do
    notes = Map.new(notes, fn {key, text} -> {key, with_preface(text, dataset)} end)

    # 「この区画を頼む」を押したのは人（止めている収集でも走らせる。`Chiezo.by_hand/1`）
    Chiezo.by_hand(fn ->
      Chiezo.run(
        base,
        name,
        [sweep: sweep(dataset), partitions: keys, notes: notes] ++
          Keyword.take(opts, [:backend, :model, :worker])
      )
    end)
  end

  @doc """
  依頼を走らせる巡回（対象の定義の `request_sweep`。食事処は整理）。
  「確かめて直す・消す・足す」を引き受ける回です。
  """
  def sweep(dataset), do: dataset[:request_sweep]

  @doc """
  依頼の頭に付ける前置き。**依頼を、区画のいつもの仕事より先に済ませてもらう**
  ための文です。

  巡回の依頼文は区画のいつもの仕事（確かめる・足りない店を足す）を頼んでいて、Chiezo は依頼を
  その後ろに「いつもの仕事に加えて」「確かめてから反映」と足します。これだと、
  **閉店の報告は後回しになり、しかも web で閉店を確かめられない小さな店は
  「確かめられなかった」として残ります** —— 実際、現地で潰れていると報告した店の
  半分近くが残りました。報告してくるのは現地を見た人なので、閉店の報告は
  **営業中だと確かめられない限り消す**、に倒します。

  **答えたあとも、いつもの仕事を続けてもらいます。** 「先に答えて」とだけ書いて
  いた頃は、補足が依頼文のいちばん最後に付くこともあって、AI が報告への回答を
  その回の仕事の全部と受け取り、2 区画・14 分の整理の回で報告のぶんしか返さな
  かった（まだ目を通していない店も、足りない店も、閉店の見直しも手付かず）。

  **「閉店していない」の報告は、消えた店を戻させます。** 戻す印を付けたときだけ戻る
  決まりなので、頼まないと AI は消えた店に手を付けない。前置きに「報告された店は戻さない」
  とだけ書いていた頃は、閉店していないと報告した店まで消えたまま戻らなかった
  （その一文は、閉店を報告した店を戻させないためのもの）。

  **「ある」と報告された店が消えていたら、足し直さずに戻させます。** 戻す印を付けずに
  同じ見出しで返すと、消えたまま変わらない —— 足したつもりで何度頼んでも入らなかった。

  **現地で「ある」「変わった」と報告された店は、web で見つからなくても足させます。**
  「確かめてから足す」とだけ書いていた頃は、web に出ていない小さな店が足されず、
  同じ場所で web に出ている別の店（改装前の名前など）に置き換えられたり、
  「変わった」の報告で前の店だけ消えて新しい店が入らなかったりした。閉店の報告を
  報告どおりに倒すのと同じ理由です。名前の打ち間違いはあるので、一字違いなら web の
  名前を使わせます。

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
    - **「閉店していない」「営業している」と書かれた店が、いま消えていたら戻してください**
      （tags に "#{Chidori.Chiezo.restore_tag()}" を入れて、同じ見出しで返す。消えた店は上の
      「消したもの」に並んでいます）。現地で営業を見た報告なので、消したときの理由
      （「閉店した」など）より報告を信じてください。戻すときは body に「現地から営業中の報告」と書く
    - **「ある」「追加」と書かれた店が、上の「消したもの」に並んでいたら、新しく足さずに
      戻してください**（tags に "#{Chidori.Chiezo.restore_tag()}" を入れて、消したものと同じ
      見出しで返す。座標は報告のものを入れる）。現地で見た報告なので、消したときの理由より
      報告を信じてください。戻すときは body に「現地から営業中の報告」と書く
    - **閉店の報告があった店は、いま消えていても戻さないでください**（戻す印を付けない）
    - 名前は地図に出している名前です。見出しの末尾の「 (数字)」が落ちていることが
      あります —— **座標の近い、同じ名前の 1 件**を指しています
    - 座標のずれ・種類の違いの報告は、正しい値を自分で調べて直してください
    - 「〜に変わった」「〜になっている」と書かれたものは、**前の店を墓標で消し、新しい店を
      足す**の 2 つを組でやってください（消すだけで終えない）
    - 「ある」と書かれた店と、上の「変わった」先の店は、**web で見つからなくても足して
      ください**（座標は報告のものを必ず入れる）。現地で見た報告なので、web に出ていない
      ことは足さない理由になりません。web で確かめられなかったときは、body に
      「現地からの報告（web では確かめられず）」と書く。**そのときの body は、1 行目の「所在地:」と
      この 1 文のほかは、報告に書いてあったことだけにしてください**（報告の言葉をそのまま書き写す。
      報告に何も書いていなければ書かない）。**確かめていない紹介文（場所の様子・名物・どういう店か）を
      作らないでください** —— 地図では確かめた紹介と同じ顔で並ぶので、作った文が本当のことに見えます。
      **タグも同じです**: ジャンルは報告か店名から明らかなときだけ、特徴・ランク・営業時間は付けない
      （確かめていない印は「そうだ」と読まれます）
    - 報告の店名は打ち間違いのことがあります。**同じ場所に一字違いの店が web で見つかれば
      そちらの名前で**足してください。**名前の違う別の店しか見つからないときは、その店で
      置き換えずに報告の名前で足してください**（web の店も確かめられたなら、別の 1 件として足す）
    """
    |> String.trim_trailing()
  end

  @doc """
  対象ごとの前置き。**対象が自分の前置きを持っていればそれ**（`request_preface/0`。
  ご当地グルメは料理と代表店の言い方で書く）、無ければ `preface/0`（食事処）。
  """
  def preface(%{module: module}) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :request_preface, 0),
      do: module.request_preface(),
      else: preface()
  end

  def preface(_dataset), do: preface()

  defp with_preface(text, dataset), do: preface(dataset) <> "\n\n" <> text

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

  依頼の結果（`results/1`）は、Chidori が控えた依頼ごとに回を引き当てるので、
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
