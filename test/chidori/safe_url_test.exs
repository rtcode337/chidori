defmodule Chidori.SafeUrlTest do
  @moduledoc """
  外から来た URL をリンク・画像の宛先にしてよいか。**通すのは http・https で
  名前のあるものだけ**（画像は Chidori 自身が配るパスも）。
  """

  use ExUnit.Case, async: true

  alias Chidori.SafeUrl

  test "http・https の URL はそのまま返す" do
    assert SafeUrl.href("https://example.com/a?b=1") == "https://example.com/a?b=1"
    assert SafeUrl.href("http://192.0.2.1:8080/") == "http://192.0.2.1:8080/"
    assert SafeUrl.href("HTTPS://example.com/") == "HTTPS://example.com/"
  end

  test "押すと画面の中で何かが走る宛先や、壊れたものは通さない" do
    for url <- [
          "javascript:alert(1)",
          "JavaScript:alert(1)",
          " javascript:alert(1)",
          "data:text/html,<script>alert(1)</script>",
          "vbscript:msgbox(1)",
          "file:///etc/passwd",
          "https://",
          "http:///path",
          "//example.com/x",
          "/relative",
          "",
          <<0xFF, 0xFE>>,
          nil,
          123
        ] do
      assert SafeUrl.href(url) == nil, inspect(url)
    end
  end

  test "画像は Chidori 自身が配るパスも通す（別のホストを指すものは通さない）" do
    assert SafeUrl.src("/thumbs/abc.webp") == "/thumbs/abc.webp"
    assert SafeUrl.src("https://upload.example.org/a.jpg") == "https://upload.example.org/a.jpg"
    assert SafeUrl.src("//example.com/a.jpg") == nil
    assert SafeUrl.src("/\\example.com/a.jpg") == nil
    assert SafeUrl.src("javascript:alert(1)") == nil
    assert SafeUrl.src(nil) == nil
  end
end
