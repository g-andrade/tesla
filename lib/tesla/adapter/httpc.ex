defmodule Tesla.Adapter.Httpc do
  @moduledoc """
  Adapter for [httpc](http://erlang.org/doc/man/httpc.html).

  This is the default adapter.

  **NOTE** Tesla overrides default autoredirect value with false to ensure
  consistency between adapters
  """

  current_otp_version = List.to_integer(:erlang.system_info(:otp_release))

  @behaviour Tesla.Adapter
  import Tesla.Adapter.Shared, only: [stream_to_fun: 1, next_chunk: 1]
  alias Tesla.Multipart

  @override_defaults autoredirect: false
  @http_opts ~w(timeout connect_timeout ssl essl autoredirect proxy_auth version relaxed url_encode)a

  @impl Tesla.Adapter
  def call(env, opts) do
    opts = Tesla.Adapter.opts(@override_defaults, env, opts)
    opts = add_default_ssl_opt(env, opts)

    with {:ok, {status, headers, body}} <- request(env, opts) do
      {:ok, format_response(env, status, headers, body)}
    end
  end

  # TODO: remove this once OTP 25+ is required
  if current_otp_version >= 25 do
    def add_default_ssl_opt(env, opts) do
      default_ssl_opt = [
        ssl: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          depth: 3,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ],
          crl_check: true,
          crl_cache: {:ssl_crl_cache, {:internal, [http: 1000]}}
        ]
      ]

      Tesla.Adapter.opts(default_ssl_opt, env, opts)
    end
  else
    def add_default_ssl_opt(_env, opts) do
      opts
    end
  end

  defp format_response(env, {_, status, _}, headers, body) do
    %{env | status: status, headers: format_headers(headers), body: format_body(body)}
  end

  # from http://erlang.org/doc/man/httpc.html
  #   headers() = [header()]
  #   header() = {field(), value()}
  #   field() = string()
  #   value() = string()
  defp format_headers(headers) do
    for {key, value} <- headers do
      {String.downcase(to_string(key)), to_string(value)}
    end
  end

  # from http://erlang.org/doc/man/httpc.html
  #   string() = list of ASCII characters
  #   Body = string() | binary()
  defp format_body(data) when is_list(data), do: IO.iodata_to_binary(data)
  defp format_body(data) when is_binary(data), do: data

  defp request(env, opts) do
    content_type = to_charlist(Tesla.get_header(env, "content-type") || "")

    handle(
      request(
        env.method,
        Tesla.build_url(env.url, env.query) |> to_charlist,
        Enum.map(env.headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end),
        content_type,
        env.body,
        opts
      )
    )
  end

  # fix for # see https://github.com/teamon/tesla/issues/147
  defp request(:delete, url, headers, content_type, nil, opts) do
    request(:delete, url, headers, content_type, "", opts)
  end

  defp request(method, url, headers, _content_type, nil, opts) do
    :httpc.request(method, {url, headers}, http_opts(opts), adapter_opts(opts), profile(opts))
  end

  # These methods aren't able to contain a content_type and body
  defp request(method, url, headers, _content_type, _body, opts)
       when method in [:get, :options, :head, :trace] do
    :httpc.request(method, {url, headers}, http_opts(opts), adapter_opts(opts), profile(opts))
  end

  defp request(method, url, headers, _content_type, %Multipart{} = mp, opts) do
    headers = headers ++ Multipart.headers(mp)
    headers = for {key, value} <- headers, do: {to_charlist(key), to_charlist(value)}

    {content_type, headers} =
      case List.keytake(headers, ~c"content-type", 0) do
        nil -> {~c"text/plain", headers}
        {{_, ct}, headers} -> {ct, headers}
      end

    body = stream_to_fun(Multipart.body(mp))

    request(method, url, headers, to_charlist(content_type), body, opts)
  end

  defp request(method, url, headers, content_type, %Stream{} = body, opts) do
    fun = stream_to_fun(body)
    request(method, url, headers, content_type, fun, opts)
  end

  defp request(method, url, headers, content_type, body, opts) when is_function(body) do
    body = {:chunkify, &next_chunk/1, body}
    request(method, url, headers, content_type, body, opts)
  end

  defp request(method, url, headers, content_type, body, opts) do
    :httpc.request(
      method,
      {url, headers, content_type, body},
      http_opts(opts),
      adapter_opts(opts),
      profile(opts)
    )
  end

  defp handle({:error, {:failed_connect, _}}), do: {:error, :econnrefused}
  defp handle(response), do: response

  defp http_opts(opts), do: opts |> Keyword.take(@http_opts) |> Keyword.delete(:profile)

  defp adapter_opts(opts), do: opts |> Keyword.drop(@http_opts) |> Keyword.delete(:profile)

  defp profile(opts), do: opts[:profile] || :default
end
