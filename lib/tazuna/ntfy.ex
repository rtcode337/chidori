defmodule Tazuna.Ntfy do
  @moduledoc """
  ntfy へ知らせる口。**宛先（トピックと場所）は全部の通知で 1 つ**で、話題ごとに
  決めるのは知らせるかどうかだけです。

  **宛先は設定画面の「通知」タブで直せます**（`Tazuna.Notify.Destination`）。宛先は運用しながら
  決めるもの（試しに別のトピックへ流す、しばらく止める）なので、環境変数だけだと
  変えるたびに立て直しが要ります。**置き場の既定は環境変数から取ります**
  （`NTFY_BASE_URL`）—— あれは環境の事情なので、画面で毎回書かせるものではありません。

  **宛先が空なら何もしません。** そこが「知らせない」の意思表示です ——
  **既定の宛先は持ちません**。勝手に決めると、**公開の ntfy では誰でも読めるところ**
  へ流れかねません（推測できる名前ほど危ない）。

  **場所のほうは書かなければ公式の公開サーバー**（`https://ntfy.sh`）へ倒します。
  宛先だけ書いた人のところに何も飛ばず、その理由が画面の隅にしか出ないほうが困ります。

  **送るのはプレーンテキストです。** ntfy は本文の URL を自分でリンクにするので、
  見出しに差し替えず URL のまま渡します（画面のほうは逆で、記事の見出しにします）。
  """

  alias Tazuna.Http
  alias Tazuna.Notify.Destination
  alias Tazuna.Notify.Settings

  # **書かなければ公式の公開サーバーへ倒します。** 場所を書かせないと、宛先だけ
  # 書いた人のところには何も飛ばず、しかもその理由は画面の隅にしか出ません
  # （実際、宛先だけ入れて静かに送れずにいた）。**送るかどうかを決めるのは宛先**で、
  # そこが空なら何も飛びません —— 場所の既定を持っても、その性質は変わりません
  @public_base_url "https://ntfy.sh"

  @user_agent "chidori"
  @timeout 10_000
  @connect_timeout 5_000

  @doc """
  ntfy のルートURL の既定。`NTFY_BASE_URL` で決めます（画面から上書きできます）。
  """
  def default_base_url do
    case System.get_env("NTFY_BASE_URL") do
      nil -> @public_base_url
      "" -> @public_base_url
      value -> value |> String.trim() |> String.trim_trailing("/")
    end
  end

  @doc "書かなかったときに倒れる先（公式の公開サーバー）。画面にも出します。"
  def public_base_url, do: @public_base_url

  @doc """
  置き場。**画面（設定の「通知」タブ）で書いてあればそちらが勝ちます**。
  """
  def base_url do
    case Destination.get().base_url do
      "" -> default_base_url()
      written -> written
    end
  end

  @doc """
  宛先（ntfy のトピック）。**全部の通知で 1 つ**です —— 話題ごとに持たせていた頃は、
  同じトピックを画面ごとに書き写していて、変えるときに全部を回る羽目になっていました。
  """
  def topic do
    case Destination.get().topic do
      "" -> nil
      topic -> topic
    end
  end

  @doc """
  その話題を知らせられる状態か。**押す前に読めるようにするため**に、理由まで返します。

  - `:notify_off` —— その話題は知らせない設定（話題の画面の「知らせる」）
  - `:ntfy_topic_missing` —— 宛先が決まっていない（設定の「通知」タブ）
  """
  def ready(collection) do
    cond do
      not Settings.get(collection).notify -> {:error, :notify_off}
      topic() == nil -> {:error, :ntfy_topic_missing}
      true -> {:ok, {base_url(), topic()}}
    end
  end

  @doc """
  1 件知らせます。

  **JSON で送ります。** ヘッダに見出しを載せる書き方もありますが、あちらは
  ASCII の前提があり、日本語の見出しが黙って化けます。
  """
  def notify(collection, title, body, opts \\ []) do
    with {:ok, {base, topic}} <- ready(collection) do
      payload =
        %{topic: topic, title: title, message: body}
        |> put_unless_nil(:click, opts[:click])
        |> put_unless_nil(:tags, opts[:tags])
        |> Jason.encode!()

      case Http.post(base <> "/", payload,
             headers: [{"user-agent", @user_agent}],
             content_type: "application/json",
             timeout: @timeout,
             connect_timeout: @connect_timeout
           ) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: status}} -> {:error, {:ntfy_status, status}}
        {:error, _reason} -> {:error, :ntfy_unavailable}
      end
    end
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, _key, []), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
