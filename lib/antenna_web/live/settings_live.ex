defmodule AntennaWeb.SettingsLive do
  @moduledoc """
  話題ごとの設定。

  **相手を 2 つ持つ**（集める相手と選ぶ相手）。役割が違うので、速さと質の釣り合いも
  別に決めたいためです —— 集めるのは web を歩く仕事、選ぶのは溜まったものを読む仕事。
  どちらも未指定なら Chiezo の既定にまかせます。

  **候補は Chiezo に聞きます**（`/v1/ai/backends`）。いま話せる相手とモデルは
  向こうが知っているので、こちらに写しを持つと必ず腐ります。
  """

  use AntennaWeb, :live_view

  alias Antenna.Chiezo
  alias Antenna.Topics

  @impl true
  def mount(_params, _session, socket) do
    Topics.ensure_default()

    {:ok,
     socket
     |> assign(page_title: "設定", editing: nil, saved: nil, error: nil)
     |> assign(backends: backends())
     |> load_topics()}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    topic = Topics.get!(id)
    {:noreply, assign(socket, editing: topic.id, form: to_form(Topics.change(topic)), saved: nil)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, editing: nil, error: nil)}
  end

  def handle_event("save", %{"topic" => attrs}, socket) do
    topic = Topics.get!(socket.assigns.editing)

    case Topics.update(topic, attrs) do
      {:ok, saved} ->
        {:noreply,
         socket
         |> assign(editing: nil, error: nil, saved: saved.name)
         |> load_topics()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset), error: "保存できませんでした")}
    end
  end

  defp load_topics(socket), do: assign(socket, topics: Topics.list())

  # 相手の一覧は Chiezo に聞く。取れなければ空（選べるのは「既定にまかせる」だけ）
  defp backends do
    with base when is_binary(base) <- Chiezo.base_url(),
         {:ok, %{status: 200, body: body}} <- Chiezo.get(base <> "/v1/ai/backends"),
         {:ok, %{"backends" => list}} when is_list(list) <- Jason.decode(body) do
      list
    else
      _ -> []
    end
  end

  @doc "相手を選ぶ選択肢。空が「Chiezo の既定にまかせる」。"
  def backend_options(backends) do
    [{"Chiezo の既定にまかせる", ""}] ++ Enum.map(backends, &{&1["label"] || &1["id"], &1["id"]})
  end

  @doc """
  相手ごとに渡せるモデルと考える量。**選ぶ前に読めるところに置く**。

  選択肢を連動させるには相手を選び直すたびの往復が要るので、一覧を添えて
  手で書いてもらいます（空にすれば相手の既定に任せられます）。
  """
  def backend_hint(backends) do
    for b <- backends do
      parts =
        [
          if(b["models"] not in [nil, []], do: "モデル: " <> Enum.join(b["models"], " / ")),
          if(b["efforts"] not in [nil, []], do: "考える量: " <> Enum.join(b["efforts"], " / "))
        ]
        |> Enum.reject(&is_nil/1)

      {b["label"] || b["id"], if(parts == [], do: "指定なしでよい", else: Enum.join(parts, "、"))}
    end
  end

  @doc "行に出す相手。未指定なら既定だと分かるように書く。"
  def backend_text(nil, _model, _effort), do: "既定にまかせる"

  def backend_text(backend, model, effort) do
    detail = Enum.reject([model, effort], &(&1 in [nil, ""]))
    if detail == [], do: backend, else: "#{backend}（#{Enum.join(detail, " / ")}）"
  end
end
