import Config

# Keep endpoint non-serving by default in this repo. Flip to `true` if/when we
# decide to actively develop the in-tree LiveView UI.
config :dspy, DspyWeb.Endpoint, server: false
