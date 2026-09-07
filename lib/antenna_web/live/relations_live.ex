defmodule AntennaWeb.RelationsLive do
  @moduledoc """
  関連図。収集の進み具合はそのまま画面へ反映します。

  AI に web 検索をさせるので数十秒かかります。押した人に再読み込みをさせず、
  `Antenna.Relations` からの通知で描き直します。
  """

  use AntennaWeb, :live_view

  alias Antenna.Jst
  alias Antenna.Relations

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "関連図", artwork: nil, artwork_for: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    view = Relations.valid_key(params["view"] || "people")

    # 種類を切り替えたら購読も付け替える。付け替えないと、見ていない側の
    # 収集結果でこの画面が書き換わる
    if connected?(socket) do
      if previous = socket.assigns[:view] do
        Relations.unsubscribe(previous)
      end

      Relations.subscribe(view)
      # Chiezo の側は antenna と関係なく進むので、開くたびに取り直す
      Relations.refresh(view)
    end

    {:noreply, assign(socket, view: view, relation: Relations.current(view))}
  end

  @impl true
  def handle_event("collect", _params, socket) do
    Relations.collect_now(socket.assigns.view)
    {:noreply, socket}
  end

  # ノードを押したら、その人の代表作を出す。**押されたときだけ引く** ——
  # 12 人ぶんを先に集めると、見ない絵まで毎回取りに行くことになる
  def handle_event("show_work", %{"name" => name}, socket) do
    node = Enum.find(socket.assigns.relation.nodes, &(&1.name == name))

    cond do
      node == nil ->
        {:noreply, socket}

      # もう一度押したら閉じる
      socket.assigns.artwork_for == name ->
        {:noreply, assign(socket, artwork: nil, artwork_for: nil)}

      true ->
        {:noreply,
         socket
         |> assign(artwork_for: name, artwork: :loading)
         |> start_async(:artwork, fn -> Antenna.Artwork.lookup(node[:work]) end)}
    end
  end

  # 閉じ方は3つとも同じところへ来る（ボタン・図の外を押す・Esc）
  def handle_event("close_work", _params, socket) do
    {:noreply, assign(socket, artwork: nil, artwork_for: nil)}
  end

  @impl true
  def handle_async(:artwork, {:ok, result}, socket) do
    {:noreply, assign(socket, artwork: result)}
  end

  def handle_async(:artwork, {:exit, _reason}, socket) do
    {:noreply, assign(socket, artwork: nil)}
  end

  @impl true
  def handle_info({:relation_updated, relation}, socket) do
    {:noreply, assign(socket, relation: relation)}
  end

  @doc """
  Chiezo の収集の状態。動いているかの判断に要るものを並べる。

  **画家の図だけが持つ** —— 人物のほうはまだその場で AI に聞く形で、
  向こうに溜め先が無い。
  """
  def collection_facts(%{collection: c} = relation) when is_map(c) do
    [
      {"状態", if(c.enabled, do: "有効", else: "止まっている")},
      {"頼む相手", backend_text(c)},
      {"間隔", if(c.interval_minutes, do: "#{c.interval_minutes} 分ごと", else: "—")},
      {"次に集める", if(c.enabled, do: Jst.format(c.next_run_at) || "—", else: "—（止まっています）")},
      {"溜まった数", "#{c.docs} 件"},
      {"進み具合", if(c.cursor == "", do: "（まだ無し。次は一気に作ります）", else: c.cursor)},
      {"前回", last_text(c)},
      # 集まるものが変わらなかった日でも、**押した結果はここが動く**
      {"最後に確かめた", Jst.format(relation[:checked_at]) || "まだ確かめていません"}
    ]
  end

  def collection_facts(_relation), do: []

  defp backend_text(%{backend: nil}), do: "Chiezo の既定にまかせる"

  defp backend_text(%{backend: backend} = c) do
    detail = Enum.reject([c.model, c.effort], &(&1 in [nil, ""]))
    if detail == [], do: backend, else: "#{backend}（#{Enum.join(detail, " / ")}）"
  end

  defp last_text(%{last_run_at: nil}), do: "まだ集めていません"

  defp last_text(%{last_status: "error", last_error: error}) when is_binary(error),
    do: "失敗: #{error}"

  defp last_text(c),
    do:
      "#{Jst.format(c.last_run_at)}（+#{c.last_added} 件" <>
        if(c.last_removed > 0, do: " / -#{c.last_removed} 件）", else: "）")

  @doc """
  AI に頼んでいる本文。**依頼した後は Chiezo が持っているものを出す** ——
  向こうの画面から直せるので、antenna の雛形を出し続けると食い違う。
  """
  def prompt_text(%{collection: %{prompt: prompt}}) when is_binary(prompt) and prompt != "",
    do: prompt

  def prompt_text(_relation), do: Antenna.Relations.painters_prompt()

  @doc """
  最初の 1 回を機械的に埋める指定（持っていなければ nil）。

  **何で埋まったのかが読めないと、図の間違いを AI のせいにしてしまいます** ——
  名簿と年代は Wikipedia から引いたもので、AI が書いたのは影響関係と代表作です。
  """
  def extract_text(%{collection: %{extract: spec}}) when is_map(spec),
    do: Jason.encode!(spec, pretty: true)

  def extract_text(_relation), do: nil

  def prompt_note(%{collection: c}) when is_map(c),
    do: "いま Chiezo が持っている内容です。直すのは Chiezo の管理画面の「集める」から。"

  def prompt_note(_relation),
    do: "「関連図を収集」を押すと、この内容で Chiezo に頼みます。"

  @doc "その人の代表作の見出し（無ければ nil）。押せるかどうかの判断にも使う。"
  def work_of(node), do: node[:work]

  @doc "丸の半径。知名度が引けていなければ既定の大きさ。"
  def radius_of(node), do: node[:radius] || if(node.kind == :group, do: 47, else: 42)

  @doc """
  いま押せないかどうか。

  自分が読んでいる間だけでなく、**Chiezo 側で取り込みが走っている間も押させません** ——
  走っている間の「いま集めて」は向こうが断るので、押してから断られることになります。
  """
  def collecting?(%{status: :loading}), do: true
  def collecting?(%{busy: true}), do: true
  def collecting?(_relation), do: false

  @doc "ボタンの文字。何を待っているのかまで出す。"
  def collect_label(%{status: :loading}), do: "収集中…"
  def collect_label(%{busy: true}), do: "Chiezo が取り込み中…"
  def collect_label(_relation), do: "関連図を収集"

  @doc """
  いまの状態を1文で言う。失敗したときは、直前の図を出していることまで書く。
  """
  def status_message(%{status: :loading}), do: "AIが出典を確認しながら関連図を作成しています。"
  def status_message(%{status: :ready, reason: nil}), do: "AIが収集した情報を表示しています。"
  def status_message(%{status: :sample, reason: nil}), do: "現在は表示例です。収集すると公開情報に基づく図へ更新します。"

  def status_message(%{status: status, reason: reason}) do
    prefix =
      case status do
        :stale -> "前回の収集結果を表示しています。"
        :ready -> "AIが収集した情報を表示しています。"
        _ -> "表示例を表示しています。"
      end

    prefix <> reason_text(reason)
  end

  @doc """
  この図がどこから来るか。**画家は Chiezo に溜まったものを読みます**。

  集めて整理するのは Chiezo の役目で、antenna は図の形に読み直して見せるだけです。
  人物のほうは、まだその場で AI に聞く形のままです。
  """
  def source_note("painters") do
    "この図は Chiezo に溜まった内容から作っています（収集「#{Antenna.Relations.painters_collection()}」）。" <>
      "集めて整理するのは Chiezo で、antenna は図の形にして見せるだけです。"
  end

  def source_note(_view), do: "「関連図を収集」を押すと、その場で AI に調べさせて図を作り直します。"

  defp reason_text(:too_soon), do: "続けて収集しようとしています。少し時間を置いてから押してください。"

  defp reason_text(:chiezo_not_configured),
    do: "CHIEZO_BASE_URL が設定されていないため収集できません。"

  defp reason_text(:chiezo_unavailable), do: "Chiezoに接続できませんでした。"
  defp reason_text({:chiezo_status, status}), do: "Chiezoが #{status} を返しました。"
  defp reason_text(:chiezo_unexpected_body), do: "Chiezoの応答を解釈できませんでした。"

  defp reason_text({:chiezo_refused, status, nil}), do: "Chiezo が依頼を断りました（#{status}）。"

  defp reason_text({:chiezo_refused, _status, message}), do: "Chiezo が依頼を断りました: #{message}"

  defp reason_text(:collect_unsupported),
    do: "この Chiezo には「集める」層がありません。Chiezo を新しくすると使えるようになります。"

  defp reason_text(:collect_disabled),
    do: "Chiezo 側で「集める」層が無効です。CHIEZO_NOTES_DIR と CHIEZO_TRIGGER_URL を設定すると有効になります。"

  defp reason_text(:collection_disabled),
    do:
      "この収集は Chiezo 側で止まっているので、集めさせられませんでした。" <>
        "Chiezo の管理画面の「集める」で有効にすると、押したときに集まります。"

  defp reason_text(:nothing_collected),
    do:
      "Chiezo にまだ何も溜まっていません。Chiezo の管理画面の「集める」で" <>
        "この図の収集を有効にすると、集まったものがここに出ます。"

  defp reason_text(:invalid_ai_response), do: "AIの応答から関連図を作れませんでした。もう一度収集してください。"
  defp reason_text(:collection_crashed), do: "収集の途中で問題が起きました。もう一度収集してください。"
  defp reason_text(nil), do: ""
  defp reason_text(_reason), do: "収集に失敗しました。"
end
