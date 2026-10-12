defmodule Chidori.SafeUrl do
  @moduledoc """
  外から来た URL をリンクや画像の宛先に使ってよいかを見る、ただ 1 つの口。

  Chiezo・AI・配信元が入れた URL は、そのまま `href` に置くと `javascript:` や
  `data:` のような、押した瞬間に画面の中で何かを走らせる宛先が紛れ込みます。
  **通すのは http と https で、名前（ホスト）があるものだけ**です。それ以外は `nil` を
  返すので、テンプレートでは `href={SafeUrl.href(url)}` と書けば、通らないものは
  `href` の無いただの文字になります。

  画面の手前（読み込むところ）でも、テンプレートでも同じ関数を使います。
  チェックを 1 か所にまとめておかないと、片方だけ直って食い違います。
  """

  @doc """
  http・https の URL ならそのまま返し、それ以外（ほかの scheme・相対パス・壊れた URL・
  文字列でないもの）は `nil`。
  """
  def href(url) when is_binary(url) do
    with true <- String.valid?(url),
         %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) <-
           URI.parse(url),
         true <- host != "" and String.downcase(scheme) in ["http", "https"] do
      url
    else
      _other -> nil
    end
  end

  def href(_url), do: nil

  @doc """
  画像の宛先（`src`）用。`href/1` が通すものに加えて、Chidori 自身が配る絵を指す
  ルートからのパス（`/thumbs/…`・`/faces/…`）も通します。`//` で始まるもの
  （別のホストを指す）と `/\\` で始まるもの（ブラウザが `//` と読む）は通しません。
  """
  def src("/" <> rest = path) when is_binary(path) do
    if String.valid?(path) and not String.starts_with?(rest, ["/", "\\"]), do: path, else: nil
  end

  def src(url), do: href(url)
end
