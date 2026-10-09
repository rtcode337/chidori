defmodule Tazuna.CollectCatalog do
  @moduledoc """
  tazuna が Chiezo に送る収集の一覧（設定ページの「Chiezo 収集」の表）。

  **並びと中身は tazuna の画面のもの**です —— 最新情報（話題と、そのトピックの網）→
  関連図 → データ収集（その下の本棚）の順。Chiezo の一覧の順で並べると、同じ画面の
  収集（技術ニュースとそのトピック）のあいだに別の画面のものが挟まって読めない。

  **Chiezo にまだ送っていない収集も並びます**（巡回は tazuna の定義から出す）。

  送るのは**各画面の「収集の設定を更新」と同じもの**（`push`）—— tazuna の今の定義
  （依頼文を含む）に、選んだ相手を載せて丸ごと送る。相手だけを送る形にすると、
  依頼文を直したのに設定ページで送っても古いまま、ということが起きる。
  """

  alias Tazuna.Chiezo
  alias Tazuna.CollectDrift
  alias Tazuna.CollectPace
  alias Tazuna.Datasets
  alias Tazuna.News
  alias Tazuna.News.Interests
  alias Tazuna.Relations
  alias Tazuna.Themes
  alias Tazuna.Topics

  @doc """
  収集の一覧（画面の並び）。1 件は
  `%{name:, label:, screen:, attrs: fn choices -> 送る設定 end, push: fn base, choices -> 結果 end}`。
  """
  def list, do: news() ++ relations() ++ datasets()

  defp news do
    Enum.flat_map(Topics.list(), fn topic ->
      name = topic.collection

      [
        %{
          name: name,
          label: topic.name,
          screen: "/news?view=#{name}",
          # 興味トピックを載せる（要約の巡回と依頼文に要る。画面の送り方と同じ）
          attrs: fn choices -> News.attrs(name, Interests.attach(topic), choices) end
        }
        |> upserting()
      ] ++
        if Topics.themes?(topic),
          do: [
            %{
              name: Themes.collection_name(topic),
              label: "#{topic.name}のトピック",
              screen: "/news?view=#{name}",
              attrs: &Themes.attrs(topic, &1)
            }
            |> upserting()
          ],
          else: []
    end)
  end

  defp relations do
    for {key, title} <- Relations.views() do
      %{
        name: Relations.collection_of(key),
        label: title,
        screen: "/relations?view=#{key}",
        attrs: &Relations.attrs_of(key, &1)
      }
      |> upserting()
    end
  end

  defp datasets do
    Enum.flat_map(Datasets.list(), fn dataset ->
      [
        %{
          name: dataset.collection,
          label: Map.get(dataset, :title, dataset.name),
          screen: "/datasets?view=#{dataset.key}",
          attrs: &Datasets.call(dataset, :attrs, [&1]),
          # データ収集の画面と同じ道で送る。比べるのも同じもの
          outgoing: fn -> Datasets.outgoing(dataset) end,
          push: fn _base, choices -> Datasets.push(dataset, choices) end
        }
      ] ++
        case dataset[:derived] do
          nil ->
            []

          derived ->
            [
              %{
                name: derived.collection(),
                label: derived.name(),
                screen: "/datasets?view=#{dataset.key}",
                attrs: &derived.attrs/1,
                push: &derived.setup/2
              }
            ]
        end
    end)
  end

  # **無ければ作り、あれば送り直す**（作るときの POST は「もうある」で断られるので、
  # 続けて送り直さないと、定義を直しても届かない）
  defp upserting(entry) do
    Map.put(entry, :push, fn base, choices ->
      attrs = entry.attrs.(choices)
      with :ok <- Chiezo.request(base, attrs), do: Chiezo.patch(base, attrs.name, attrs)
    end)
  end

  @doc """
  表の行。**tazuna の収集を画面の並びで**出し、Chiezo の状態（`Tazuna.CollectOverview`
  の行）を巡回の名前で重ねます。Chiezo にまだ無い収集は `in_chiezo: false` で、巡回は
  定義のもの。**tazuna の定義に無い Chiezo の収集**（画面から外した
  もの）は後ろに並べ、`push` は nil（相手だけを送る）。
  """
  def rows(chiezo_rows) do
    rows_with(chiezo_rows, &drift/2)
  end

  @doc false
  # 突き合わせを差し替えられる形（テストで使う）
  def rows_with(chiezo_rows, drift) do
    by_name = Map.new(chiezo_rows, &{&1.name, &1})
    entries = list()
    known = MapSet.new(entries, & &1.name)

    Enum.map(entries, &row(&1, by_name[&1.name], drift)) ++
      for(
        c <- chiezo_rows,
        !MapSet.member?(known, c.name),
        do: Map.merge(c, %{in_chiezo: true, screen: nil, push: nil})
      )
  end

  defp row(entry, chiezo, drift) do
    sweeps =
      for d <- sweeps(entry) do
        c = chiezo && Enum.find(chiezo.sweeps, &(&1.name == d.name))

        if c do
          Map.merge(c, %{mechanical: d.mechanical})
        else
          %{
            name: d.name,
            mechanical: d.mechanical,
            pick: d.backend,
            pick_model: d.model,
            enabled: true,
            # 送っていなくても、整理を止める選択は tazuna が覚えている
            by_caller:
              d.name == Tazuna.SweepNames.tidy() and Tazuna.CollectPace.tidy_stopped?(entry.name),
            clock: "—",
            last_run_at: nil,
            last_status: nil,
            next_run_at: nil,
            blocked: nil
          }
        end
      end

    %{
      name: entry.name,
      label: entry.label,
      screen: entry.screen,
      in_chiezo: chiezo != nil,
      enabled: chiezo == nil or chiezo.enabled,
      sweeps: sweeps,
      push: entry.push,
      # **Chidori の定義と違う項目**（Chiezo にまだ無い収集は空）
      drift: if(chiezo, do: drift.(entry, chiezo), else: [])
    }
  end

  @doc """
  Chiezo の今の設定が、Chidori がいま送るはずの設定と違う項目（`Tazuna.CollectDrift`）。
  比べるのは**送るときと同じもの**（整理を止めた選択も載せる）。組み立てに失敗しても
  表は出す（違いが読めないだけで、空として扱う）。
  """
  def drift(entry, chiezo) do
    expected =
      case entry[:outgoing] do
        nil -> entry.attrs.(%{})
        outgoing -> outgoing.()
      end

    CollectDrift.differences(CollectPace.with_stops(entry.name, expected), chiezo[:config])
  rescue
    _error -> []
  end

  @doc """
  tazuna の定義にある巡回（名前・相手を選べるか・定義の相手とモデル）。
  **機械で引く回は相手を選ばせない**（AI を呼ばないので、選んでも読まれない）。
  検索文を考えさせる回（依頼文に `{queries}`）は例外。
  """
  def sweeps(entry) do
    for sweep <- Map.get(entry.attrs.(%{}), :sweeps) || [] do
      %{
        name: sweep.name,
        mechanical: mechanical?(sweep),
        backend: sweep[:backend] || "",
        model: sweep[:model] || ""
      }
    end
  end

  defp mechanical?(sweep) do
    sweep[:use_extract] == true or sweep[:by_hand] == true or sweep[:use_pihole] == true or
      (sweep[:use_feed] == true and
         not String.contains?(to_string(sweep[:prompt] || ""), "{queries}"))
  end
end
