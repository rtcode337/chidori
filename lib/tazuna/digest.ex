defmodule Tazuna.Digest do
  @moduledoc """
  まとめを作らせて、知らせるところ。**段取りを持つのは tazuna です**。

  Chiezo に「何時に回したいか」は持たせません —— あちらは題材も都合も持たない側で、
  何時に読みたいかは利用者の都合です。時刻を持つのはこちら（話題ごとに画面から
  決めます）で、Chiezo には「いま回してください」としか言いません。

  順番はこうです。

  1. **整理を 1 回起こす**（定時の時計はそのまま。まとめの直前にもう 1 回回す）——
     整理されていないものでまとめさせると、宣伝も重複も読み物に入ります
  2. 終わるのを待って、**要約を起こす**。要約は時計を持たない巡回（`on_demand`）で、
     頼まれたときだけ動きます —— これで「いつ回ったか分からない」が無くなります
  3. **新しいまとめが出るのを待って、知らせる**

  **起こした先は待ってくれません。** Chiezo の口は run も割り込みも「起こした」まで
  返すので、終わったかどうかはこちらが読み直して確かめます —— 整理は収集の前回時刻が
  進んだか、まとめは見出しが変わったかで見ます。

  **途中で止まっても黙りません。** どの段で止まったかは画面に出し、知らせ済みの
  まとめを二度知らせることはしません（`Tazuna.Notify` が覚えています）。
  """

  require Logger

  alias Tazuna.Chiezo
  alias Tazuna.News
  alias Tazuna.Notify

  # 読み直す間隔と、各段で待つ上限。**待つのは分の単位** —— AI が読んで書くので、
  # 秒で返るものではない
  @poll_ms 15_000
  @refine_wait_ms 600_000
  @digest_wait_ms 900_000

  # まとめを読むだけなので、1 件も取れれば足りる（画面の一覧はこちらでは使わない）
  @samples 5

  @refine_sweep "整理"
  @digest_sweep "要約"

  # 割り込みに添える頼みごと。**Chiezo は指示文の無い割り込みを断ります** ——
  # 依頼文そのものは巡回の定義にあるので、ここは「この回で何をしてほしいか」だけ
  @digest_note "定時のまとめです。前回のまとめから今回までに入ったものを1件にまとめてください。" <>
                 "既にある記事は書き換えないでください。"

  @doc """
  その話題のまとめを作らせて、知らせます。**数分かかります**。

  呼ぶ側を待たせないので、走らせるのは `Tazuna.TaskSupervisor` の下です。
  """
  def start(topic) do
    Task.Supervisor.start_child(Tazuna.TaskSupervisor, fn -> run(topic) end)
  end

  @doc """
  段取りを順に踏みます。**戻るのは最後まで行った結果**です。
  """
  def run(%{collection: collection}) do
    case News.chiezo_base_url() do
      nil ->
        {:error, :chiezo_not_configured}

      base ->
        result = walk(base, collection)
        # 画面はこの後の状態を見る（まとめが入れ替わっているので）
        News.refresh(News.server(collection))
        log(collection, result)
        result
    end
  end

  def run(_topic), do: {:error, :no_topic}

  defp walk(base, collection) do
    with {:ok, before} <- Chiezo.collection(base, collection, @samples),
         :ok <- enabled(before),
         :ok <- tell(collection, "整理を起こしています…"),
         :ok <- Chiezo.run(base, collection, sweep: @refine_sweep),
         :ok <- wait_for_run(base, collection, before[:last_run_at], deadline(@refine_wait_ms)),
         :ok <- tell(collection, "まとめを書かせています…"),
         :ok <- Chiezo.focus(base, collection, @digest_note, [], @digest_sweep),
         {:ok, digest} <-
           wait_for_digest(base, collection, digest_title(before), deadline(@digest_wait_ms)) do
      tell(collection, "知らせています…")
      Notify.deliver(collection, digest)
    end
  end

  # 止まっている収集は Chiezo が断る。**押す前と同じ理由で先に見る** ——
  # 起こしてから断られると、どの段で止まったのかが読みにくい
  defp enabled(%{enabled: true}), do: :ok
  defp enabled(_collection), do: {:error, :collection_disabled}

  # 整理が終わったか。**収集の前回時刻で見る** —— 巡回ごとの時刻は割り込みでは
  # 進まないので、どちらの起こし方でも動く側を見る
  defp wait_for_run(base, collection, before, deadline) do
    poll(deadline, fn ->
      case Chiezo.collection(base, collection, 0) do
        {:ok, %{last_run_at: at}} when at != before and not is_nil(at) -> {:done, :ok}
        _other -> :wait
      end
    end)
  end

  # まとめができたか。**見出しで見る** —— まとめの見出しには作った時刻が入るので、
  # 入れ替わったことがそのまま「新しい1件ができた」になる
  defp wait_for_digest(base, collection, before, deadline) do
    poll(deadline, fn ->
      with {:ok, %{recent: recent}} <- Chiezo.collection(base, collection, @samples),
           [digest | _rest] <- News.to_digests(recent),
           true <- digest.title != before do
        # 通知に流すのは要旨なので、冒頭だけの要約ではなく本文を取り直す
        [full | _rest] = News.with_body([digest], base, collection)
        {:done, {:ok, full}}
      else
        _other -> :wait
      end
    end)
  end

  # 読み直す間隔。テストでは短くする（待つこと自体は確かめたいことではない）
  defp poll_ms, do: Application.get_env(:tazuna, :digest_poll_ms, @poll_ms)

  defp poll(deadline, check) do
    case check.() do
      {:done, result} ->
        result

      :wait ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timed_out}
        else
          Process.sleep(poll_ms())
          poll(deadline, check)
        end
    end
  end

  # 待つ上限。テストでは短くする（待つこと自体は確かめたいことではない）
  defp deadline(wait_ms) do
    System.monotonic_time(:millisecond) + Application.get_env(:tazuna, :digest_wait_ms, wait_ms)
  end

  defp digest_title(%{recent: recent}) do
    case News.to_digests(recent) do
      [%{title: title} | _rest] -> title
      _none -> nil
    end
  end

  # 進み具合は画面へ。**数分かかる段取りなので、押した人が待てるようにする**
  defp tell(collection, message) do
    News.broadcast_digest(collection, message)
    :ok
  end

  defp log(collection, {:ok, what}),
    do: Logger.info("まとめを作って知らせた（#{collection}）: #{inspect(what)}")

  defp log(collection, {:error, reason}),
    do: Logger.warning("まとめを作れなかった（#{collection}）: #{inspect(reason)}")

  defp log(_collection, _result), do: :ok

  @doc """
  止まった理由の言い方。**画面にも通知にも、次に何をすればよいかまで出します**。
  """
  def error_text(:chiezo_not_configured), do: "Chiezo の場所が設定されていません。"
  def error_text(:collection_disabled), do: "この収集は Chiezo 側で止まっています。"
  def error_text(:not_requested), do: "まだ収集を依頼していません。"
  def error_text(:chiezo_busy), do: "Chiezo がいま別の依頼を抱えています。少し待ってください。"
  def error_text(:timed_out), do: "Chiezo の返事を待ちましたが、時間内に終わりませんでした。"
  def error_text(:ntfy_topic_missing), do: "この話題の通知先が決まっていません。"
  def error_text(:ntfy_base_url_missing), do: "ntfy の場所が決まっていません。"
  def error_text({:chiezo_refused, _status, reason}) when is_binary(reason), do: reason
  def error_text(_reason), do: "まとめを作れませんでした。"
end
