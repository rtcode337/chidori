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

  **決めた時刻（JST）に頼みます**（収集の画面（`/collect`）の表、映画の図の
  「最新情報からの引き継ぎ」の行。`Chidori.Relations.CarrySetting`）。**時刻を書いて
  いなければ頼みません（既定）** —— 時計は Chidori の中にあるので、本番とテストの 2 つを
  立てていると同じ割り込みが二重に出る。時刻を書いた Chidori だけが頼む。

  5 分ごとに起きて、予定を過ぎた回があれば頼みます（まだのものが無ければ頼まず、
  そう記録する）。**過ぎて 30 分までの回だけ拾います**（要約の時計と同じ。夜中に立ち上げた
  拍子に朝の回が走らないように）。**頼めなかった回は、次の予定まで起きるたびに試し直します**
  （取り込みが混んで断られるのは普通にある。断られた回は AI を使っていない）。
  **止めた収集には頼みません**（割り込みは止めた収集を断る。時計は人が押した 1 回では
  ないので `by_hand` で囲まない）。図の画面から足したときだけは、押した人の 1 回として
  すぐ頼みます（`carry_now/2`）。
  """

  use GenServer

  require Logger

  alias Chidori.Chiezo
  alias Chidori.News.Events
  alias Chidori.News.Movies
  alias Chidori.Relations.CarrySetting
  alias Chidori.Relations.Films
  alias Chidori.Relations.Marks

  @tick_ms 5 * 60 * 1000
  # 起動直後は少し待つ（立ち上げの最中に Chiezo を叩かない）
  @first_tick_ms 60 * 1000
  # 予定を過ぎてから拾う長さ（要約の時計と同じ）
  @grace_seconds 30 * 60
  # 似た見出しとして見せる、図に既にある作品の上限（割り込みで名指しできる数）
  @max_named 50

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :tick, @first_tick_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    maybe_carry(DateTime.utc_now())
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp maybe_carry(now) do
    setting = CarrySetting.get()

    with true <- due?(setting, now),
         base when is_binary(base) <- Chiezo.base_url(),
         {:ok, items} <- pending(base, setting.batch) do
      titles = Enum.map(items, & &1.title)

      if items == [] do
        CarrySetting.record("時計", [], :nothing)
      else
        result = carry(base, items)
        # 数えるのは頼めた回だけ（断られた回は AI を使っていない）
        if result == :ok, do: count(base, titles)
        CarrySetting.record("時計", titles, reason_text(result))
      end
    else
      {:error, reason} ->
        Logger.info("映画の引き継ぎを頼めませんでした: #{inspect(reason)}")
        CarrySetting.record("時計", [], reason_text({:error, reason}))

      _nothing ->
        :ok
    end
  end

  @doc false
  # 頼む番か。直近の予定（今以前で最も新しい時刻）を過ぎて、まだ時計が頼みに
  # 行っていなければ 30 分まで拾う。頼みに行って済まなかった回は、次の予定まで試し直す
  def due?(%CarrySetting{} = setting, now) do
    case last_slot(setting, now) do
      nil ->
        false

      slot ->
        if is_nil(setting.clock_at) or DateTime.compare(setting.clock_at, slot) == :lt,
          do: DateTime.diff(now, slot, :second) <= @grace_seconds,
          else: not setting.clock_ok
    end
  end

  @doc """
  次の予定。`{:at, UTC の時刻}`・`:retry`（済まなかった回を試し直している）・
  `:off`（時刻を決めていない）。**まだのものが無ければ頼まない**ので、その時刻に
  必ず頼むわけではない（確かめに行く時刻）。
  """
  def next_at(%CarrySetting{} = setting, now \\ DateTime.utc_now()) do
    slot = last_slot(setting, now)

    cond do
      CarrySetting.times(setting) == [] ->
        :off

      slot && setting.clock_at && DateTime.compare(setting.clock_at, slot) != :lt &&
          not setting.clock_ok ->
        :retry

      true ->
        {:at, next_slot(setting, now)}
    end
  end

  @doc "次の予定の一言（画面に出す。関連図と設定ページで同じ書き方にする）。"
  def next_text({:at, %DateTime{} = at}), do: Chidori.Jst.format(at)
  def next_text(:retry), do: "前の回が済まなかったので、5 分ごとに試し直しています"
  def next_text(:off), do: "時刻を決めていないので、頼みません"
  def next_text(_other), do: "—"

  # 今以前で最も新しい予定（今日と昨日の JST から）。時刻が無ければ nil
  defp last_slot(setting, now) do
    setting
    |> slots(now, [-1, 0])
    |> Enum.filter(&(DateTime.compare(&1, now) != :gt))
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp next_slot(setting, now) do
    setting
    |> slots(now, [0, 1])
    |> Enum.filter(&(DateTime.compare(&1, now) == :gt))
    |> Enum.min(DateTime, fn -> nil end)
  end

  defp slots(setting, now, days) do
    today = Chidori.Jst.today(now)

    for offset <- days,
        {hour, minute} <- CarrySetting.times(setting),
        do: Chidori.Jst.utc_at(Date.add(today, offset), hour, minute)
  end

  @doc """
  **図の画面から足した作品を、すぐ頼みます**（押した人の 1 回。止めた収集でも走る）。
  `hint` は人が添えた手がかり（公開年・監督など。空でもよい）。
  `{:ok, 頼んだ数}` か `{:error, 理由}`。
  """
  def carry_now(titles, hint \\ "") when is_list(titles) do
    with base when is_binary(base) <- Chiezo.base_url(),
         {:ok, items} <- items_for(base, titles, hint) do
      result = Chiezo.by_hand(fn -> carry(base, items) end)
      if result == :ok, do: count(base, titles)
      CarrySetting.record("画面", titles, reason_text(result))

      case result do
        :ok -> {:ok, length(items)}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :chiezo_not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  **時計を待たずに、いま 1 回頼みます**（画面の「いま頼む」。押した人の 1 回なので、
  止めている収集でも走る）。頼む作品と数は時計の回と同じ（`pending/2` の上から
  1 回に頼む数まで。何度頼んでも載らない作品は外す）。時計の記録（`clock_at`）は
  動かさないので、その日の時計の回は飛ばない。

  `{:ok, 頼んだ数}`（無ければ 0）か `{:error, 理由}`。
  """
  def carry_batch_now do
    with base when is_binary(base) <- Chiezo.base_url(),
         {:ok, items} <- pending(base, CarrySetting.get().batch) do
      titles = Enum.map(items, & &1.title)

      if items == [] do
        CarrySetting.record("画面", [], :nothing)
        {:ok, 0}
      else
        result = Chiezo.by_hand(fn -> carry(base, items) end)
        if result == :ok, do: count(base, titles)
        CarrySetting.record("画面", titles, reason_text(result))

        case result do
          :ok -> {:ok, length(items)}
          {:error, reason} -> {:error, reason}
        end
      end
    else
      nil -> {:error, :chiezo_not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  # 頼んだ回数を数える。ついでに、載った作品の回数を消す（読めなければ消さないだけ）
  defp count(base, titles) do
    carried =
      case carried(base) do
        {:ok, carried} -> carried
        {:error, _reason} -> MapSet.new()
      end

    CarrySetting.count_attempts(titles, carried)
  end

  defp reason_text(:ok), do: :ok
  defp reason_text({:error, reason}), do: {:error, ChidoriWeb.Collect.reason_text(reason)}

  @doc """
  まだ図へ引き継いでいない作品（`%{title, date, summary, url, tries}`）。`tries` は頼んだ回数。

  **並びは、見た記録を付けた作品（見た日の新しい順）→ 注目度の高い作品（公開日の新しい順）**。
  `limit` を渡すと時計が頼むぶん —— **何度頼んでも載らなかった作品
  （`CarrySetting.max_attempts/0` 回）を外して**その数まで。外さないと、その作品が毎回の枠の
  頭を占め続け、後ろの作品がいつまでも頼まれない。画面に並べるときは全部。
  """
  def pending(base, limit \\ nil) do
    with {:ok, carried} <- carried(base),
         {:ok, released} <- released_high(base) do
      setting = CarrySetting.get()
      {:ok, order(carried, released, Marks.for_view(Films.mark_view()), setting, limit)}
    end
  end

  @doc false
  def order(carried, released, marks, setting, limit \\ nil) do
    by_title = Map.new(released, &{&1.title, &1})

    seen =
      marks
      |> Enum.sort_by(fn {title, mark} ->
        {if(mark.seen_on, do: -Date.to_gregorian_days(mark.seen_on), else: 1), title}
      end)
      |> Enum.map(&elem(&1, 0))

    high =
      released
      |> Enum.sort_by(&{-Date.to_gregorian_days(&1.date), &1.title})
      |> Enum.map(& &1.title)

    items =
      (seen ++ high)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(carried, &1))
      |> Enum.map(fn title ->
        (Map.get(by_title, title) || %{title: title})
        |> Map.put(:tries, CarrySetting.attempts(setting, title))
      end)

    if limit,
      do: items |> Enum.reject(&(&1.tries >= CarrySetting.max_attempts())) |> Enum.take(limit),
      else: items
  end

  # 名指しした見出しを、最新情報に残っていればその中身つきで。人が添えた手がかりは
  # 説明の代わりに渡す（最新情報に無い作品は、見出しのほかに手がかりが無い）
  defp items_for(base, titles, hint) do
    known =
      case released_high(base) do
        {:ok, entries} -> Map.new(entries, &{&1.title, &1})
        {:error, _reason} -> %{}
      end

    hint = String.trim(hint || "")

    {:ok,
     Enum.map(titles, fn title ->
       item = Map.get(known, title) || %{title: title}
       if hint == "", do: item, else: Map.put(item, :summary, "手がかり: " <> hint)
     end)}
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

  # 図にある作品のうち、同じ作品かもしれないもの。**見出しの前方一致と全文検索の両方**
  # —— 人が打った題名は記事名と一字違うことがあり（「7人の侍」）、前方一致だけでは
  # 拾えない。拾えないと AI が二重に足すか、見ていない作品を上書きする
  defp similar(base, title) do
    by_prefix = titles_from(base, "titles", %{"prefix" => title, "limit" => 3}, "titles")
    by_search = titles_from(base, "search", %{"q" => title, "limit" => 3}, "results")
    Enum.uniq(by_prefix ++ by_search)
  end

  defp titles_from(base, path, params, key) do
    url = base <> "/v1/" <> Films.collection() <> "/" <> path <> "?" <> URI.encode_query(params)

    with {:ok, %{status: 200, body: body}} <- Chiezo.get(url),
         {:ok, %{^key => list}} when is_list(list) <- Jason.decode(body) do
      Enum.flat_map(list, fn
        %{"title" => t} when is_binary(t) -> [t]
        _other -> []
      end)
    else
      _ -> []
    end
  end

  # Chiezo の filter が 1 回に返す上限（`limit` は 500 まで。超えると 422）
  @page 500

  @doc """
  **図にもう居る作品の見出し**（引き継ぎ済み）。図の作品の見出しと、引き継いだ作品が持つ
  `記録:` の見出しの両方。図の札に直接付けた見た記録も同じ置き場に入るので、`記録:` だけで
  数えると、図に元から居る作品まで「まだ」になり、時計が毎回頼みに行く。

  **ページを送って全部読みます**（1 回に #{@page} 件まで）。図の作品は数千件になるので
  数回の往復になるが、読むのは見出しとタグだけで、時計の回と押したときにしか読まない。
  """
  def carried(base), do: carried(base, 0, MapSet.new())

  defp carried(base, offset, acc) do
    query =
      URI.encode_query(%{
        "tag" => Films.kind_tag(),
        "fields" => "title,tags",
        "limit" => @page,
        "offset" => offset
      })

    case Chiezo.get(base <> "/v1/" <> Films.collection() <> "/filter?" <> query) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"results" => docs}} when is_list(docs) ->
            acc =
              Enum.reduce(docs, acc, fn doc, acc ->
                [doc["title"] | Films.record_titles(%{tags: doc["tags"] || []})]
                |> Enum.filter(&is_binary/1)
                |> Enum.reduce(acc, &MapSet.put(&2, &1))
              end)

            if length(docs) < @page,
              do: {:ok, acc},
              else: carried(base, offset + @page, acc)

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
