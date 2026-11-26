[mode, dir, endpoint] = System.argv()

{:ok, _} = Application.ensure_all_started(:dspy)
:ok = Dspy.configure_cache(disk_cache_dir: dir, disk_size_limit_bytes: 1_000_000)

lm =
  Dspy.LM.new!("openai/gpt-4.1-mini",
    api_key: "synthetic-disk-" <> mode,
    base_url: endpoint,
    cache_namespace: "account-a"
  )

request = %{messages: [%{role: "user", content: "Offline"}]}

contract = %{
  "type" => "object",
  "properties" => %{"answer" => %{"type" => "string"}},
  "required" => ["answer"],
  "additionalProperties" => false
}

Dspy.context([cache: true], fn ->
  for {route, request} <- [
        {"text", request},
        {"native", Map.put(request, :output_contract, contract)}
      ] do
    {:ok, response} = Dspy.LM.generate(lm, request)
    %{usage: %{cost: %{line_items: line_items}}} = response
    true = Enum.any?(line_items, &(&1.kind == :tokens))

    File.write!(
      Path.join(dir, "#{route}-#{mode}.etf"),
      :erlang.term_to_binary(response, [:deterministic])
    )
  end
end)
