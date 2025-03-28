defmodule Ueberauth.Strategy.LinkedIn do
  @moduledoc """
  LinkedIn Strategy for Überauth.
  """

  use Ueberauth.Strategy,
    uid_field: :id,
    default_scope: "r_liteprofile r_emailaddress"

  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra

  @state_cookie_name "ueberauth_linkedin_state"
  @user_query "/v2/me?projection=(id,localizedFirstName,localizedLastName,profilePicture(displayImage~:playableStreams))"
  @email_query "/v2/clientAwareMemberHandles?q=members&projection=(elements*(primary,type,handle~))"

  @doc """
  Handles initial request for LinkedIn authentication.
  """
  def handle_request!(conn) do
    scopes = conn.params["scope"] || option(conn, :default_scope)
    state =
      conn.params["state"] || Base.encode64(:crypto.strong_rand_bytes(16))

    opts = [scope: scopes,
            state: state,
            redirect_uri: callback_url(conn)]

    conn
    |> put_resp_cookie(@state_cookie_name, state)
    |> redirect!(Ueberauth.Strategy.LinkedIn.OAuth.authorize_url!(opts))
  end

  @doc """
  Handles the callback from LinkedIn.
  """
  def handle_callback!(%Plug.Conn{params: %{"code" => code,
                                            "state" => state}} = conn) do
    conn = conn |> fetch_cookies

    opts = [redirect_uri: callback_url(conn)]
    %OAuth2.Client{token: token} = Ueberauth.Strategy.LinkedIn.OAuth.get_token!([code: code], opts)

    if token.access_token == nil do
      token_error = token.other_params["error"]
      token_error_description = token.other_params["error_description"]
      conn
      |> delete_resp_cookie(@state_cookie_name)
      |> set_errors!([error(token_error, token_error_description)])
    else
      if conn.cookies[@state_cookie_name] == state do
        conn
        |> delete_resp_cookie(@state_cookie_name)
        |> fetch_user(token)
        |> fetch_email(token)
      else
        conn
        |> delete_resp_cookie(@state_cookie_name)
        |> set_errors!([error("csrf", "CSRF token mismatch")])
      end
    end
  end

  @doc false
  def handle_callback!(conn) do
    conn
    |> delete_resp_cookie(@state_cookie_name)
    |> set_errors!([error("missing_code", "No code received")])
  end

  @doc false
  def handle_cleanup!(conn) do
    conn
    |> put_private(:linkedin_user, nil)
    |> put_private(:linkedin_token, nil)
  end

  @doc """
  Fetches the uid field from the response.
  """
  def uid(conn) do
    uid_field =
      conn
      |> option(:uid_field)
      |> to_string

    conn.private.linkedin_user[uid_field]
  end

  @doc """
  Includes the credentials from the linkedin response.
  """
  def credentials(conn) do
    token = conn.private.linkedin_token

    %Credentials{
      expires: !!token.expires_at,
      expires_at: token.expires_at,
      refresh_token: token.refresh_token,
      token: token.access_token
    }
  end

  @doc """
  Fetches the fields to populate the info section of `Ueberauth.Auth` struct.
  """
  def info(conn) do
    user = conn.private.linkedin_user
    email = conn.private.linkedin_email

    %Info{
      email: email,
      first_name: user["localizedFirstName"],
      image: extract_image(user["profilePicture"]),
      last_name: user["localizedLastName"]
    }
  end

  @doc """
  Stores the raw information (including the token) obtained from
  the linkedin callback.
  """
  def extra(conn) do
    %Extra{
      raw_info: %{
        token: conn.private.linkedin_token,
        user: conn.private.linkedin_user
      }
    }
  end

  defp skip_url_encode_option, do: [path_encode_fun: fn(a) -> a end]

  defp extract_image(%{"displayImage~" => %{"elements" => elements}}) when length(elements) > 0 do
    element =
      Enum.max_by(elements, fn element ->
        get_in(element, ["data", "com.linkedin.digitalmedia.mediaartifact.StillImage", "storageSize", "width"]) || 0
      end)

    case element do
      %{"identifiers" => identifiers} when length(identifiers) > 0 ->
        Enum.at(identifiers, 0)["identifier"]

      _ ->
        nil
    end
  end
  defp extract_image(_), do: nil

  defp extract_email(%{"elements" => elements}) do
    case Enum.filter(elements, &(&1["type"] == "EMAIL")) do
      [] ->
        nil
      [element] ->
        extract_email(element)
      email_elements ->
        element = Enum.find(email_elements, &(&1["primary"])) || Enum.at(email_elements, 0)
        extract_email(element)
    end
  end
  defp extract_email(%{"handle~" => %{"emailAddress" => email}}), do: email
  defp extract_email(_body), do: nil

  defp fetch_email(conn, token) do
    resp = Ueberauth.Strategy.LinkedIn.OAuth.get(token, @email_query, [], skip_url_encode_option())
    case resp do
      {:ok, %OAuth2.Response{status_code: 401, body: _body}} ->
        set_errors!(conn, [error("token", "unauthorized")])
      {:ok, %OAuth2.Response{status_code: status_code, body: body}}
        when status_code in 200..399 ->
          put_private(conn, :linkedin_email, extract_email(body))
      {:error, %OAuth2.Error{reason: reason} } ->
        set_errors!(conn, [error("OAuth2", reason)])
    end
  end

  defp fetch_user(conn, token) do
    conn = put_private(conn, :linkedin_token, token)
    resp = Ueberauth.Strategy.LinkedIn.OAuth.get(token, @user_query, [], skip_url_encode_option())

    case resp do
      { :ok, %OAuth2.Response{status_code: 401, body: _body}} ->
        set_errors!(conn, [error("token", "unauthorized")])
      { :ok, %OAuth2.Response{status_code: status_code, body: user} }
        when status_code in 200..399 ->
          put_private(conn, :linkedin_user, user)
      { :error, %OAuth2.Error{reason: reason} } ->
        set_errors!(conn, [error("OAuth2", reason)])
    end
  end

  defp option(conn, key) do
    Keyword.get(options(conn), key, Keyword.get(default_options(), key))
  end
end
