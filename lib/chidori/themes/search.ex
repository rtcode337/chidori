defmodule Chidori.Themes.Search do
  @moduledoc """
  トピックを**名前で探す**（表記ゆれも含めて）。

  **比べるのは均した形です**（`normalize/1`）—— 全角と半角、大文字と小文字、
  カタカナとひらがな、中黒・ハイフン・空白の有無を同じものとして扱います。
  AI が畳んだ言い換え（「同義:<語>」のタグ）も名前と同じに引きます —— 記事の側は
  畳む前の表記のまま残っているので、読む人が覚えている呼び名もそちらのことがあります。

  **本棚の本と興味トピックを突き合わせるのも同じ均し方**です（`near_map/2`）。
  ここで書き分けると、検索では当たるのに本棚では当たらない、が起きます。
  """

  alias Chidori.Themes

  # 読みを変えない区切りの字。**消してから比べる**
  @separators ~r/[\s・･\-‐‑–—_\.／\/]+/u

  @doc "比べるための形に均します。"
  def normalize(text) when is_binary(text) do
    text
    |> :unicode.characters_to_nfkc_binary()
    |> String.downcase()
    |> String.replace(@separators, "")
    |> katakana_to_hiragana()
  end

  def normalize(_text), do: ""

  # カタカナ（ァ〜ヶ）をひらがなへ。長音（ー）はそのまま（読みの一部）
  defp katakana_to_hiragana(text) do
    for <<cp::utf8 <- text>>, into: "" do
      if cp in 0x30A1..0x30F6, do: <<cp - 0x60::utf8>>, else: <<cp::utf8>>
    end
  end

  @doc "そのトピックの名前と言い換え。"
  def names_of(theme), do: [theme.name | Themes.synonyms_of(theme)]

  @doc """
  名前か言い換えに `query` を含むトピック。**近い順**に並べます ——
  均した形がそのまま一致するもの、前から一致するもの、途中に含むもの。
  同じ段なら、いま動いている（直近の件数が多い）トピックを先に。
  """
  def search(themes, query) do
    needle = normalize(query)

    if needle == "" do
      []
    else
      themes
      |> Enum.flat_map(fn theme ->
        case best_rank(theme, needle) do
          nil -> []
          rank -> [{rank, theme}]
        end
      end)
      |> Enum.sort_by(fn {rank, theme} -> {rank, -theme.recent, -theme.docs, theme.name} end)
      |> Enum.map(fn {_rank, theme} -> theme end)
    end
  end

  defp best_rank(theme, needle) do
    theme
    |> names_of()
    |> Enum.map(&normalize/1)
    |> Enum.flat_map(fn name ->
      cond do
        name == needle -> [0]
        String.starts_with?(name, needle) -> [1]
        String.contains?(name, needle) -> [2]
        true -> []
      end
    end)
    |> Enum.min(fn -> nil end)
  end

  @doc """
  **興味トピックに近い語** → その興味トピック。近いのは、興味トピックそのもの・
  その言い換え・**すぐ下の子**（「親:<興味トピック>」の付いたトピック）とその言い換え。
  鍵は均した形です。
  """
  def near_map(themes, interests) do
    by_name = Map.new(themes, &{&1.name, &1})

    for interest <- interests, reduce: %{} do
      acc ->
        own =
          case Map.get(by_name, interest) do
            nil -> [interest]
            theme -> names_of(theme)
          end

        children = for t <- themes, t.parent == interest, name <- names_of(t), do: name

        Enum.reduce(own ++ children, acc, fn name, acc ->
          Map.put_new(acc, normalize(name), interest)
        end)
    end
  end
end
