defmodule AntennaWeb.RelationsLive do
  @moduledoc """
  関連図。収集の進み具合はそのまま画面へ反映します。

  AI に web 検索をさせるので数十秒かかります。押した人に再読み込みをさせず、
  `Antenna.Relations` からの通知で描き直します。
  """

  use AntennaWeb, :live_view

  alias Antenna.Relations

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "関連図")}
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
    end

    {:noreply, assign(socket, view: view, relation: Relations.current(view))}
  end

  @impl true
  def handle_event("collect", _params, socket) do
    Relations.collect_now(socket.assigns.view)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:relation_updated, relation}, socket) do
    {:noreply, assign(socket, relation: relation)}
  end

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

  defp reason_text(:too_soon), do: "続けて収集しようとしています。少し時間を置いてから押してください。"

  defp reason_text(:chiezo_not_configured),
    do: "CHIEZO_BASE_URL が設定されていないため収集できません。"

  defp reason_text(:chiezo_unavailable), do: "Chiezoに接続できませんでした。"
  defp reason_text({:chiezo_status, status}), do: "Chiezoが #{status} を返しました。"
  defp reason_text(:chiezo_unexpected_body), do: "Chiezoの応答を解釈できませんでした。"
  defp reason_text(:invalid_ai_response), do: "AIの応答から関連図を作れませんでした。もう一度収集してください。"
  defp reason_text(:collection_crashed), do: "収集の途中で問題が起きました。もう一度収集してください。"
  defp reason_text(nil), do: ""
  defp reason_text(_reason), do: "収集に失敗しました。"
end
