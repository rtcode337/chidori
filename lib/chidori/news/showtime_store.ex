defmodule Chidori.News.ShowtimeStore do
  @moduledoc """
  上映スケジュールを調べている最中か、前に調べた結果（`Chidori.News.Showtimes`）を置いておくところ。

  **答えを押した画面に直接送らない。** 調べるのに数十秒〜数分かかり、そのあいだに画面を移ると
  受け取り手が消えて、AI の枠を使った答えが捨てられていた（調べる処理は裏で最後まで走る）。
  ここに置いて `topic/0` で知らせ、映画の画面は開いたときにここを読む —— 画面を移っても、
  別の端末で開いても、同じ答えが読める。

  **置くのは最後の 1 回ぶんだけ、プロセスの中に**（再起動すると消える）。上映時刻は
  その日のうちに古くなるもので、残しておく理由が無い。
  """

  use Agent

  @topic "showtimes"

  def start_link(_opts),
    do: Agent.start_link(fn -> %{state: nil, form: %{}} end, name: __MODULE__)

  @doc "変わったときに知らせる PubSub の話題（`{:showtimes, state}` が届く）。"
  def topic, do: @topic

  @doc "いまの状態（`nil` / `:loading` / `{:ok, 結果}` / `{:error, 理由}`）と、頼んだときのフォームの値。"
  def get do
    Agent.get(__MODULE__, & &1)
  catch
    # 立てていない（テストで部品だけ動かすとき）
    :exit, _reason -> %{state: nil, form: %{}}
  end

  @doc "調べ始めた（フォームの値も覚える）。"
  def started(form), do: put(:loading, form)

  @doc "調べ終えた（結果か理由）。"
  def finished(result), do: put(result, nil)

  # **置けなくても知らせは出す**（置き場を立てる前から動いている Chidori でも、
  # 開いている画面には答えが届くように）
  defp put(state, form) do
    try do
      Agent.update(__MODULE__, fn current -> %{state: state, form: form || current.form} end)
    catch
      :exit, _reason -> :ok
    end

    Phoenix.PubSub.broadcast(Chidori.PubSub, @topic, {:showtimes, state})
  end
end
