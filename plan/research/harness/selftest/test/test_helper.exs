ExUnit.start()
if System.get_env("DSPY_MUT_REPORT") do
  Code.require_file("#{Path.expand("../..", __DIR__)}/mut_formatter.exs", __DIR__)
  ExUnit.configure(formatters: [ExUnit.CLIFormatter, MutFormatter])
end
