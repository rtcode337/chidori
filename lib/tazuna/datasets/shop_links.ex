defmodule Tazuna.Datasets.ShopLinks do
  @moduledoc """
  店の説明に添える URL を選びます（travel-log へ書き出すとき）。

  店の URL は 2 か所から来ます —— 地図辞典の公式サイト欄（`extra.website`）と、
  出典（`extra.url`。百科事典の記事か AI が書いたもの）。**どちらも開けるとは限りません**:
  AI は口コミサイトの店の番号を推し量って書くことがあり（1 つ違うと別の店の頁）、
  地図辞典には何年も前に書かれたまま、ドメインごと無くなったものが残ります。

  Chiezo が URL を開いて控えた結果（`GET /v1/collect/{name}/links`）を見て選びます。

  - **開けなかった URL は使わない**（`HTTP 404`・名前を引けない・つながらない…）
  - **断られた URL は使う**（機械の取得を断るサイトでも、人のブラウザでは開ける）
  - **口コミサイトの頁は、題名に店の名前が入っていなければ使わない** —— 別の店の頁です。
    **公式サイトには当てない**（チェーンの公式サイトは会社の名前を題名にする）
  - **まだ確かめていない URL は今までどおり使う**（確かめる前に全部を落とさない）
  - **http から https へ転送される URL は https のほうを書く**（同じホストのときだけ。
    別のホストへの転送は、頁が無くなってトップへ飛ばされたものかもしれない）

  公式サイト欄を先に見ます（店そのものの頁なので）。使えなければ出典を見ます。
  """

  # 口コミサイト（URL が店ごとの頁を指すところ）。題名で店を確かめる
  @review_sites ~w(tabelog.com hotpepper.jp retty.me jalan.net gnavi.co.jp supleks.jp hitosara.com tripadvisor.jp)

  @doc "口コミサイトのホスト（題名で店を確かめるところ）。"
  def review_sites, do: @review_sites

  @doc """
  使う URL（無ければ `""`）。`name` は店の名前、`links` は Chiezo が控えた結果
  （URL → `%{"status", "final_url", "title"}`）。
  """
  def pick(extra, name, links) when is_map(extra) do
    ["website", "url"]
    |> Enum.map(&to_string(Map.get(extra, &1) || ""))
    |> Enum.filter(&String.starts_with?(&1, ["http://", "https://"]))
    |> Enum.find_value("", fn url -> usable(url, name, Map.get(links || %{}, url)) end)
  end

  # 使えるなら書く URL、使えなければ nil
  defp usable(url, _name, nil), do: url

  defp usable(url, name, %{"status" => status} = info) do
    cond do
      not (status == "ok" or String.starts_with?(status, "断られた")) -> nil
      status == "ok" and review_site?(url) and not names_it?(info["title"], name) -> nil
      true -> upgraded(url, info["final_url"])
    end
  end

  defp usable(url, _name, _info), do: url

  @doc "口コミサイトの URL か。"
  def review_site?(url) do
    host = URI.parse(url).host || ""
    Enum.any?(@review_sites, &(host == &1 or String.ends_with?(host, "." <> &1)))
  end

  @doc """
  頁の題名に店の名前が入っているか。**表記の揺れを均してから、名前の 3 文字が続けて
  入っているか**で見ます（題名は「店名 (最寄り駅/ジャンル)」「店名 - 口コミサイト名」の形で、
  名前がそのまま入るとは限らない）。名前が 3 文字に満たなければ丸ごと探します。
  """
  def names_it?(title, name) do
    title = normalize(title)
    name = normalize(name)

    cond do
      name == "" -> true
      String.length(name) < 3 -> String.contains?(title, name)
      true -> name |> chunks() |> Enum.any?(&String.contains?(title, &1))
    end
  end

  defp chunks(name) do
    graphemes = String.graphemes(name)
    for at <- 0..(length(graphemes) - 3), do: graphemes |> Enum.slice(at, 3) |> Enum.join()
  end

  # 全角と半角・大文字と小文字・空白と区切りの記号を揃える
  defp normalize(text) do
    (text || "")
    |> to_string()
    |> :unicode.characters_to_nfkc_binary()
    |> String.downcase()
    |> String.replace(~r/[\s・\-ー'’()（）\[\]「」『』.,、。]/u, "")
  end

  # http から https へ、同じホストのまま転送されたなら https のほうを書く
  defp upgraded("http://" <> _rest = url, "https://" <> _rest2 = final) do
    if same_host?(url, final), do: final, else: url
  end

  defp upgraded(url, _final), do: url

  defp same_host?(a, b), do: bare_host(a) == bare_host(b)

  defp bare_host(url), do: (URI.parse(url).host || "") |> String.replace_prefix("www.", "")
end
