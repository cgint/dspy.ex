import Config

# Core `:dspy` is library-first and keeps runtime config minimal.
# Optional Phoenix/UI and other experimental services live in `extras/dspy_extras`.

env_config = "#{config_env()}.exs"

if File.exists?(Path.join(__DIR__, env_config)) do
  import_config env_config
end
