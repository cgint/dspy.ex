#!/usr/bin/env python3
# Greta: drive the H12 harness in-process to test its try/finally restore.
#   mode "exc": run_tests raises RuntimeError on its 2nd call (a mutation is applied then)
#   mode "int": restore Python's default SIGINT handler, then run normally (the caller sends SIGINT)
import importlib.util, signal, sys

mode, harness = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("mutate_h12", harness)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)          # defines functions; main() only runs under __main__

if mode == "exc":
    real = mod.run_tests
    calls = {"n": 0}
    def flaky():
        calls["n"] += 1
        if calls["n"] == 2:
            raise RuntimeError("injected failure while a mutation is applied")
        return real()
    mod.run_tests = flaky
elif mode == "int":
    signal.signal(signal.SIGINT, signal.default_int_handler)

mod.main()
