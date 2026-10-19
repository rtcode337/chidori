defmodule Chidori.News.AskStore do
  @moduledoc """
  AI に頼んで答えを待っているあいだの状態と、前の答えを置いておくところ。
  いまは 2 つ —— 上映スケジュール（`:showtimes`。`Chidori.News.Showtimes`）と、
  映画館を探した答え（`:theater_search`。`Chidori.News.TheaterFinder`）。

  **答えを押した画面に直接送らない。** 答えるのに数十秒〜数分かかり、そのあいだに画面を移ると
  受け取り手が消えて、AI の枠を使った答えが捨てられていた（頼んだ処理は裏で最後まで走る）。
  ここに置いて PubSub で知らせ（`{鍵, 状態}`）、画面は開いたときにここを読む —— 画面を移っても、
  別の端末で開いても、同じ答えが読める。

  **置くのは鍵ごとに最後の 1 回ぶんだけ、プロセスの中に**（再起動すると消える）。
  上映時刻はその日のうちに古くなり、探した映画館はまた頼めばよいので、残しておく理由が無い。
  """

  use Agent

  @keys [:showtimes, :theater_search]
  @empty %{state: nil, form: %{}}

  def start_link(_opts),
    do: Agent.start_link(fn -> Map.new(@keys, &{&1, @empty}) end, name: __MODULE__)

  @doc "変わったときに知らせる PubSub の話題（`{鍵, 状態}` が届く）。"
  def topic(key) when key in @keys, do: "ask:#{key}"

  @doc "いまの状態（`nil` / `:loading` / `{:ok, 答え}` / `{:error, 理由}`）と、頼んだときのフォームの値。"
  def get(key) when key in @keys do
    Agent.get(__MODULE__, &Map.get(&1, key, @empty))
  catch
    # 立てていない（テストで部品だけ動かすとき）
    :exit, _reason -> @empty
  end

  @doc "頼み始めた（フォームの値も覚える）。"
  def started(key, form), do: put(key, :loading, form)

  @doc "答えが返った（答えか理由）。"
  def finished(key, result), do: put(key, result, nil)

  # **置けなくても知らせは出す**（置き場を立てる前から動いている Chidori でも、
  # 開いている画面には答えが届くように）
  defp put(key, state, form) when key in @keys do
    try do
      Agent.update(__MODULE__, fn all ->
        current = Map.get(all, key, @empty)
        Map.put(all, key, %{state: state, form: form || current.form})
      end)
    catch
      :exit, _reason -> :ok
    end

    Phoenix.PubSub.broadcast(Chidori.PubSub, topic(key), {key, state})
  end
end
