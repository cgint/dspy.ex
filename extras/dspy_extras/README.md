# dspy_extras

Optional/experimental modules extracted from the core `:dspy` library.

Intent:
- keep `:dspy` library-first and low-dependency
- allow Phoenix/UI, GenStage-heavy coordination, and legacy HTTP clients to exist as an **opt-in** package

## Safety note

This package may contain **experimental/unsafe prototypes**. Anything under `extras/dspy_extras/unsafe/` is **not compiled** (it is intentionally kept out of `lib/`) and may contain patterns that are not production-safe (e.g. dynamic atom creation, runtime compilation).

This package is currently maintained in-tree for convenience.

## Use

In your app:

```elixir
defp deps do
  [
    {:dspy, github: "cgint/dspy.ex", tag: "v0.2.0"},
    {:dspy_extras, path: "deps/dspy/extras/dspy_extras"}
  ]
end
```

(Adjust the `path:` to match how you vendored the repo. See also `docs/RELEASES.md` in the main repo.)

## Configuration (host app)

Because `:dspy_extras` is a library dependency, its `config/*.exs` files are **not** automatically imported into your app.
Configure the endpoint in your **host application**:

```elixir
# config/config.exs (in your app)
config :phoenix, :json_library, Jason

config :dspy_extras, DspyWeb.Endpoint,
  url: [host: "localhost"],
  secret_key_base: String.duplicate("0", 64),
  live_view: [signing_salt: String.duplicate("0", 32)],
  http: [ip: {127, 0, 0, 1}, port: 0],
  server: true
```

## Starting the optional services

`dspy_extras` does **not** start any processes automatically.

Note: `DspyWeb` uses the PubSub name `Dspy.PubSub` (module namespace), even though the endpoint config lives under the OTP app `:dspy_extras`.

Note on lockfiles: `extras/dspy_extras/mix.lock` is intentionally gitignored; treat it as a local dev artifact.
Add what you need to your supervision tree, for example:

```elixir
children = [
  {Phoenix.PubSub, name: Dspy.PubSub},
  DspyWeb.Endpoint,
  {Dspy.GodmodeCoordinator, []},
  {Dspy.RealtimeMonitor, []}
]
```
