defmodule Tazuna.Datasets.Map do
  @moduledoc """
  区画を地図の形に並べるところ。**置き場所を決めるだけ**で、描くのは画面です。

  **白地図は手元に持ちます**（`priv/geo/japan_coast.json`。Natural Earth のパブリック
  ドメインのデータを日本の範囲で切って間引いたもの）。外の地図を読みに行かないので、
  **手元だけで開けて、誰にも何を見ているかを知らせません** —— 区画の並びだけでも形は
  見えますが、海岸線があると「どこを見終えたか」が一目で分かります。

  **並べ方はメルカトル**（緯度は `ln(tan(45° + φ/2))`）。緯度をそのまま縦に使うと、
  南と北で横の縮尺が変わり、**北へ行くほど横に潰れます** —— 日本は南北に長いので、
  そのまま並べると九州と北海道で形が変わって見えます。

  **大きさは区画の広さそのもの。** 店の多いところほど細かく切られているので、
  細かい格子がそのまま「たくさん集まっているところ」になります。

  **濃さは詰まり具合の順位**（広さあたりの件数の順）。区画は指定した矩形を端から端まで
  覆うので、**海の上にも大きな区画が載ります** —— 同じ濃さで塗ると全面が埋まり、
  島の形が沈みます。薄くすれば、集まっているところだけが浮きます。

  **大きさは細くても本当のまま描きます。** 見える太さまで太らせていた頃は、
  8,185 区画のうち 6,295 が下限に当たっていて、**寄っても本当の大きさに戻らず**、
  同じ塊が大きくなるだけでした。区画は矩形を隙間なく覆うので、細い区画が
  消えても白い穴は空きません（隣が同じ色で埋めます）。

  **角は端の座標を丸めて出します**（幅ではなく）。幅を別々に丸めると、
  **隣と端が合わずに白い筋が出ます** —— 実測で 6,127 区画がずれていました。
  隣り合う区画は同じ境界の値を持つので、端で丸めれば必ず一致します。
  """

  # 図の幅。高さは区画の広がりから決める（日本は南北に長いので、縦は都度変わる）
  @width 960

  # 座標の桁。**0.001 は最大まで寄って 0.4px** —— ここが粗いと、寄ったときに
  # 角が階段になる（区画の端は押す口の端でもある）
  @places 3

  # 潰れて幅 0 になった区画の最低幅。0 の四角はどれだけ寄っても押せない
  @min_span 0.001

  # これより細い区画は「細い」印を付ける（画面側で、面の足りないぶんを
  # 画面 1px の縁で補う）。全体表示でおよそ 1.5px にあたる
  @tiny_side 2.0

  # いちばん薄い濃さ。**0 にはしない** —— 押せる四角なので、見えないところは押せない
  @min_tone 0.12

  @doc """
  区画の一覧を、四角の並びにします。**鍵から座標を読みます**
  （`南,西/北,東`。Chiezo が区画を切るときに決めた形）。

  読めない鍵は落とします —— 座標で切っていない収集（区画が名前で切られているもの）
  では、地図にする意味がありません。
  """
  def build(rows, opts \\ []) do
    boxes = rows |> Enum.map(&with_box/1) |> Enum.reject(&is_nil/1)

    case bounds(boxes) do
      nil ->
        %{rects: [], coast: [], width: @width, height: 0, visited: 0, origin: nil}

      {south, west, north, east} ->
        scale = @width / max(east - west, 1.0e-9)
        top = mercator(north)
        height = (top - mercator(south)) * scale

        rects = Enum.map(boxes, &place(&1, west, top, scale))

        %{
          rects: toned(rects),
          coast: coast(west, top, scale),
          width: @width,
          height: Float.round(height, 1),
          visited: Enum.count(boxes, &(stage(&1) > 0)),
          # 起点のピン。**区画と同じ置き方で投影する**（別々に置くとずれて重なる）
          origin: origin(opts[:origin], west, top, scale)
        }
    end
  end

  # 起点（`{緯度, 経度}`）を図の座標へ。渡されなければ nil（ピンを立てない）
  defp origin({lat, lon}, west, top, scale) when is_number(lat) and is_number(lon),
    do: %{x: round1((lon - west) * scale), y: round1((top - mercator(lat)) * scale)}

  defp origin(_none, _west, _top, _scale), do: nil

  @doc "図の幅（画面はこの座標系で描きます）。"
  def width, do: @width

  # 白地図。**区画と同じ置き方で投影する** —— 別々に置くと、海岸線と区画が
  # ずれたまま重なり、どちらが正しいのか読めなくなります
  defp coast(west, top, scale) do
    for ring <- Tazuna.Geo.Japan.rings() do
      ring
      |> Enum.map(fn [lon, lat] ->
        "#{round1((lon - west) * scale)} #{round1((top - mercator(lat)) * scale)}"
      end)
      |> then(fn [first | rest] -> "M#{first}L" <> Enum.join(rest, "L") <> "Z" end)
    end
  end

  defp with_box(row) do
    case parse(row.key) do
      nil ->
        nil

      {south, west, north, east} ->
        Map.merge(row, %{south: south, west: west, north: north, east: east})
    end
  end

  # 「南,西/北,東」。**数として読めない鍵は落とす**（名前で切った区画がこれに当たる）
  defp parse(key) when is_binary(key) do
    with [south_west, north_east] <- String.split(key, "/", parts: 2),
         [south, west] <- numbers(south_west),
         [north, east] <- numbers(north_east),
         true <- north > south and east > west do
      {south, west, north, east}
    else
      _other -> nil
    end
  end

  defp parse(_key), do: nil

  defp numbers(text) do
    text
    |> String.split(",")
    |> Enum.flat_map(fn part ->
      case Float.parse(String.trim(part)) do
        {number, _rest} -> [number]
        :error -> []
      end
    end)
  end

  defp bounds([]), do: nil

  defp bounds(boxes) do
    Enum.reduce(boxes, {90.0, 180.0, -90.0, -180.0}, fn box, {south, west, north, east} ->
      {min(south, box.south), min(west, box.west), max(north, box.north), max(east, box.east)}
    end)
  end

  # 濃さは**詰まり具合の順位**で決めます。
  #
  # **値の比では濃さになりません。** 実測で、いちばん詰まった区画といちばん空いた
  # 区画は 5 億倍離れています（都心の 1 区画と、外海を丸ごと覆う区画）。比で塗ると
  # 上位 1 割を基準にしても中央値が 0.14 —— 日本地図がほとんど白く飛びます。
  # 順位で塗れば、どんな散らばり方でも濃さが一様に散り、**どこが詰まっているか**が
  # そのまま読めます（絶対の値ではなく、この収集の中での相対です）。
  defp toned(rects) do
    order = rects |> Enum.map(& &1.density) |> Enum.sort()
    last = length(order) - 1
    # 同じ詰まり具合は同じ濃さにする（値 → 順位）
    ranks = order |> Enum.with_index() |> Map.new()

    for rect <- rects do
      tone =
        if last > 0,
          do: @min_tone + (1.0 - @min_tone) * Map.fetch!(ranks, rect.density) / last,
          else: 1.0

      rect |> Map.put(:tone, Float.round(tone, 2)) |> Map.delete(:density)
    end
  end

  # **端を丸めてから引き算する**（幅を丸めない）—— 隣り合う区画は同じ境界の値を
  # 持つので、端で丸めれば必ず同じ位置に来て、白い筋が出ない
  defp place(box, west, top, scale) do
    left = place1((box.west - west) * scale)
    right = place1((box.east - west) * scale)
    upper = place1((top - mercator(box.north)) * scale)
    lower = place1((top - mercator(box.south)) * scale)

    # **引き算の結果も丸める。** 丸めた端どうしの差は二進では割り切れず、
    # そのまま書き出すと `0.009000000000014552` のような桁が並ぶ
    # （8,000 区画ぶんで送る量が 1 割ほど増えた）。端との差は 1e-12 で、
    # 隣とのつながりは変わらない
    width = place1(max(right - left, @min_span))
    height = place1(max(lower - upper, @min_span))

    %{
      key: box.key,
      count: box.count,
      # **どこまで見たか**（0 がまだ）。回る巡回が何本かあるので、
      # 「見たか見ていないか」では進み具合が読めない
      stage: stage(box),
      seen_by: Map.get(box, :seen_by) || [],
      by: Map.get(box, :by),
      x: left,
      y: upper,
      width: width,
      height: height,
      # **細いのはどちらか一方でも。** 長く伸びた区画は、細い側が消えると
      # 線にもならずに消える
      tiny: min(width, height) < @tiny_side,
      density: box.count / (width * height)
    }
  end

  # メルカトル（度のまま）。緯度をそのまま使うと、北へ行くほど横に潰れて見える
  defp mercator(lat) do
    radians = lat * :math.pi() / 180.0
    :math.log(:math.tan(:math.pi() / 4 + radians / 2)) * 180.0 / :math.pi()
  end

  defp stage(box), do: Map.get(box, :stage) || 0

  defp place1(value), do: Float.round(value, @places)

  # 海岸線は**押す口ではない**ので、座標は粗くてよい（点の数がそのまま送る量になる）
  defp round1(value), do: Float.round(value, 1)
end
