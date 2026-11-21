# Restore and verify learned predictor state

## 1. Contract and typed state

- [x] 1.1 TDD. Check the existing BootstrapRS, predictor-slot, and parameter persistence tests. Add failing public API tests for root and composite state, typed map key identity, ordered signature mismatch, missing or extra slots, and duplicate slots, object members, and demo keys.
- [x] 1.2 Add the native envelope and compatible-target validation, with public API docs that describe caller-owned configuration and the format marker. Verify an extensionless filename, an unsupported version, a foreign format, and each typed slot mismatch through the public API.
- [x] 1.3 Preserve instructions, demos, and stored generation config using the portable subset in the design. Verify distinct atom and string keys, exact Example metadata, missing and explicit null rollout IDs, and `n`. Test an unrecognized atom key whose name already exists in the VM, plus a never-seen name that remains absent after rejection.
- [x] 1.4 Resolve LM references using caller registries. Verify that runtime adapter and retry settings survive, a null reference clears a destination binding, an explicit reference uses the supplied LM, and absent or ambiguous names fail with the documented errors. Assert sentinel values from LM credentials and transport fields are absent from the JSON.

## 2. Complete file operations

- [x] 2.1 Publish saves using an exclusive temporary file and atomic replacement. Verify an unsupported value preserves a byte-for-byte previous checkpoint. Induce a rename failure and check cleanup and error shape.
- [x] 2.2 Hydrate only compatible, fully validated state. Verify a malicious duplicate record and a valid first record followed by a malformed later record both return errors, and that ordinary file and parse failures follow the documented error contract.

## 3. Integration verification

- [x] 3.1 Add and verify an offline fixture that actually compiles a composite BootstrapRS program with typed integer and string keys and distinct traced demos. In the writer BEAM, set distinct instructions and stored config and record successful inference requests and the prediction. In a separate reader BEAM, build the same program shape and runtime settings, supply fresh LM bindings, and verify the loaded program reproduces the captured requests and prediction. Assert restored instructions, stored config, and exact Example attrs and metadata separately from wire equality.
- [x] 3.2 Verify the focused tests, full test suite, frozen consumer contract, and offline examples. Confirm the slice adds no dependencies and that the Parameter APIs and frozen tests retain their current behavior.
- [ ] 3.3 [User Verification] Confirm that an optimized program can be restored in a fresh BEAM by supplying its code and LM registry, and review the accepted portable demo types. This task belongs exclusively to the human user and MUST NOT be checked off by an agent.

Hosted CI and committed consumer replays are merge gates on the final PR commit.
