defmodule Tazuna.Datasets.Survey do
  @moduledoc """
  情報収集の回を、**決めた時刻に tazuna が起こす**ところ。**どの区画を見るかは
  Chiezo が選びます。**

  Chiezo の側の情報収集は止めておき（自分の時計では走らない）、tazuna が時刻に起きて
  巡回を名前で 1 回走らせます（`Chiezo.run/3` の `sweep`）。止めてある巡回でも、
  名前で起こせばふつうの回として走り、区画は Chiezo が選びます —— その巡回で見た
  時刻の古い順、同じなら収集の起点（`origin`）に近い順で、ざっと見ると同じ規則です。
  起点は tazuna で決めて Chiezo へ送ってあるので（`Tazuna.Datasets.put_origin/2`）、
  ざっと見るも情報収集も同じ起点から広がります。

  **区画の選び方を tazuna に書き写さない。** 2 か所に同じ規則を持つと、片方だけ
  直したときに、画面で見ている並びと実際に回る並びが食い違います。

  **取り込み中なら空くまで待ちます**（`Chiezo.when_free/2`）。待つのは次の予定の
  時刻までで、それを過ぎたらその回は諦めます。
  """

  alias Tazuna.Chiezo
  alias Tazuna.Datasets
  alias Tazuna.Datasets.SurveyPlan

  @doc """
  いま 1 回頼みます。`:ok` か `{:error, 理由}`。

  `deadline` は `System.monotonic_time(:millisecond)` の値で、**取り込みが空くのを
  そこまで待ちます**。
  """
  def run(%{collection: name} = dataset, %SurveyPlan{} = plan, deadline) do
    sweep = dataset.survey_plan_sweep

    with {:ok, base} <- Datasets.base_url(),
         true <- Datasets.ready_to_survey?(dataset, plan) || {:error, :no_place},
         :ok <- before_survey(dataset, base),
         :ok <- Chiezo.when_free(fn -> Chiezo.run(base, name, sweep: sweep) end, deadline) do
      :ok
    end
  end

  # 対象ごとの下ごしらえ（技術書なら、検索文を差し替える）。持たなければ何もしない
  defp before_survey(%{module: module}, base) do
    Code.ensure_loaded(module)

    if function_exported?(module, :before_survey, 1) do
      case module.before_survey(base) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, _reason} = error -> error
      end
    else
      :ok
    end
  end

  @doc """
  画面と通知に出す一言。**いつ・どうなったか**を 1 行で。
  """
  def result_text(result, now \\ DateTime.utc_now()) do
    Tazuna.Jst.format(now) <> " — " <> outcome(result)
  end

  defp outcome(:ok), do: "情報収集を 1 回頼みました（見る区画は Chiezo が選びます）。"
  defp outcome({:error, reason}), do: "頼めませんでした。そのときの理由: " <> error_text(reason)

  @doc "頼めなかった理由の言い方。"
  def error_text(:no_place), do: "起点がまだ決まっていません。"
  def error_text(:no_new_queries), do: "AI が新しい検索文を出せませんでした（出したものが全部使用済み）。"
  def error_text(:not_requested), do: "まだ収集を依頼していません。"
  def error_text(:collection_disabled), do: "この収集は Chiezo 側で止まっています。"

  def error_text(:chiezo_busy),
    do: "次の予定の時刻まで待ちましたが、Chiezo の取り込みが空きませんでした。"

  def error_text(:chiezo_not_configured), do: "Chiezo の場所が設定されていません。"
  def error_text(:chiezo_unavailable), do: "Chiezo に接続できませんでした。"
  def error_text({:chiezo_refused, _status, reason}) when is_binary(reason), do: reason
  def error_text(other), do: "#{inspect(other)}"
end
