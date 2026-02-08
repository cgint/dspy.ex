import Config

config :phoenix, :json_library, Jason

# Library-first by default: optional web/"godmode" services must be explicitly enabled.
config :dspy, :start_optional_services, false

# Minimal defaults so the in-tree Phoenix endpoint can compile and the application can boot.
# This repo is moving toward "library-only"; until `lib/dspy_web/*` is relocated/gated, we keep
# the endpoint non-serving by default.
config :dspy, DspyWeb.Endpoint,
  url: [host: "localhost"],
  secret_key_base: String.duplicate("0", 64),
  live_view: [signing_salt: String.duplicate("0", 32)],
  http: [ip: {127, 0, 0, 1}, port: 0],
  server: false

env_config = "#{config_env()}.exs"

if File.exists?(Path.join(__DIR__, env_config)) do
  import_config env_config
end
