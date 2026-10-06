defmodule Tazuna.CollectDrift do
  @moduledoc """
  Chiezo に置いてある収集の設定が、**Chidori がいま送るはずの設定と違うところ**
  （設定ページの「Chiezo 収集」の表に出す）。

  依頼文や絵の拾い方を Chidori で直しても、各画面の「収集の設定を更新」を押すまでは
  Chiezo に届かない。届いていないことは画面のどこにも出ないので、直したつもりの
  ものが古いまま回り続ける —— ここで突き合わせて、違う項目を名前で出す。

  **比べるのは Chidori が送る項目だけ**（Chiezo が持つ進み具合や前回の結果は見ない）。
  入れ子の設定も、Chidori が書いた鍵だけを見る —— Chiezo は受け取った設定に既定の
  鍵を足して返すので、丸ごと比べると全部が「違う」になる。

  **Chiezo が返さない鍵も比べません。** Chiezo が知らない鍵は受け取っても黙って
  捨てられる（巡回ごとの `web`、配信元の `since` など）ので、比べると「送り直しても
  消えない違い」が出続ける。

  **頼む相手（相手・モデル・ワーカー）は比べません**。表の欄で巡回ごとに選び直せる
  もので、Chidori の定義は既定の相手しか持たない。止めた・動かしたも比べない
  （Chiezo の管理画面で決めるもの）。
  """

  # 比べない鍵。名前は突き合わせに使ったもの、相手は表の欄で選ぶもの、
  # 動かすかどうかは Chiezo の管理画面で決めるもの
  @ignored ~w(name requested_by backend model effort worker enabled)

  # 画面に出す名前（無いものは鍵のまま出す）
  @labels %{
    "description" => "説明",
    "prompt" => "依頼文",
    "interval_minutes" => "間隔",
    "kind" => "種類",
    "feed" => "配信元",
    "extract" => "名簿の引き方",
    "thumbs" => "絵の拾い方",
    "keep_days" => "保つ日数",
    "partition" => "区画",
    "material" => "材料",
    "verify_tags" => "タグの確かめ方",
    "web" => "web 検索",
    "locked_doubt_tag" => "固定した店を消さずに付けるタグ",
    "after" => "待つ巡回",
    "only_new" => "足すだけにするか",
    "use_feed" => "配信で引くか",
    "use_extract" => "名簿で引くか",
    "use_pihole" => "Pi-hole で引くか",
    "by_hand" => "手で起こすか",
    "by_caller" => "自動で回すか",
    "on_demand" => "頼まれたときだけ回すか",
    "unreviewed_per_run" => "1 回に見る数",
    "unreviewed_by" => "見る順",
    "partitions_per_run" => "1 回に見る区画の数"
  }

  @doc """
  違う項目の名前（`["依頼文", "巡回「整理」の依頼文", …]`）。同じなら空。

  `expected` は Chidori が送る設定（アトムの鍵でも文字列の鍵でもよい）、`actual` は
  Chiezo の `GET /v1/collect` が返す 1 件。
  """
  def differences(expected, actual) when is_map(expected) and is_map(actual) do
    want = plain(expected)

    top =
      for {key, value} <- want,
          key not in @ignored and key != "sweeps",
          Map.has_key?(actual, key),
          not same?(key, value, actual[key]),
          do: label(key)

    top ++ sweep_differences(want["sweeps"], actual["sweeps"])
  end

  def differences(_expected, _actual), do: []

  # 巡回は名前で突き合わせる。**Chiezo にだけある巡回も出す**（Chidori が外した巡回が
  # 残っていると、外したつもりの仕事が回り続ける）
  defp sweep_differences(wanted, had) when is_list(wanted) do
    had = if is_list(had), do: had, else: []
    by_name = Map.new(had, &{&1["name"], &1})
    names = MapSet.new(wanted, & &1["name"])

    Enum.flat_map(wanted, fn sweep ->
      case by_name[sweep["name"]] do
        nil ->
          ["巡回「#{sweep["name"]}」が Chiezo にありません"]

        present ->
          for {key, value} <- sweep,
              key not in @ignored,
              Map.has_key?(present, key),
              not same?(key, value, present[key]),
              do: "巡回「#{sweep["name"]}」の#{label(key)}"
      end
    end) ++
      for sweep <- had,
          not MapSet.member?(names, sweep["name"]),
          do: "Chiezo にだけある巡回「#{sweep["name"]}」"
  end

  defp sweep_differences(_wanted, _had), do: []

  # 1 つの値が同じか。**Chidori が書いた側に合わせて見る**
  # 絵の拾い方の `true` は、Chiezo では「どのページも読まない」形で返る
  defp same?("thumbs", true, had), do: same?("thumbs", %{"pages_from" => []}, had)
  defp same?(_key, want, had), do: same?(want, had)

  defp same?(want, had) when is_map(want) and is_map(had),
    do:
      Enum.all?(want, fn {key, value} ->
        not Map.has_key?(had, key) or same?(value, had[key])
      end)

  defp same?(want, had) when is_list(want) and is_list(had) do
    cond do
      length(want) != length(had) -> false
      Enum.all?(want ++ had, &scalar?/1) -> Enum.sort(want) == Enum.sort(had)
      true -> want |> Enum.zip(had) |> Enum.all?(fn {w, h} -> same?(w, h) end)
    end
  end

  defp same?(want, had) when is_binary(want) and is_binary(had),
    do: String.trim(want) == String.trim(had)

  defp same?(want, had) when is_number(want) and is_number(had), do: want == had
  defp same?(want, had), do: want == had or (blank?(want) and blank?(had))

  defp scalar?(value), do: not is_map(value) and not is_list(value)

  # 「書いていない」と同じ値（Chiezo は書かなかった鍵を既定で返すことがある）
  defp blank?(value), do: value in [nil, false, 0, "", [], %{}]

  # 鍵を文字列に揃える（Chiezo の返りと同じ形にして比べる）
  defp plain(attrs), do: attrs |> Jason.encode!() |> Jason.decode!()

  defp label(key), do: Map.get(@labels, key, key)
end
