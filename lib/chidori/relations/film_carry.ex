defmodule Chidori.Relations.FilmCarry do
  @moduledoc """
  **最新情報の映画を、映画のつながりの図へ引き継ぐ**ところ。

  最新情報の映画（`chidori_movies`）は上映が終わると整理の回が消します（公開から 60 日）。
  図（`chidori_films`）は名作を Wikipedia の分類から引いた名簿なので、新しい作品は入りません。
  そのままだと、**見た映画がどちらにも残らない**。そこで、消える前に図へ足させます。

  ## 何を引き継ぐか

  - **見た記録を付けた作品**（`Chidori.Relations.Marks` の `movies`。最新情報で付けたものも、
    図の画面から足したものも同じ置き場）
  - **注目度が高く、公開された作品**（`注目度:高` で公開日が今日以前）

  全部ではないのは、最新情報が全国公開の作品を全部集めているため（年に数百本）。
  入れると図が知られていない作品で埋まります。

  ## どう足すか

  図の収集へ割り込みを 1 回頼み、AI に足させます（`Chidori.Relations.Films.carry_prompt/1`）。
  Chiezo の収集へは AI を通してしか書けず、監督・主演も AI が埋める項目なので、
  同じ回でまとめて書かせます。**足した作品は `記録:<元の見出し>` を持つ**ので、
  済んだかはそのタグで数えます（`carried/1`）。

  ## 時計

  **1 時間ごとに起き、まだのものがあれば 1 日 1 回まで頼みます。** 取り込みが混んで
  断られたら（`:chiezo_busy`）、次に起きたときにまた試します。**止めた収集には頼みません**
  （割り込みは止めた収集を断る。時計は人が押した 1 回ではないので `by_hand` で囲まない）。
  図の画面から足したときだけは、押した人の 1 回としてすぐ頼みます（`carry_now/1`）。
  """

  use GenServer

  require Logger

  alias Chidori.Chiezo
  alias Chidori.News.Events
  alias Chidori.News.Movies
  alias Chidori.Relations.Films
  alias Chidori.Relations.Marks

  @tick_ms 60 * 60 * 1000
  # 起動直後は待つ（立ち上げの最中に Chiezo を叩かない）
  @first_tick_ms 10 * 60 * 1000
  @min_interval_hours 24
  # 1 回に頼む数。**AI が 1 回で返し切れる数**に抑える（残りは次の日）
  @batch 20
  # 似た見出しとして見せる、図に既にある作品の上限（割り込みで名指しできる数）
  @max_named 50

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :tick, @first_tick_ms)
    {:ok, %{last_at: nil}}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, maybe_carry(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp maybe_carry(%{last_at: last} = state) do
    due? =
      is_nil(last) or DateTime.diff(DateTime.utc_now(), last, :hour) >= @min_interval_hours

    with true <- due?,
         base when is_binary(base) <- Chiezo.base_url(),
         {:ok, items} when items != [] <- pending(base),
         :ok <- carry(base, items) do
      %{state | last_at: DateTime.utc_now()}
    else
      {:error, reason} ->
        Logger.info("映画の引き継ぎを頼めませんでした: #{inspect(reason)}")
        state

      _nothing ->
        state
    end
  end

  @doc """
  **図の画面から足した作品を、すぐ頼みます**（押した人の 1 回。止めた収集でも走る）。
  `{:ok, 頼んだ数}` か `{:error, 理由}`。
  """
  def carry_now(titles) when is_list(titles) do
    with base when is_binary(base) <- Chiezo.base_url(),
         {:ok, items} <- items_for(base, titles),
         :ok <- Chiezo.by_hand(fn -> carry(base, items) end) do
      {:ok, length(items)}
    else
      nil -> {:error, :chiezo_not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "まだ図へ引き継いでいない作品（`%{title, date, summary, url}`）。"
  def pending(base) do
    with {:ok, carried} <- carried(base),
         {:ok, released} <- released_high(base) do
      by_title = Map.new(released, &{&1.title, &1})
      marked = Map.keys(Marks.for_view(Films.mark_view()))

      items =
        (Map.keys(by_title) ++ marked)
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(carried, &1))
        |> Enum.sort()
        |> Enum.take(@batch)
        |> Enum.map(&(Map.get(by_title, &1) || %{title: &1}))

      {:ok, items}
    end
  end

  # 名指しした見出しを、最新情報に残っていればその中身つきで
  defp items_for(base, titles) do
    known =
      case released_high(base) do
        {:ok, entries} -> Map.new(entries, &{&1.title, &1})
        {:error, _reason} -> %{}
      end

    {:ok, Enum.map(titles, &(Map.get(known, &1) || %{title: &1}))}
  end

  @doc """
  頼みます。**図に似た見出しの作品があれば名指しして見せます**（AI が二重に足さないように。
  「〇〇」と「〇〇 (映画)」は前方一致で拾える）。
  """
  def carry(_base, []), do: :ok

  def carry(base, items) do
    named =
      items
      |> Enum.flat_map(&similar(base, &1.title))
      |> Enum.uniq()
      |> Enum.take(@max_named)

    Chiezo.focus(
      base,
      Films.collection(),
      "最新情報の映画と、見た記録を付けた映画を、図に足してください: " <>
        Enum.map_join(items, "、", & &1.title),
      named,
      Chidori.SweepNames.tidy(),
      nil,
      Films.carry_prompt(items)
    )
  end

  # 図にある作品のうち、見出しが同じ語で始まるもの（最大 3 つ）
  defp similar(base, title) do
    query = URI.encode_query(%{"prefix" => title, "limit" => 3})

    with {:ok, %{status: 200, body: body}} <-
           Chiezo.get(base <> "/v1/" <> Films.collection() <> "/titles?" <> query),
         {:ok, %{"titles" => titles}} when is_list(titles) <- Jason.decode(body) do
      Enum.flat_map(titles, fn
        %{"title" => t} when is_binary(t) -> [t]
        t when is_binary(t) -> [t]
        _other -> []
      end)
    else
      _ -> []
    end
  end

  @doc "図が既に持っている `記録:` の見出し（引き継ぎ済み）。"
  def carried(base) do
    query = URI.encode_query(%{"prefix" => Films.record_tag() <> ":", "limit" => 5000})

    case Chiezo.get(base <> "/v1/" <> Films.collection() <> "/tags?" <> query) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"tags" => tags}} when is_list(tags) ->
            {:ok,
             MapSet.new(tags, fn %{"tag" => tag} ->
               String.replace_prefix(tag, Films.record_tag() <> ":", "")
             end)}

          _other ->
            {:error, :chiezo_unexpected_body}
        end

      # 図の収集がまだ無い（頼んでいない）なら、引き継ぐ先も無い
      {:ok, %{status: 404}} ->
        {:error, :not_requested}

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  # 注目度が高く、公開された作品（公開日が今日以前）
  defp released_high(base) do
    collection =
      Enum.find_value(Chidori.Topics.list(), &(&1[:works] == Movies && &1.collection))

    with {:ok, entries} <-
           Events.fetch_tagged(base, collection, Events.attention_tag(:high),
             date_tag: Movies.date_tag()
           ) do
      today = Chidori.Jst.today()
      {:ok, Enum.filter(entries, &(Date.compare(&1.date, today) != :gt))}
    end
  end
end
