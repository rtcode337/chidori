defmodule Tazuna.Notify.Watcher do
  @moduledoc """
  まとめが出ていないかを時々見に行って、出ていたら知らせるところ。

  **誰かが画面を開くのを待てません。** Chiezo は勝手に集めて、まとめもあちらで
  できます。tazuna は読みに行く側なので、**開かれるまで読まない作り**だと、
  通知は「誰かが画面を見たとき」にしか飛びません —— それでは通知の意味がありません。

  **宛先を設定した話題だけ見に行きます。** 設定していない話題まで読みに行くと、
  誰も待っていない問い合わせで Chiezo を叩き続けることになります。

  **知らせるかどうかの判断はここでしません**（`Tazuna.Notify`）。ここがやるのは
  「読みに行く」ことと「届いた状態を渡す」ことだけです。
  """

  use GenServer

  alias Tazuna.News
  alias Tazuna.Notify
  alias Tazuna.Ntfy
  alias Tazuna.Topics

  require Logger

  # 見に行く間隔。**まとめができるのは 12 時間ごと**なので、1 時間で十分に細かい
  # （短くしても早くは届かず、Chiezo への問い合わせが増えるだけ）
  @default_minutes 60
  # 立ち上げ直後は少し待つ。**起動の並びに頼らない** —— Chiezo も DB も、
  # こちらが動き出す頃には居るはずだが、居なくても落ちないほうがよい
  @first_delay_ms 30_000

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @impl true
  def init(_options) do
    for topic <- watched(), do: News.subscribe(topic.collection)
    schedule(@first_delay_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:look, state) do
    for topic <- watched() do
      # **読み直させるだけ。** 結果は購読しているので、届いたところで知らせる
      News.refresh(News.server(topic.collection))
    end

    schedule(interval_ms())
    {:noreply, state}
  end

  # 読み直しが終わった知らせ。**まだ読めていないものは触らない** ——
  # 途中の状態で「まとめが無い」と読むと、次の回まで黙ることになる
  def handle_info({:news_updated, %{status: :ready, name: collection} = news}, state) do
    case Topics.get(collection) do
      nil ->
        {:noreply, state}

      topic ->
        case Notify.deliver_latest(topic, news) do
          {:ok, :sent} -> Logger.info("まとめを知らせた（#{collection}）")
          _other -> :ok
        end

        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  見に行く話題。**宛先を設定したものだけ**。
  """
  def watched do
    Enum.filter(Topics.list(), &(Ntfy.topic_for(&1.collection) != nil))
  end

  @doc "見に行く間隔（分）。`TAZUNA_NOTIFY_MINUTES` で変えられます。"
  def interval_minutes do
    case System.get_env("TAZUNA_NOTIFY_MINUTES", "") |> String.trim() |> Integer.parse() do
      {minutes, _rest} when minutes > 0 -> minutes
      _unset -> @default_minutes
    end
  end

  defp interval_ms, do: interval_minutes() * 60 * 1_000

  defp schedule(after_ms), do: Process.send_after(self(), :look, after_ms)
end
