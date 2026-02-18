## 1. Define the conversation history contract (TDD)

- [ ] 1.1 Review existing adapter/prompt/message-shape tests to reuse patterns (TDD)
- [ ] 1.2 Add failing unit test(s) for `%Dspy.History{}` shape validation (invalid struct, non-list messages, invalid message element)
- [ ] 1.3 Add failing test proving: when history is omitted, `Predict` request `messages` shape and rendered prompt content are unchanged (byte-for-byte for the single `user` message)
- [ ] 1.4 Add failing test proving: when history is provided, exactly `2*N + 1` messages are sent (N history elements + current request)
- [ ] 1.5 Add failing test proving: history messages precede the final current-request `user` message
- [ ] 1.6 Add failing test proving: the history field is not rendered into the current request content

## 2. Implement history type + validation

- [ ] 2.1 Add `lib/dspy/history.ex` with `%Dspy.History{messages: [...]}` and basic constructors/docs
- [ ] 2.2 Implement validation helper(s) that ensure each history element has ≥1 signature input key and ≥1 signature output key (excluding the history field itself)
- [ ] 2.3 Define tagged error shapes for history failures (include failing index) and use them consistently

## 3. Add deterministic formatting helpers for history message content

- [ ] 3.1 Introduce a small formatter module for rendering “inputs-only” and “outputs-only” content for a signature (deterministic `Field: value` lines)
- [ ] 3.2 Ensure formatter supports both atom and string keys (same conventions as `Dspy.call/2` inputs)
- [ ] 3.3 Add unit tests asserting deterministic formatting uses signature field order and stable newline formatting

## 4. Extend Predict and ChainOfThought to emit history messages

- [ ] 4.1 Update `Dspy.Predict` to detect an optional history input field (`type: :history`), validate it, and prepend formatted history message pairs to `request.messages`
- [ ] 4.2 Update `Dspy.Predict` prompt filling to exclude the history field from placeholder substitution
- [ ] 4.3 Update `Dspy.Predict` attachments extraction to exclude the history field (avoid treating history as attachments)
- [ ] 4.4 Apply the same history handling changes to `Dspy.ChainOfThought`

## 5. Ensure ReAct final extraction includes history (and trajectory remains tool-only)

- [ ] 5.1 Add failing test for `Dspy.ReAct`: extraction request includes history messages when base signature includes history
- [ ] 5.2 Add/adjust test asserting returned `:trajectory` contains only tool-loop trace (history is not added as steps)
- [ ] 5.3 If needed, adjust `Dspy.ReAct` to ensure the extractor call receives the original inputs (including history) unchanged

## 6. Verification

- [ ] 6.1 Run targeted tests for the new history behavior and confirm all new tests pass
- [ ] 6.2 Run full `mix test` to ensure no regressions across existing adapter/predict/cot/react tests

## 7. Final verification by the user

- [ ] 7.1 Review the new tests to confirm they match the specs’ scenarios and error shapes
- [ ] 7.2 Run an offline demo in `iex -S mix` using a mock LM to confirm history produces multi-message requests in practice
