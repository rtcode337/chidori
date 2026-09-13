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
    {:ok,
     socket
     |> assign(page_title: "設定", editing: nil, saved: nil, error: nil)
     |> assign(backends: backends())
     |> load_topics()}
  end

  @impl true
  # **鍵は収集名。** 話題の定義はコードにあり、DB の行は設定を保存したときに
  # 初めてできる —— id で指すと、まだ保存していない話題を開けない
  def handle_event("edit", %{"collection" => collection}, socket) do
    topic = Topics.get(collection)

    {:noreply,
     assign(socket, editing: collection, form: to_form(Topics.change(topic)), saved: nil)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, editing: nil, error: nil)}
  end

  # 相手を選び直したら、モデルと考える量の選択肢も入れ替える。
  #
  # **Chiezo へ聞き直しません。** 候補は mount で取った一覧に最初から入っているので
  # （`/v1/ai/backends` は相手ごとの models と efforts を返します）、選び直しの
  # たびに外へ出るのは無駄なうえ、相手が落ちていると画面が固まります。
  #
  # 保存はしません。ここで持ち回るのは書きかけの入力だけで、書き込むのは "save" です。
  def handle_event("validate", %{"topic" => attrs}, socket) do
    topic = Topics.get(socket.assigns.editing)
    {:noreply, assign(socket, form: to_form(Topics.change(topic, attrs)))}
  end

  def handle_event("save", %{"topic" => attrs}, socket) do
    topic = Topics.get(socket.assigns.editing)

    case Topics.save_settings(socket.assigns.editing, attrs) do
      {:ok, _row} ->
        {:noreply,
         socket
         |> assign(editing: nil, error: nil, saved: topic.name)
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
  モデル・考える量の選択肢。**空が「相手の既定」**で、先頭に置きます。

  候補は mount で取った一覧から引きます —— `/v1/ai/backends` は相手ごとの
  models と efforts を最初から返すので、相手を選び直すたびに聞き直す必要はありません。

  **相手が未指定なら一覧の先頭の候補を出します。** 「Chiezo の既定にまかせる」で
  実際に当たるのがその相手だからです（向こうの `normalize_backend` と同じ決まり）。

  **いま入っている値が候補に無くても残します** —— 落とすと、保存し直した瞬間に
  既定へ倒れて、何を指定していたのかが画面から消えます（相手を選ぶ側と同じ約束）。
  """
  def candidate_options(backends, backend, key, current) do
    spec =
      Enum.find(backends, &(&1["id"] == backend)) ||
        if(backend in [nil, ""], do: List.first(backends), else: nil)

    candidates = List.wrap(spec && spec[key])
    kept = if current in [nil, "" | candidates], do: [], else: [current]
    [{"相手の既定", ""}] ++ Enum.map(candidates ++ kept, &{&1, &1})
  end

  @doc "フォームのいまの値（選び直した直後は、まだ保存されていない値）。"
  def field_value(form, key) do
    case form[key].value do
      nil -> ""
      value -> to_string(value)
    end
  end

  @doc """
  相手ごとに渡せるモデルと考える量。**選ぶ前に読めるところに置く**。

  モデルと考える量はセレクトで選べますが、あれは**いま選んでいる相手のぶんだけ**なので、
  「どの相手に替えれば何が使えるか」はここでしか読めません。相手を選ぶ前に効きます。
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
