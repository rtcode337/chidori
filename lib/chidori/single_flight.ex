defmodule Chidori.SingleFlight do
  @moduledoc """
  同じ仕事を同時に 2 本走らせないための札（鍵ごとに 1 本だけ）。

  AI を動かす依頼（まとめ・割り込み・区画の実行など）は、押すたびに Chiezo へ
  1 回ずつ届きます。走っている最中にもう一度押されたり、別のタブから同じものを
  押されたりすると、同じ依頼が重なって枠だけを食います。ここで鍵を取れたものだけを
  走らせ、取れなかったものは `{:error, :busy}` で断ります。

  札は走らせているプロセスが持ちます（`Registry`）。**終われば外れ、落ちても外れる**
  ので、外し忘れて二度と押せなくなることはありません。

  - `run/2` —— 呼んだプロセスで鍵を取って走らせる（`start_async` の中で使う）
  - `start/2` —— `Chidori.TaskSupervisor` の下で走らせ、鍵を取れたかをその場で返す
  - `busy?/1` —— いま走っているか（押した直後に断るための下見。確かめるのは `run/2`）
  """

  @registry __MODULE__

  @doc "札を置く `Registry` の子の定義（`Chidori.Application` が立てる）。"
  def child_spec(_opts), do: Registry.child_spec(keys: :unique, name: @registry)

  @doc "その鍵の仕事がいま走っているか。"
  # 終わったプロセスの札は Registry が後から片付けるので、生きているものだけを数える
  def busy?(key),
    do: Enum.any?(Registry.lookup(@registry, key), fn {pid, _value} -> Process.alive?(pid) end)

  @doc """
  呼んだプロセスで鍵を取ってから `fun` を走らせ、その戻り値を返します。
  取れなければ走らせずに `{:error, :busy}`。
  """
  def run(key, fun) when is_function(fun, 0) do
    case Registry.register(@registry, key, nil) do
      {:ok, _owner} ->
        try do
          fun.()
        after
          Registry.unregister(@registry, key)
        end

      {:error, {:already_registered, _pid}} ->
        {:error, :busy}
    end
  end

  @doc """
  `Chidori.TaskSupervisor` の下で `fun` を走らせます。**鍵を取れたかは待って返します**
  （`{:ok, pid}` か `{:error, :busy}`）—— 押した人に「もう走っています」をその場で出すため。
  """
  def start(key, fun) when is_function(fun, 0) do
    caller = self()
    ref = make_ref()

    {:ok, pid} =
      Task.Supervisor.start_child(Chidori.TaskSupervisor, fn ->
        case Registry.register(@registry, key, nil) do
          {:ok, _owner} ->
            send(caller, {ref, :ok})
            fun.()

          {:error, {:already_registered, _pid}} ->
            send(caller, {ref, :busy})
        end
      end)

    monitor = Process.monitor(pid)

    receive do
      {^ref, :ok} ->
        Process.demonitor(monitor, [:flush])
        {:ok, pid}

      {^ref, :busy} ->
        Process.demonitor(monitor, [:flush])
        {:error, :busy}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:not_started, reason}}
    end
  end
end
