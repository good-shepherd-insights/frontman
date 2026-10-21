# Frontman Server
# Copyright (C) 2025 Frontman AI
#
# Licensed under the AGPL-3.0 — see LICENSE for details.
# Additional terms apply — see AI-SUPPLEMENTARY-TERMS.md

defmodule FrontmanServerWeb.Plugs.CORS do
  @moduledoc """
  CORS plug for cross-origin API requests.

  When used at the endpoint level, handles OPTIONS preflight requests
  before they reach the router.

  Protected API routes must remain bearer-token-only and must validate the
  request Origin against the bearer token. This plug deliberately does not set
  Access-Control-Allow-Credentials, so browser cookies are not exposed through
  credentialed cross-origin requests.

  ## Options

    * `:path_prefix` - Only apply CORS to paths starting with this prefix.
      Defaults to "/api".
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    path_prefix = Keyword.get(opts, :path_prefix, "/api")

    cond do
      String.starts_with?(conn.request_path, path_prefix) ->
        conn
        |> put_resp_header("access-control-allow-origin", "*")
        |> put_resp_header(
          "access-control-allow-methods",
          "GET, POST, PATCH, PUT, DELETE, OPTIONS"
        )
        |> put_resp_header("access-control-allow-headers", "authorization, content-type")
        |> handle_preflight()

      # The self-hosted browser client bundle is served cross-origin to the QA
      # page (same as api.frontman.sh serving app.frontman.sh assets). Echo the
      # request Origin and allow credentials: zone cookies (e.g. cf_zaraz) ride
      # along on cross-origin requests, and "ACAO: *" is rejected by browsers
      # for credentialed requests - which showed up as "Failed to fetch".
      String.starts_with?(conn.request_path, "/frontman-client") ->
        case get_req_header(conn, "origin") do
          [origin | _] ->
            conn
            |> put_resp_header("access-control-allow-origin", origin)
            |> put_resp_header("access-control-allow-credentials", "true")
            |> put_resp_header("vary", "origin")
            |> put_resp_header("access-control-allow-headers", "authorization, content-type")
            |> handle_preflight()

          [] ->
            conn
            |> put_resp_header("access-control-allow-origin", "*")
            |> put_resp_header("access-control-allow-headers", "authorization, content-type")
        end

      true ->
        conn
    end
  end

  defp handle_preflight(%{method: "OPTIONS"} = conn) do
    conn
    |> send_resp(204, "")
    |> halt()
  end

  defp handle_preflight(conn), do: conn
end
