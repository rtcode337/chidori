defmodule Chidori.News.Report do
  @moduledoc """
  まとめの本文を、レポートとして描ける形に読み分けます。

  **通知へ流す文と、画面に出すレポートは別に書かせます。** 依頼文
  （`Chidori.News.digest_prompt/1`）では冒頭に「要旨」を独立して書かせていて、
  ntfy へ送るのはそこだけです —— レポート全体をプレーンテキストに潰すと、
  見出しも表も箇条書きも区別の付かない塊になります。画面ではその要旨を
  レポートの導入として出すので、**同じ 1 件を、場所に合わせて使い分ける**形です。

  **読めるのは決めた書き方だけです。** 書くのは AI なので、何でも読める必要は
  ありません（依頼文で頼んでいる形に合わせてあります）。

      ## 見出し
      段落。**強調**と[文字つきリンク](https://example.com/1)と裸の URL が使えます
      - 箇条書き
      | 比較軸 | A | B |
      | --- | --- | --- |
      | 速さ | 速い | 遅い |
      > 注記
      出典: https://example.com/1

  **`##` の無い本文も読めます。** 以前のまとめは「空行で区切った塊の 1 行目を
  小見出しにする」形で溜まっていて、**溜まったものは書き換わりません** ——
  古い形を読めなくすると、既に Chiezo にあるまとめが 1 つの塊になって出ます。
  """

  # 要旨の見出し。揺れを受ける —— 依頼文では 1 つに決めていますが、
  # 別の言い方で返ってきたときに要旨が章の 1 つとして埋もれるのは惜しい
  @summary_titles ["要旨", "要約", "サマリー", "サマリ", "概要"]

  @bullets ["- ", "-", "* ", "*", "・"]

  @url ~r{https?://[^\s、。）)\]」]+}u

  # 行の中の飾り。この 3 つだけ（強調・文字つきリンク・裸の URL）
  @inline ~r{(\*\*[^*\n]+\*\*|\[[^\]\n]+\]\(https?://[^)\s]+\)|https?://[^\s、。）)\]」]+)}u

  @typedoc "行の中の一片。描くのは画面、潰すのは通知"
  @type part :: {:text, String.t()} | {:strong, String.t()} | {:link, String.t(), String.t()}

  @typedoc "本文の塊"
  @type block ::
          {:paragraph, [part]}
          | {:list, [[part]]}
          | {:note, [part]}
          | {:table, [[part]], [[[part]]]}
          | {:source, String.t(), String.t() | nil}
          | {:source_note, String.t()}

  @doc """
  本文を、要旨と章に読み分けます。

  返すのは `%{summary: [block], sections: [%{title: String.t(), blocks: [block]}]}` です。
  **要旨は章に混ぜません** —— 画面では導入として別に描き、通知にはここだけを流します。
  """
  def document(body) when is_binary(body) do
    lines = body |> String.split("\n") |> Enum.map(&String.trim/1)

    {lead, sections} =
      if Enum.any?(lines, &heading?/1), do: split_headings(lines), else: split_blank(lines)

    {summary, rest} = Enum.split_with(sections, &(&1.title in @summary_titles))

    %{
      summary: blocks_of(lead ++ Enum.flat_map(summary, & &1.lines)),
      sections: Enum.map(rest, &%{title: &1.title, blocks: blocks_of(&1.lines)})
    }
  end

  def document(_body), do: %{summary: [], sections: []}

  @doc """
  レポートが根拠にした出典。本文に出てきた順で、URL の重複は落とします。

  返るのは `%{url: ..., label: ...}` です。label は AI が書いた記事の見出しで、
  書かれていなければ nil になります。
  """
  def sources(%{summary: summary, sections: sections}) do
    (summary ++ Enum.flat_map(sections, & &1.blocks))
    |> Enum.flat_map(fn
      {:source, url, label} -> [%{url: url, label: label}]
      _block -> []
    end)
    |> Enum.uniq_by(& &1.url)
  end

  def sources(_document), do: []

  @doc """
  読み分けた塊を、飾りのないプレーンテキストにします（通知へ流すのはこれ）。

  **記号は落とします。** ntfy は Markdown として描かないので、`**` を残すと
  読みたい文字の間に `*` が挟まるだけです。**URL はそのまま残します** ——
  ntfy が自分でリンクにするので、文字に差し替えると行き先が読めなくなります。
  """
  def to_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(&text_of/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  def to_text(_blocks), do: ""

  @doc """
  要旨を、通知に流すプレーンテキストにします。**出典の URL は、根拠にした要点の
  すぐ下に `→ URL` で並べます**（要旨の中で要点の次の行に書かれた出典）。

  `to_text/1` と違うのは出典の置き方だけです —— あちらは URL だけの行になるので、
  要点の行と見分けが付かず、どれがどの要点の根拠なのかが読めません。
  """
  def to_notice(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      {:source, url, _label} -> ["→ " <> url]
      block -> text_of(block)
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp text_of({:paragraph, parts}), do: [plain(parts)]
  defp text_of({:note, parts}), do: [plain(parts)]
  defp text_of({:list, items}), do: Enum.map(items, &("・" <> plain(&1)))
  defp text_of({:source, url, _label}), do: [url]
  defp text_of({:source_note, text}), do: [text]

  defp text_of({:table, header, rows}),
    do: Enum.map([header | rows], fn row -> Enum.map_join(row, " / ", &plain/1) end)

  defp plain(parts) do
    Enum.map_join(parts, "", fn
      {:text, text} -> text
      {:strong, text} -> text
      {:link, url, url} -> url
      {:link, url, label} -> label <> " " <> url
    end)
  end

  # 見出しの行。`#` の数は見ません（画面の階層は章の並びで決めます）
  defp heading?(line), do: String.starts_with?(line, "#") and heading_text(line) != ""

  defp heading_text(line), do: line |> String.trim_leading("#") |> String.trim()

  defp split_headings(lines) do
    {lead, rest} = Enum.split_while(lines, &(not heading?(&1)))
    {lead, sections_of(rest)}
  end

  defp sections_of([]), do: []

  defp sections_of([head | rest]) do
    {body, tail} = Enum.split_while(rest, &(not heading?(&1)))
    [%{title: heading_text(head), lines: body} | sections_of(tail)]
  end

  # `##` の無い本文（以前のまとめ）。空行で区切った塊のうち、2 行以上ある塊の
  # 1 行目が小見出しです —— 導入は 1 行だけの塊なので見出しになりません
  defp split_blank(lines) do
    lines
    |> chunks()
    |> Enum.reduce({[], []}, fn
      [head | body], {lead, sections} when body != [] ->
        {lead, sections ++ [%{title: head, lines: body}]}

      chunk, {lead, []} ->
        {lead ++ chunk, []}

      chunk, {lead, sections} ->
        # 見出しの後に来た 1 行だけの塊は、その章の続き（章を増やさない）
        {lead, List.update_at(sections, -1, &%{&1 | lines: &1.lines ++ chunk})}
    end)
  end

  defp chunks(lines) do
    lines
    |> Enum.chunk_by(&(&1 == ""))
    |> Enum.reject(&match?(["" | _], &1))
  end

  defp blocks_of(lines), do: take(lines, [])

  defp take([], acc), do: Enum.reverse(acc)

  defp take([line | rest] = lines, acc) do
    case classify(line) do
      :blank ->
        take(rest, acc)

      :list ->
        {run, tail} = Enum.split_while(lines, &(classify(&1) == :list))
        take(tail, [{:list, Enum.map(run, &inline(list_text(&1)))} | acc])

      :table ->
        {run, tail} = Enum.split_while(lines, &(classify(&1) == :table))
        take(tail, [table(run) | acc])

      :note ->
        take(rest, [{:note, inline(note_text(line))} | acc])

      :source ->
        case source_links(line) do
          # URL を書けなかった出典（元の記事に URL が無いと、こう返ってくる）。
          # 落とさずに出典の見た目で出す —— 本文の段落として並べると、
          # 読み物の途中に断り書きが紛れ込む
          [] -> take(rest, [{:source_note, line} | acc])
          links -> take(rest, Enum.reduce(links, acc, &[{:source, &1.url, &1.label} | &2]))
        end

      :text ->
        {run, tail} = Enum.split_while(lines, &(classify(&1) == :text))
        take(tail, [{:paragraph, inline(join(run))} | acc])
    end
  end

  defp classify(""), do: :blank

  defp classify(line) do
    cond do
      list_item?(line) -> :list
      String.starts_with?(line, "|") -> :table
      String.starts_with?(line, ">") -> :note
      String.starts_with?(line, "出典") -> :source
      source_urls(line) != [] -> :source
      true -> :text
    end
  end

  defp list_item?(line), do: Enum.any?(@bullets, &String.starts_with?(line, &1))

  defp list_text(line) do
    Enum.find_value(@bullets, line, fn bullet ->
      if String.starts_with?(line, bullet), do: String.trim(String.trim_leading(line, bullet))
    end)
  end

  defp note_text(line), do: line |> String.trim_leading(">") |> String.trim()

  # 出典 1 行ぶん。見出しつきで書かれていれば、その見出しを連れて返します
  # —— 裸の URL のままだと、押す前にどこへ行くのか読めません
  defp source_links(line) do
    case Regex.scan(~r{\[([^\]\n]+)\]\((https?://[^)\s]+)\)}u, line) do
      [] -> Enum.map(source_urls(line), &%{url: &1, label: nil})
      found -> Enum.map(found, fn [_all, label, url] -> %{url: url, label: label} end)
    end
  end

  # 「出典: <URL>」の行と、URL だけの行。本文の途中にある URL は出典にしません
  # —— 1 行が URL と、それを指すごく短い言葉だけのときに限ります
  defp source_urls(line) do
    urls =
      @url |> Regex.scan(line) |> Enum.map(&(&1 |> List.first() |> String.trim_trailing(".")))

    rest =
      urls
      |> Enum.reduce(line, &String.replace(&2, &1, ""))
      |> String.replace(~r{[-*・,、:：\s\]\[()（）]}u, "")

    if urls != [] and String.length(rest) <= 4, do: urls, else: []
  end

  defp table(rows) do
    cells =
      rows
      |> Enum.map(&row_cells/1)
      |> Enum.reject(&separator?/1)

    case cells do
      [] -> {:paragraph, []}
      [header | body] -> {:table, row_parts(header), Enum.map(body, &row_parts/1)}
    end
  end

  defp row_cells(line) do
    line
    |> String.trim()
    |> String.trim("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  defp row_parts(cells), do: Enum.map(cells, &inline/1)

  # 見出しと中身を仕切る行（`| --- | --- |`）。表の行ではあるが、描くものは無い
  defp separator?(cells), do: cells != [] and Enum.all?(cells, &(&1 =~ ~r{^:?-+:?$}))

  # 続けて書かれた行は 1 つの段落にします。日本語は詰めて繋ぎ、英数字どうしの
  # 境目にだけ空白を入れます（詰めて語がくっつくのはそこだけ）
  defp join([]), do: ""

  defp join([first | rest]), do: Enum.reduce(rest, first, &join_pair(&2, &1))

  defp join_pair(left, right) do
    if ascii?(String.last(left)) and ascii?(String.first(right)),
      do: left <> " " <> right,
      else: left <> right
  end

  defp ascii?(nil), do: false
  defp ascii?(char), do: char =~ ~r{^[A-Za-z0-9,.;:)\]"']$}

  @doc false
  # 行の中を、描ける一片に割ります。素の HTML は受け付けません ——
  # 書くのは AI なので、そのまま描かせる道は作らない（画面は一片ずつ描きます）
  def inline(text) when is_binary(text) do
    @inline
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(&segment/1)
  end

  def inline(_text), do: []

  defp segment(token) do
    cond do
      strong = Regex.run(~r{^\*\*([^*]+)\*\*$}u, token) ->
        {:strong, Enum.at(strong, 1)}

      link = Regex.run(~r{^\[([^\]]+)\]\((https?://[^)\s]+)\)$}u, token) ->
        {:link, Enum.at(link, 2), Enum.at(link, 1)}

      Regex.match?(~r{^https?://}, token) ->
        url = String.trim_trailing(token, ".")
        {:link, url, url}

      true ->
        {:text, token}
    end
  end
end
