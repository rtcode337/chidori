defmodule Chidori.News.Showtimes do
  @moduledoc """
  お気に入りの映画館で、選んだ映画を**指定の時刻より後に**上映する回を調べるところ
  （映画の画面の「上映スケジュール」）。

  ## AI に web で調べさせる

  上映時刻を配っている API は無く、映画館のサイトの頁を機械で読み取るのは壊れやすく
  相手の負担にもなるので、**押したときだけ** Chiezo 越しに AI へ web で調べさせます
  （`/v1/ai/complete` の `web: true`）。押すたびに AI の枠を 1 回使い、答えるまで
  数十秒〜数分かかります。**頼める相手は web を持つ相手だけ**（`backends/1`）で、
  画面で選びます。

  ## 答えは JSON で返させる

  館ごとの表にして出すので、決めた形の JSON で返させて読みます（`parse/1`）。
  **確かめられなかった館は「分からない」と返させます** —— 上映時刻を推し量って
  書かれると、それを信じて映画館へ行くことになる。館ごとに出どころの頁の URL も返させ、
  画面に添えます（確かめるのは人）。JSON が読めなければ、答えの文をそのまま出します。
  """

  alias Chidori.Chiezo
  alias Chidori.Jst

  # 答えを待つ上限（CLI ブリッジ越しの相手は web で何頁も当たるので長くかかる）
  @timeout 10 * 60 * 1000

  @doc """
  上映時刻を頼める相手（web を持つ相手だけ。ワーカーは `/v1/ai/complete` に渡せないので外す）。
  `{:ok, [%{id, label}]}` か `{:error, 理由}`。
  """
  def backends(base) do
    case Chiezo.get(base <> "/v1/ai/backends") do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"backends" => list}} when is_list(list) ->
            {:ok,
             for(
               %{"id" => id, "label" => label} = b <- list,
               b["web"] == true and b["kind"] != "worker",
               do: %{id: id, label: label}
             )}

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
  調べます。`theaters` はお気に入りの館（`Chidori.News.Theaters.favorites/0` の形）、
  `date` は日付、`from` は `{時, 分}`（その時刻より後に始まる回だけ）。
  `{:ok, %{theaters: [館ごとの結果], raw: 答えの文}}` か `{:error, 理由}`。
  """
  def ask(base, backend, title, theaters, %Date{} = date, {_h, _m} = from) do
    body =
      Jason.encode!(%{
        backend: backend,
        web: true,
        requested_by: "chidori",
        messages: [%{role: "user", content: prompt(title, theaters, date, from)}]
      })

    case Chiezo.post(base <> "/v1/ai/complete", body, @timeout) do
      {:ok, %{status: 200, body: raw}} ->
        case Jason.decode(raw) do
          {:ok, %{"content" => content}} when is_binary(content) ->
            {:ok, %{theaters: parse(content), raw: content}}

          _other ->
            {:error, :chiezo_unexpected_body}
        end

      {:ok, %{status: status, body: raw}} ->
        {:error, {:chiezo_refused, status, Chiezo.reason_of(raw)}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  @doc "頼む文。館は名前・住所・サイトで名指しする（同じ名前の別の館と取り違えないように）。"
  def prompt(title, theaters, %Date{} = date, {hour, minute}) do
    at = Chidori.Notify.Setting.format({hour, minute})

    lines =
      Enum.map_join(theaters, "\n", fn t ->
        facts = [t[:address], t[:website]] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" / ")
        if facts == "", do: "- #{t.name}", else: "- #{t.name}（#{facts}）"
      end)

    """
    映画「#{title}」の上映スケジュールを調べてください。

    - 日付: #{Date.to_iso8601(date)}（#{Jst.weekday_label(date)}）
    - #{at} より後に始まる回だけ
    - 映画館（この館だけ。ほかの館は調べない）:
    #{lines}

    **各映画館の公式サイトの上映スケジュールの頁か、映画館の予約サイト**で確かめてください。
    **確かめられなかった館は、時刻を推し量らずに found を false にしてください**
    （その時刻を信じて映画館へ行くことになります）。上映していない館も found を false にし、
    note にそう書いてください。

    答えは次の JSON だけを返してください（前後に文を書かない）。
    {"theaters": [
      {"name": "映画館の名前（上に書いた表記のまま）",
       "found": true,
       "showings": [{"start": "HH:MM", "end": "HH:MM", "format": "字幕・吹替・IMAX など（分からなければ空）"}],
       "source": "確かめた頁の URL",
       "note": "補足（前売りの状況・満席など。無ければ空）"}
    ]}
    """
  end

  @doc """
  答えを読みます（館ごとに `%{name, found, showings: [%{start, end, format}], source, note}`）。
  答えの中の最初の `{` から最後の `}` までを JSON として読む（前後に文が付いても読めるように）。
  読めなければ空。
  """
  def parse(content) when is_binary(content) do
    with [json] <- Regex.run(~r/\{.*\}/su, content),
         {:ok, %{"theaters" => list}} when is_list(list) <- Jason.decode(json) do
      Enum.flat_map(list, &to_result/1)
    else
      _other -> []
    end
  end

  def parse(_content), do: []

  defp to_result(%{"name" => name} = item) when is_binary(name) do
    showings =
      for %{"start" => start} = s <- List.wrap(item["showings"]),
          is_binary(start),
          do: %{start: start, end: text(s["end"]), format: text(s["format"])}

    [
      %{
        name: name,
        found: item["found"] == true and showings != [],
        showings: Enum.sort_by(showings, & &1.start),
        source: Chidori.SafeUrl.href(item["source"]),
        note: text(item["note"])
      }
    ]
  end

  defp to_result(_item), do: []

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""
end
