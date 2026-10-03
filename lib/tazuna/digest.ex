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
  4. **興味トピックを選んでいれば、興味トピックの要約も書かせて知らせる**
     （ふつうのまとめとは別の 1 本。`Tazuna.News.interest_digest_prompt/1`）。
     ふつうのまとめを先に知らせるのは、興味の要約を待つあいだ、いつもの知らせを
     遅らせないため。**興味の要約で止まっても、ふつうのまとめの結果は変えません**

  **起こした先は待ってくれません。** Chiezo の口は run も割り込みも「起こした」まで
  返すので、終わったかどうかはこちらが読み直して確かめます —— 整理は収集の前回時刻が
  進んだか、まとめは見出しが変わったかで見ます。

  **取り込みが混んでいても、その回を落としません。** Chiezo は取り込み中の依頼を
  積まずに断る（409）ので、断られたら空くのを待って頼み直します
  （`Chiezo.when_free/2`）。待つのは次の予定の時刻まで —— 定時の時計が渡します。
  画面から押したときは 1 時間までです。

  **途中で止まっても黙りません。** どの段で止まったかは画面に出し、知らせ済みの
  まとめを二度知らせることはしません（`Tazuna.Notify` が覚えています）。
  """

  require Logger

  alias Tazuna.Chiezo
  alias Tazuna.Jst
  alias Tazuna.News
  alias Tazuna.News.Interests
  alias Tazuna.Notify
  alias Tazuna.Notify.Settings

  # 読み直す間隔と、各段で待つ上限。**待つのは分の単位** —— AI が読んで書くので、
  # 秒で返るものではない。
  #
  # **Chiezo が混んでいる時間を見込んで 30 分ずつ待つ。** Chiezo の取り込みは収集を
  # 1 本ずつ焼くので、ほかの収集（1 回 8 分かかるものもある）が並んでいると、
  # 起こした回が順番を待つ。整理 10 分・まとめ 15 分で切っていた頃は、混んでいた朝に
  # 「時間内に終わりませんでした」で止まり、その日のまとめが作られなかった
  # （読む側の 売買提案のアプリ は、まとめ無しで売買提案を書くことになる）。
  # まとめを作る時刻は、読む側より 1 時間ほど前に置く前提（README）
  @poll_ms 15_000
  @refine_wait_ms 30 * 60 * 1000
  @digest_wait_ms 30 * 60 * 1000

  # まとめを読むだけなので、1 件も取れれば足りる（画面の一覧はこちらでは使わない）
  @samples 5

  # 画面から押したときに、取り込みが空くのを待つ上限
  @manual_wait_ms 60 * 60 * 1000

  @refine_sweep Tazuna.SweepNames.tidy()
  @digest_sweep Tazuna.SweepNames.digest()

  # 割り込みに添える頼みごと。**Chiezo は指示文の無い割り込みを断ります** ——
  # 依頼文そのものは巡回の定義にあるので、ここは「この回で何をしてほしいか」だけ
  @digest_note "定時のまとめです。前回のまとめから今回までに入ったものを1件にまとめてください。" <>
                 "既にある記事は書き換えないでください。"

  @interest_note "定時の、興味トピックの要約です。前回から今回までに入ったもののうち、" <>
                   "選ばれた興味トピックに関わるものを1件にまとめてください。" <>
                   "既にある記事は書き換えないでください。"

  # 興味の要約を待つとき、前の 1 件を見つけるために読む件数
  @interest_samples 20

  @doc """
  その話題のまとめを作らせて、知らせます。**数分かかります**。

  呼ぶ側を待たせないので、走らせるのは `Tazuna.TaskSupervisor` の下です。
  """
  def start(topic) do
    Task.Supervisor.start_child(Tazuna.TaskSupervisor, fn -> run(topic) end)
  end

  @doc """
  取り込みが空くのを待つ上限（`System.monotonic_time(:millisecond)` の値）。
  **画面から押したとき**のもの —— 定時の回は、時計が次の予定の時刻を渡します。
  """
  def manual_deadline, do: System.monotonic_time(:millisecond) + @manual_wait_ms

  @doc """
  段取りを順に踏みます。**戻るのは最後まで行った結果**です。
  """
  def run(topic, free_by \\ nil)

  def run(%{collection: collection}, free_by) do
    case News.chiezo_base_url() do
      nil ->
        {:error, :chiezo_not_configured}

      base ->
        result = walk(base, topic_of(collection), free_by || manual_deadline())
        # 画面はこの後の状態を見る（まとめが入れ替わっているので）
        News.refresh(News.server(collection))
        log(collection, result)

        # **どう終わったかを残す。** 誰も見ていない時刻に走る回なので、残さないと
        # 知らせが来なかった理由がログにしか無い
        Settings.mark_digest_result(collection, result_text(result))
        result
    end
  end

  def run(_topic, _free_by), do: {:error, :no_topic}

  # `free_by` までは、取り込みが空くのを待って頼み直す（断られても、その回を落とさない）
  defp walk(base, topic, free_by) do
    collection = topic.collection

    with {:ok, before} <- Chiezo.collection(base, collection, @samples),
         :ok <- enabled(before),
         :ok <- tell(collection, "整理を起こしています…"),
         :ok <-
           Chiezo.when_free(
             fn -> busy_told(collection, Chiezo.run(base, collection, sweep: @refine_sweep)) end,
             free_by
           ),
         :ok <- wait_for_run(base, collection, before[:last_run_at], deadline(@refine_wait_ms)),
         :ok <- tell(collection, "まとめを書かせています…"),
         :ok <-
           Chiezo.when_free(
             fn ->
               busy_told(
                 collection,
                 Chiezo.focus(
                   base,
                   collection,
                   @digest_note,
                   digest_titles(base, topic),
                   @digest_sweep
                 )
               )
             end,
             free_by
           ),
         {:ok, digest} <-
           wait_for_digest(base, collection, digest_title(before), deadline(@digest_wait_ms)) do
      delivered = deliver_if_set(collection, digest)
      interest_round(base, collection, free_by)
      delivered
    end
  end

  # 定義の話題（無ければ名前だけの入れ物。要約の材料を名指ししない話題と同じ扱いになる）
  defp topic_of(collection), do: Tazuna.Topics.get(collection) || %{collection: collection}

  # 要約の材料として**名指しする**もの。**要約は割り込みとして起こす**ので、依頼文が
  # いま入っているもの（`{current}`）を読む話題では、名指ししないと差し込みが空になる
  # （割り込みの `{current}` は名指しした見出しだけ —— 映画の要約が材料 0 件で空振りした）。
  # 名指しするかは作り方のモジュールが決める（`digest_titles/2`。記事を溜める話題は
  # `{recent}` を読むので要らない）
  defp digest_titles(base, topic) do
    case Tazuna.Topics.works(topic) do
      nil ->
        []

      works ->
        if function_exported?(works, :digest_titles, 2),
          do: works.digest_titles(base, topic),
          else: []
    end
  end

  # **知らせるのは通知先があるときだけ。** 時刻は「要約を作る時刻」で、通知はその後に
  # 付いてくるもの —— 通知先が無いのは「知らせない」の意思表示で、失敗ではない
  # （失敗として残すと、要約はできているのに画面に「止まりました」と出る）
  defp deliver_if_set(collection, digest) do
    case Tazuna.Ntfy.ready(collection) do
      {:ok, _ready} ->
        tell(collection, "知らせています…")
        Notify.deliver(collection, digest)

      {:error, :ntfy_topic_missing} ->
        {:ok, :made}
    end
  end

  # 興味トピックの要約。**選んでいなければ何もしない**（書く材料が無い）。
  # ここで止まっても、ふつうのまとめの結果は変えない（画面とログにだけ残す）
  defp interest_round(base, collection, free_by) do
    if Interests.list(collection) == [] do
      :skipped
    else
      result =
        with {:ok, before} <- Chiezo.collection(base, collection, @interest_samples),
             :ok <- tell(collection, "興味トピックの要約を書かせています…"),
             :ok <-
               Chiezo.when_free(
                 fn ->
                   busy_told(
                     collection,
                     Chiezo.focus(
                       base,
                       collection,
                       @interest_note,
                       [],
                       News.interest_digest_sweep()
                     )
                   )
                 end,
                 free_by
               ),
             {:ok, digest} <-
               wait_for_interest_digest(
                 base,
                 collection,
                 interest_title(before),
                 deadline(@digest_wait_ms)
               ) do
          deliver_if_set(collection, digest)
        end

      case result do
        {:error, reason} ->
          Logger.warning("#{collection} の興味トピックの要約: #{inspect(reason)}")
          tell(collection, "興味トピックの要約は作れませんでした（#{error_text(reason)}）")

        _done ->
          :ok
      end

      result
    end
  end

  defp interest_title(%{recent: recent}) do
    case News.to_interest_digests(recent) do
      [%{title: title} | _rest] -> title
      _none -> nil
    end
  end

  # 興味の要約ができたか。ふつうのまとめと同じく**見出しで見る**
  defp wait_for_interest_digest(base, collection, before, deadline) do
    poll(deadline, fn ->
      with {:ok, %{recent: recent}} <- Chiezo.collection(base, collection, @samples),
           [digest | _rest] <- News.to_interest_digests(recent),
           true <- digest.title != before do
        [full | _rest] = News.with_body([digest], base, collection)
        {:done, {:ok, full}}
      else
        _other -> :wait
      end
    end)
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

  # 断られたら、待っていることを画面へ（黙って待つと、止まったように見える）
  defp busy_told(collection, {:error, :chiezo_busy} = busy) do
    tell(collection, "Chiezo が取り込み中なので、空くのを待っています…")
    busy
  end

  defp busy_told(_collection, result), do: result

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

  @doc false
  # 画面に出す一言。**いつ・どうなったか**を 1 行で（次に何をすればよいかまで）。
  #
  # **これは記録で、いまの状態ではありません。** 画面側が「前回の定時の回」として
  # 見出しを付けるので、ここは時刻と顛末だけを書きます —— 混ざると、ずっと前に
  # 止まった回の理由が、いまの状態として読まれます（実際にそう読まれました）。
  def result_text(result) do
    Jst.format(DateTime.utc_now()) <> " — " <> outcome(result)
  end

  defp outcome({:ok, :sent}), do: "まとめを作って知らせました。"
  defp outcome({:ok, :made}), do: "まとめを作りました（通知先が無いので知らせていません）。"
  defp outcome({:ok, :already_sent}), do: "まとめを作りましたが、同じものは知らせ済みでした。"

  defp outcome({:ok, :nothing_to_send}),
    do: "まとめを作りましたが、知らせるものがありませんでした。"

  # **理由は「そのときの」と断る。** 理由の文はいまの状態を指す言い回し
  # （「止まっています」など）で、押した直後の画面にも同じものを出すため
  defp outcome({:error, reason}), do: "止まりました。そのときの理由: " <> error_text(reason)
  defp outcome(_other), do: "終わりました。"

  @doc """
  止まった理由の言い方。**画面にも通知にも、次に何をすればよいかまで出します**。
  """
  def error_text(:chiezo_not_configured), do: "Chiezo の場所が設定されていません。"
  def error_text(:collection_disabled), do: "この収集は Chiezo 側で止まっています。"
  def error_text(:not_requested), do: "まだ収集を依頼していません。"

  def error_text(:chiezo_busy),
    do: "次の予定の時刻まで待ちましたが、Chiezo の取り込みが空きませんでした。"

  def error_text(:timed_out), do: "Chiezo の返事を待ちましたが、時間内に終わりませんでした。"
  def error_text(:ntfy_topic_missing), do: "この話題の通知先が決まっていません。"
  def error_text({:chiezo_refused, _status, reason}) when is_binary(reason), do: reason
  def error_text(_reason), do: "まとめを作れませんでした。"
end
