import Config

# Tests should run quiet + deterministic; keep optional services off.
config :dspy, :start_optional_services, false

config :dspy, DspyWeb.Endpoint, server: false
