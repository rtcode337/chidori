defmodule Antenna.Selection do
  @moduledoc """
  溜まったものから、重要なものを AI に選ばせるところ。

  **集めるのは Chiezo、選ぶのは antenna** です。何が重要かは利用者の関心で決まるので、
  Chiezo には持たせません（あちらは判断や好みを持たない、という線）。

  **選ぶたびに AI を呼ばない。** 画面を開くたびに呼ぶと枠を食い切るので、結果は
  持っておき、新しく溜まったものが増えたときだけ呼び直します。

  **候補は antenna が渡し、掘り下げは AI に任せます。** 直近のものを候補として渡し、
  判断に迷ったら Chiezo を引いて確かめてよい、と伝えます。候補の件数に上限は
  掛かりますが、背景や裏取りは AI が好きなだけ引けます。
  """

  alias Antenna.Chiezo

  # 1 回に渡す候補の上限。Chiezo 側の `samples` の上限が 50
  @max_candidates 50
  # 選ばせる件数。多すぎると「重要なもの」の意味が薄れる
  @max_picks 6
  # AI に web を歩かせないので、会話より短くてよい
  @timeout 300_000

  @system """
  あなたは、溜まった情報から「いま読むべきもの」を選ぶ編集者です。
  渡された候補の中からだけ選び、候補に無いものを作らないでください。
  判断に迷ったら、繋がっている Chiezo の道具で調べて確かめてかまいません。
  応答は JSON だけにしてください。前置き・説明・コードブロックの記号は付けません。
  形式: {"picks":[{"title":"候補の見出しをそのまま","why":"なぜ今読むべきか。1〜2文"}]}
  title は渡された候補の見出しと**一字一句同じ**にしてください（突き合わせに使います）。
  """

  @doc """
  候補を選ばせます。話題の関心と、選ぶ相手の設定を使います。

  返すのは `{:ok, [%{title:, why:}]}`。**候補と突き合わせて、無い見出しは落とします**
  —— AI が作った見出しを「選ばれたもの」として出すと、押しても中身がありません。
  """
  def pick(base_url, topic, candidates) when is_list(candidates) do
    titles = candidates |> Enum.map(& &1.title) |> MapSet.new()

    with {:ok, content} <- ask(base_url, topic, Enum.take(candidates, @max_candidates)),
         {:ok, picks} <- parse(content) do
      {:ok,
       picks
       |> Enum.filter(&MapSet.member?(titles, &1.title))
       |> Enum.uniq_by(& &1.title)
       |> Enum.take(@max_picks)}
    end
  end

  defp ask(base_url, topic, candidates) do
    payload =
      Jason.encode!(
        %{
          backend: topic.select_backend,
          model: topic.select_model,
          effort: topic.select_effort,
          # 候補は渡してあるので、web を開ける必要は無い（そのぶん速い）
          web: false,
          messages: [
            %{role: "system", content: @system},
            %{role: "user", content: user_prompt(topic, candidates)}
          ]
        }
        |> Enum.reject(fn {_k, v} -> v == nil end)
        |> Map.new()
      )

    case Chiezo.post(base_url <> "/v1/ai/complete", payload, @timeout) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"content" => content}} when is_binary(content) -> {:ok, content}
          _ -> {:error, :chiezo_unexpected_body}
        end

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  @doc false
  def user_prompt(topic, candidates) do
    list =
      candidates
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {c, i} ->
        "#{i}. #{c.title}" <> if(c[:summary], do: "\n   #{c.summary}", else: "")
      end)

    """
    関心: #{String.trim(topic.interest || "")}

    候補（この中からだけ選ぶ）:
    #{list}

    上のうち、いま読むべきものを最大#{@max_picks}件、重要な順に選んでください。
    どれも読むほどではないなら、無理に選ばず picks を空にしてください。
    """
  end

  @doc false
  # 応答から選ばれたものを取り出す。コードブロックで囲まれても拾えるようにする
  def parse(content) when is_binary(content) do
    stripped = String.replace(content, ~r/```(?:json)?/, "")

    with [_ | _] = candidates <- json_candidates(stripped),
         {:ok, %{"picks" => picks}} when is_list(picks) <-
           Enum.find_value(candidates, {:error, :invalid}, &decode(&1)) do
      {:ok,
       Enum.flat_map(picks, fn
         %{"title" => title} = pick when is_binary(title) ->
           case String.trim(title) do
             "" -> []
             t -> [%{title: t, why: trimmed(pick["why"])}]
           end

         _ ->
           []
       end)}
    else
      _ -> {:error, :invalid_ai_response}
    end
  end

  def parse(_content), do: {:error, :invalid_ai_response}

  defp json_candidates(text) do
    trimmed = String.trim(text)

    [trimmed, between_braces(trimmed)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp between_braces(text) do
    case Regex.run(~r/\{.*\}/s, text) do
      [json] -> json
      _ -> nil
    end
  end

  defp decode(candidate) do
    case Jason.decode(candidate) do
      {:ok, %{"picks" => _} = payload} -> {:ok, payload}
      _ -> nil
    end
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_value), do: nil
end
