defmodule Tazuna.Ntfy do
  @moduledoc """
  ntfy へ知らせる口。**話題ごとに宛先（トピック）を決めます**。

  **未設定なら何もしません。** サーバーの場所か宛先のどちらかが空なら、その話題は
  知らせない、という意味です —— 既定の宛先を勝手に決めると、**公開の ntfy では
  誰でも読めるところ**へ流れかねません（推測できる名前ほど危ない）。

  **送るのはプレーンテキストです。** ntfy は本文の URL を自分でリンクにするので、
  見出しに差し替えず URL のまま渡します（画面のほうは逆で、記事の見出しにします）。
  """

  alias Tazuna.Http

  @user_agent "tazuna/0.1 (+https://github.com/rtcode337/tazuna)"
  @timeout 10_000
  @connect_timeout 5_000

  @doc """
  ntfy のルートURL。**未設定ならこの機能は使えません**。
  """
  def base_url do
    case System.get_env("NTFY_BASE_URL") do
      nil -> nil
      "" -> nil
      value -> value |> String.trim() |> String.trim_trailing("/")
    end
  end

  @doc """
  その収集の宛先（ntfy のトピック）。

  **収集ごとに別に決められます**（`TAZUNA_<収集名>_NTFY_TOPIC`）。同じところへ
  まとめて流すと、技術の話を追いたいだけの人に暮らしの話まで届きます。
  """
  def topic_for(collection) when is_binary(collection) do
    case collection |> env_name() |> System.get_env("") |> String.trim() do
      "" -> nil
      topic -> topic
    end
  end

  def topic_for(_collection), do: nil

  @doc """
  その収集の宛先を決める環境変数の名前。**画面に出すので公開しています** ——
  設定していないときに「どこへ書けばよいか」が読めないと、設定しようがありません。
  """
  def env_name(collection) when is_binary(collection),
    do: String.upcase(collection) <> "_NTFY_TOPIC"

  @doc """
  知らせられる状態か。**押す前に読めるようにするため**に、理由まで返します。
  """
  def ready(collection) do
    cond do
      is_nil(base_url()) -> {:error, :ntfy_not_configured}
      is_nil(topic_for(collection)) -> {:error, {:ntfy_topic_missing, env_name(collection)}}
      true -> {:ok, {base_url(), topic_for(collection)}}
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
