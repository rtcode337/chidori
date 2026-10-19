defmodule Chidori.Notify do
  @moduledoc """
  まとめを知らせるところ（と、画面で頼んだ AI の答えが返ったことの知らせ。`deliver_notice/4`）。

  **知らせるのは、新しくできたまとめ 1 件と、画面で押されたときだけ**です
  （`Chidori.Digest` と最新情報の「知らせる」）。Chiezo に溜まったまとめを読み直して
  知らせ漏れを探すことはしないので、「何を知らせたか」の記録は持ちません ——
  持っていた頃（表 `sent_notices`）も、効いていたのは画面の「最後に知らせた時刻」だけでした。
  その時刻は話題の設定に 1 つだけ控えます（`Chidori.Notify.Settings.mark_sent/2`）。
  """

  alias Chidori.News
  alias Chidori.Notify.Settings
  alias Chidori.Ntfy
  alias Chidori.WebPush.Subscriptions

  require Logger

  @doc """
  その話題のいちばん新しいまとめを知らせます。

  **知らせないときも理由を返します** —— 無言で何もしないと、設定を間違えているのか
  まとめがまだ無いのかを、後から見ている人が区別できません。
  """
  def deliver_latest(collection, %{digests: digests}) do
    case List.first(digests) do
      nil -> {:ok, :nothing_to_send}
      digest -> deliver(collection, digest)
    end
  end

  @doc """
  まとめ 1 件を知らせます。**知らせ済みかどうかは見ません**（押されれば同じまとめでも
  もう一度送る。送ったことは画面の「最後に知らせた」に出ます）。

  **送り先は 2 つあり、両方へ送ります** —— ntfy（宛先が決まっていれば）と、
  登録した端末（Web Push。`Chidori.WebPush.Subscriptions`）。**どちらか 1 つでも
  届けば知らせた扱い**にします（画面の「最後に知らせた」を進める）。
  """
  def deliver(collection, digest) do
    with {:ok, channels} <- ready(collection) do
      send_and_record(collection, digest, channels)
    end
  end

  @doc """
  定時の回が止まったことを知らせます（`text` は理由の一言）。**まとめと同じ送り先へ**、
  知らせる設定の話題にだけ送ります —— 知らせを待っている人にとって、止まった回は
  「来ない」としか見えない。画面の記録（`last_digest_result`）は誰も見ていない時刻に
  書かれるので、気づくのは来ていないと思ったとき、になっていた。

  **「最後に知らせた」は進めません**（まとめを知らせたわけではないので）。
  """
  def deliver_failure(collection, text) when is_binary(text) do
    with {:ok, channels} <- ready(collection) do
      title = notice_title(collection, "まとめを作れませんでした")

      results =
        Enum.map(channels, fn
          :ntfy ->
            {:ntfy, Ntfy.notify(collection, title, text, click: click_url(collection))}

          :push ->
            sent =
              Subscriptions.deliver_all(title, text, open_path(collection),
                tag: "digest-failed-" <> collection
              )

            {:push,
             if(Enum.any?(sent, fn {_s, result} -> result == :ok end),
               do: :ok,
               else: {:error, :push_failed}
             )}
        end)

      for {channel, {:error, reason}} <- results do
        Logger.warning("#{channel} へ止まったことを知らせられなかった（#{collection}）: #{inspect(reason)}")
      end

      if Enum.any?(results, fn {_channel, result} -> result == :ok end),
        do: :ok,
        else: {:error, :not_delivered}
    end
  end

  @doc """
  話題に依らない知らせを送ります（映画館を探した答え・上映スケジュールのように、画面で頼んで
  数分かかる AI の答えが返ったとき）。**話題の「知らせる」は見ず**、ntfy の宛先と登録した端末の
  あるほうへ送ります —— 頼んだ本人に「終わった」と返すもので、まとめの知らせとは別のため。
  `path` は押したときに開く画面、`tag` は端末の通知を置き換える印（同じ種類の知らせは 1 つに）。
  `:ok`・`{:error, :no_destination}`・`{:error, :not_delivered}` のどれか。**「最後に知らせた」は進めません。**
  """
  def deliver_notice(title, text, path, tag) do
    channels =
      [ntfy: Ntfy.usable?(), push: Subscriptions.list() != []]
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    results =
      Enum.map(channels, fn
        :ntfy ->
          {:ntfy, Ntfy.notify_any(title, text, click: click_to(path))}

        :push ->
          sent = Subscriptions.deliver_all(title, text, path, tag: tag)

          {:push,
           if(Enum.any?(sent, fn {_s, result} -> result == :ok end),
             do: :ok,
             else: {:error, :push_failed}
           )}
      end)

    for {channel, {:error, reason}} <- results do
      Logger.warning("#{channel} へ知らせられなかった（#{tag}）: #{inspect(reason)}")
    end

    cond do
      channels == [] -> {:error, :no_destination}
      Enum.any?(results, fn {_channel, result} -> result == :ok end) -> :ok
      true -> {:error, :not_delivered}
    end
  end

  @doc """
  その話題を知らせられる状態か。返すのは送り先の並び（`:ntfy`・`:push`）。

  - `:notify_off` —— その話題は知らせない設定（話題の画面の「知らせる」）
  - `:no_destination` —— ntfy の宛先も、登録した端末も無い（設定の「通知」タブ）
  """
  def ready(collection) do
    if Settings.get(collection).notify do
      channels =
        [ntfy: Ntfy.usable?(), push: Subscriptions.list() != []]
        |> Enum.filter(&elem(&1, 1))
        |> Enum.map(&elem(&1, 0))

      if channels == [], do: {:error, :no_destination}, else: {:ok, channels}
    else
      {:error, :notify_off}
    end
  end

  @doc """
  その話題へ最後に知らせた時刻。**押した結果がここに出ます**。
  """
  def last_sent_at(collection), do: Settings.get(collection).last_sent_at

  defp send_and_record(collection, digest, channels) do
    results = Enum.map(channels, &{&1, send_to(&1, collection, digest)})

    for {channel, {:error, reason}} <- results do
      Logger.warning("#{channel} へ知らせられなかった（#{collection}）: #{inspect(reason)}")
    end

    # **1 つでも届けば知らせた扱い。** 全部だめなら時刻を進めない
    # （画面に「知らせた」と出すと、届いていないことに気づけない）
    if Enum.any?(results, fn {_channel, result} -> result == :ok end) do
      Settings.mark_sent(collection, DateTime.utc_now())
      {:ok, :sent}
    else
      [{_channel, error} | _rest] = results
      error
    end
  end

  defp send_to(:ntfy, collection, digest) do
    Ntfy.notify(collection, notice_title(collection, digest.title), News.digest_text(digest),
      click: click_url(collection)
    )
  end

  defp send_to(:push, collection, digest) do
    results =
      Subscriptions.deliver_all(
        notice_title(collection, digest.title),
        push_body(digest),
        open_path(collection),
        tag: "digest-" <> collection
      )

    cond do
      Enum.any?(results, fn {_s, result} -> result == :ok end) -> :ok
      Enum.all?(results, fn {_s, result} -> result == :expired end) -> {:error, :push_expired}
      true -> {:error, :push_failed}
    end
  end

  # 端末の通知に出す本文。**要旨だけを短く** —— 出典の URL は通知からは押せず、
  # 中身の大きさにも上限がある（配信先によっては 4KB）。続きは押して開いた画面で読む
  @push_body_length 180

  @doc false
  def push_body(digest) do
    text =
      digest
      |> News.digest_text()
      |> String.split("\n")
      |> Enum.reject(&(String.starts_with?(&1, "→") or &1 =~ ~r{\Ahttps?://}))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    if String.length(text) > @push_body_length,
      do: String.slice(text, 0, @push_body_length - 1) <> "…",
      else: text
  end

  @doc """
  通知の見出し。**どの話題のまとめか分かるように、話題の名前を頭に付けます** ——
  まとめの見出しは「まとめ: …（日時）」で、通知の一覧に並ぶと話題が読めない。
  「まとめ」で始まる見出しは「〈話題〉のまとめ: …」に、それ以外は「〈話題〉｜…」にします。
  """
  def notice_title(collection, title) do
    case Chidori.Topics.get(collection) do
      %{name: name} when is_binary(name) ->
        if String.starts_with?(title, "まとめ"),
          do: name <> "の" <> title,
          else: name <> "｜" <> title

      _unknown ->
        title
    end
  end

  @doc """
  通知を押したときに開く画面（その話題の最新情報で、**いちばん新しいまとめを全画面で開く**）。
  Web Push はこのまま使います（同じ場所の画面を開くので、相対の行き先で足りる）。
  """
  def open_path(collection),
    do: "/news?" <> URI.encode_query(view: collection, digest: "latest")

  @doc false
  # ntfy で押したときに開く先。**通知の 1 行だけでは足りない**ので、続きを読む場所を添える。
  # 開く画面は端末の通知と同じ（`open_path/1`）。
  #
  # **手元しか指せないときは添えません**（`PHX_HOST` が既定のまま）。通知を開くのは
  # たいてい別の機械 —— 電話で押しても `localhost` は自分自身を指すので、開けない
  # リンクが付くだけです。**添えなければ、その通知は本文をそのまま扱えます**
  # （ntfy の画面で写す・共有する）。
  def click_url(collection, url \\ ChidoriWeb.Endpoint.url()) do
    if local?(url),
      do: nil,
      else: url <> open_path(collection)
  end

  @doc false
  # 話題に依らない知らせの、ntfy で押したときに開く先（`click_url/2` と同じ決まり）
  def click_to(path, url \\ ChidoriWeb.Endpoint.url()) do
    if local?(url), do: nil, else: url <> path
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
