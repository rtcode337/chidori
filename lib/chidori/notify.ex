defmodule Chidori.Notify do
  @moduledoc """
  まとめを知らせるところ。

  **知らせるのは、新しくできたまとめ 1 件と、画面で押されたときだけ**です
  （`Chidori.Digest` と最新情報の「知らせる」）。Chiezo に溜まったまとめを読み直して
  知らせ漏れを探すことはしないので、「何を知らせたか」の記録は持ちません ——
  持っていた頃（表 `sent_notices`）も、効いていたのは画面の「最後に知らせた時刻」だけでした。
  その時刻は話題の設定に 1 つだけ控えます（`Chidori.Notify.Settings.mark_sent/2`）。
  """

  alias Chidori.News
  alias Chidori.Notify.Settings
  alias Chidori.Ntfy

  require Logger

  @doc """
  その話題のいちばん新しいまとめを知らせます。

  **知らせないときも理由を返します** —— 無言で何もしないと、設定を間違えているのか
  まとめがまだ無いのかを、後から見ている人が区別できません。
  """
  def deliver_latest(collection, %{digests: digests}, opts \\ []) do
    case List.first(digests) do
      nil -> {:ok, :nothing_to_send}
      digest -> deliver(collection, digest, opts)
    end
  end

  @doc """
  まとめ 1 件を知らせます。`opts` は呼び出し側との互換のために受け取るだけです
  （知らせ済みかどうかを見ないので、`force` の有無で動きは変わりません）。
  """
  def deliver(collection, digest, _opts \\ []) do
    with {:ok, _ready} <- Ntfy.ready(collection) do
      send_and_record(collection, digest)
    end
  end

  @doc """
  その話題へ最後に知らせた時刻。**押した結果がここに出ます**。
  """
  def last_sent_at(collection), do: Settings.get(collection).last_sent_at

  defp send_and_record(collection, digest) do
    case Ntfy.notify(collection, digest.title, News.digest_text(digest),
           click: click_url(collection)
         ) do
      :ok ->
        Settings.mark_sent(collection, DateTime.utc_now())
        {:ok, :sent}

      {:error, reason} ->
        # 届かなかったものは時刻を進めない（画面に「知らせた」と出さない）
        Logger.warning("ntfy へ知らせられなかった（#{collection}）: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc false
  # 押したときに開く先。**通知の 1 行だけでは足りない**ので、続きを読む場所を添える。
  #
  # **手元しか指せないときは添えません**（`PHX_HOST` が既定のまま）。通知を開くのは
  # たいてい別の機械 —— 電話で押しても `localhost` は自分自身を指すので、開けない
  # リンクが付くだけです。**添えなければ、その通知は本文をそのまま扱えます**
  # （ntfy の画面で写す・共有する）。
  def click_url(collection, url \\ ChidoriWeb.Endpoint.url()) do
    if local?(url),
      do: nil,
      else: url <> "/news?view=" <> URI.encode_www_form(collection)
  end

  defp local?(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        host in ["localhost", "127.0.0.1", "0.0.0.0", "::1"]

      _uri ->
        true
    end
  end
end
