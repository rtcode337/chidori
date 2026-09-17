defmodule TazunaWeb.ThemesLive do
  @moduledoc """
  トピックの画面。**記事に付いたタグから育てた語**を並べます。

  一覧（`/news`）が 1 件ずつの索引、まとめがその期間の読み物だとすれば、
  ここは**話題の地図**です —— どの語が動いていて、どれが何の下にあるのか。

  **仕分け待ちを画面に出します。** まだトピックになっていない語が見えていないと、
  「押すと何が起きるのか」が分からないまま AI を動かすことになります。
  """

  use TazunaWeb, :live_view

  import TazunaWeb.Collect
  import TazunaWeb.CollectPanel

  alias Tazuna.News
  alias Tazuna.Themes
  alias Tazuna.Themes.Graph
  alias Tazuna.Topics

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        topics: Topics.list(),
        backends: [],
        picks: %{},
        state: empty(),
        loading: true
      )

    socket =
      if connected?(socket),
        do: start_async(socket, :backends, fn -> Tazuna.Relations.ai_backends() end),
        else: socket

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    topic = pick_topic(socket.assigns.topics, params["view"])

    socket =
      assign(socket,
        topic: topic,
        page_title: if(topic, do: "トピック — #{topic.name}", else: "トピック"),
        state: empty(),
        loading: true
      )

    {:noreply, if(connected?(socket), do: load(socket), else: socket)}
  end

  @impl true
  def handle_event("pick_sweep", params, socket) do
    {:noreply, assign(socket, picks: sweep_choices(params))}
  end

  # **押す口は 1 つ。** 無ければ作り、あれば設定を送り直す（関連図・最新情報と同じ形）
  def handle_event("collect", _params, socket) do
    topic = socket.assigns.topic
    picks = socket.assigns.picks

    case with_base(fn base -> Themes.setup(base, topic, picks) end) do
      :ok -> {:noreply, socket |> put_flash(:info, "Chiezo へ送りました。") |> load()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  # **予定を待たずに 1 回育てさせる。** 育てるのは Chiezo の側で、tazuna は起こすだけ
  def handle_event("grow", _params, socket) do
    topic = socket.assigns.topic

    case with_base(fn base -> Themes.grow_now(base, topic) end) do
      :ok ->
        {:noreply, put_flash(socket, :info, "育てるよう頼みました。終わったら読み直してください。")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_async(:backends, {:ok, backends}, socket),
    do: {:noreply, assign(socket, backends: backends)}

  def handle_async(:backends, _result, socket), do: {:noreply, socket}

  def handle_async(:load, {:ok, state}, socket),
    do: {:noreply, assign(socket, state: state, loading: false)}

  def handle_async(:load, _result, socket), do: {:noreply, assign(socket, loading: false)}

  defp load(socket) do
    topic = socket.assigns.topic

    case {topic, News.chiezo_base_url()} do
      {nil, _base} ->
        assign(socket, loading: false)

      {_topic, nil} ->
        assign(socket, loading: false)

      {topic, base} ->
        socket
        |> assign(loading: true)
        |> start_async(:load, fn -> Themes.read(base, topic) end)
    end
  end

  defp with_base(fun) do
    case News.chiezo_base_url() do
      nil -> {:error, :chiezo_not_configured}
      base -> fun.(base)
    end
  end

  defp empty do
    %{collection: nil, themes: [], checked_at: nil}
  end

  defp pick_topic(topics, nil), do: List.first(topics)

  defp pick_topic(topics, view) do
    Enum.find(topics, List.first(topics), &(&1.collection == view))
  end

  @doc """
  図に出す丸と線。**置き場所を決めるのは `Tazuna.Themes.Graph`** で、ここは渡すだけです。
  """
  def graph(%{themes: themes}), do: Graph.build(themes)

  @doc "並びは、つながりの多い順。**同じ数なら名前の順**（開くたびに並びが変わらないように）。"
  def sorted_themes(%{themes: themes}) do
    linked =
      Enum.reduce(themes, %{}, fn theme, counted ->
        Enum.reduce(theme.related, counted, fn related, inner ->
          inner
          |> Map.update(theme.name, 1, &(&1 + 1))
          |> Map.update(related.to, 1, &(&1 + 1))
        end)
      end)

    Enum.sort_by(themes, &{-Map.get(linked, &1.name, 0), &1.name})
  end

  @doc """
  収集の状態の一言。**押す前に、何が起きるのかが読めるように**。
  """
  def note(%{collection: nil}),
    do: "まだ Chiezo に収集がありません。押すと、止まった状態の収集が作られます。"

  def note(%{collection: %{enabled: false}}),
    do: "Chiezo 側で止まっています。動かすのは Chiezo の画面からです（止まっている収集は仕分けを断ります）。"

  def note(_state), do: "押すと、いまの設定を Chiezo へ送り直します（走らせはしません）。"

  @doc "押す口の文字。何が起きるのかまで出します。"
  def collect_label(%{collection: nil}), do: "収集を依頼する"
  def collect_label(_state), do: "収集の設定を更新"

  @doc false
  def error_text(:chiezo_not_configured), do: "Chiezo の場所が設定されていません。"
  def error_text(:collection_disabled), do: "この収集は Chiezo 側で止まっています。"
  def error_text(:not_requested), do: "まだ収集を依頼していません。"
  def error_text(:chiezo_busy), do: "Chiezo がいま別の依頼を抱えています。少し待ってください。"
  def error_text({:chiezo_refused, _status, reason}) when is_binary(reason), do: reason
  def error_text(_reason), do: "Chiezo へ送れませんでした。"
end
