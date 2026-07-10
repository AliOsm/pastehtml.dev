# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # OAuth authorization codes and PKCE code_verifier/code_challenge (partial match on :code).
  :code,
  # MCP JSON-RPC tool calls carry the paste body as `content` -- up to 2 MB and
  # possibly password-protected, so keep it out of the logs.
  :content
]
