defmodule Tazuna.News.AiDigests do
  @moduledoc """
  **別のアプリの AI が書いた要約**を、書き手ごとに最新の 1 本ずつ読む（`Tazuna.Topics` の
  `digest_from`）。

  市況ニュースの要約は tazuna では作らない。売買提案のアプリ（売買提案のアプリ）の参加者が、それぞれ
  この話題の記事を読んで自分の売買のための要約を書き、Chiezo の収集 `pta_market` に溜めている
  （1 件 = 1 人 × 1 回。タグ `まとめ` と `担当:<参加者>`）。同じ記事から tazuna も 1 本書くと、
  AI に何が渡ったのかと人が読むものが別になる —— だから人も同じものを読む。

  本文の最後には書き手が目を付けた銘柄の JSON（`notable_codes`）が付いている。読み物の
  描画（`Tazuna.News.Report`）はコードの囲みを読めないので、渡す前に切り落とす。
  """

  alias Tazuna.Chiezo
  alias Tazuna.Jst

  # 1 人 1 日 2 本、14 日ぶん溜まる（数人ぶんでも収まる）
  @limit 200

  @doc """
  書き手ごとの最新の要約。`{:ok, [%{author:, title:, at:, body:}]}`（書き手の名前順）。
  収集がまだ無ければ空（404）。
  """
  def latest(base, source) do
    query =
      URI.encode_query(%{
        "tag" => "まとめ",
        "limit" => @limit,
        "fields" => "title,tags,body,updated_at"
      })

    case Chiezo.get(base <> "/v1/" <> URI.encode(source) <> "/filter?" <> query) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"results" => docs}} when is_list(docs) -> {:ok, pick_latest(docs)}
          _other -> {:error, :chiezo_unexpected_body}
        end

      {:ok, %{status: 404}} ->
        {:ok, []}

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  @doc """
  文書の並びから、書き手（`担当:<名前>` のタグ）ごとに最新の 1 本を選ぶ。
  **並びは Chiezo の返した順に頼らない**（filter は点数順で返る）。書き手の無いものは捨てる。
  """
  def pick_latest(docs) do
    docs
    |> Enum.flat_map(fn doc ->
      case author(doc) do
        nil -> []
        name -> [{name, doc}]
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {name, list} ->
      doc = Enum.max_by(list, &(&1["updated_at"] || ""))

      %{
        author: name,
        title: doc["title"] || "",
        at: Jst.format(doc["updated_at"]),
        body: strip_codes(doc["body"] || "")
      }
    end)
    |> Enum.sort_by(& &1.author)
  end

  defp author(%{"tags" => tags}) when is_list(tags) do
    Enum.find_value(tags, fn
      "担当:" <> name when name != "" -> name
      _other -> nil
    end)
  end

  defp author(_doc), do: nil

  @doc """
  本文の最後の、目を付けた銘柄の JSON を切り落とす（```json で囲んであってもなくても）。
  """
  def strip_codes(body) do
    cut =
      cond do
        match = last_index(body, "```json") -> match
        match = last_match(body, ~r/\{\s*"notable_codes"\s*:/) -> match
        true -> nil
      end

    if cut,
      do: body |> binary_part(0, cut) |> String.trim_trailing(),
      else: String.trim_trailing(body)
  end

  defp last_index(body, needle) do
    case :binary.matches(body, needle) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp last_match(body, regex) do
    case Regex.scan(regex, body, return: :index) do
      [] -> nil
      matches -> matches |> List.last() |> hd() |> elem(0)
    end
  end
end
