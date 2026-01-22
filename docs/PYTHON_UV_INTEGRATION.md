# Python Integration via `uv` and `Pythonx`

## Executive Summary

**Pythonx** embeds Python directly into the Erlang VM (BEAM) using NIFs, providing high-performance, low-latency interoperability. It leverages **`uv`** to automate the management of the Python runtime and dependencies directly from your Elixir configuration.

*   **Best for:** Tasks requiring low-latency data exchange, tight integration (e.g., verifying logic against reference implementations), and simplified deployment without managing external processes.
*   **Key Risks:** NIF crashes bring down the BEAM; Global Interpreter Lock (GIL) limits concurrency; Global state is shared across Elixir processes.
*   **Critical Requirement:** Consistent C-runtime (glibc vs. musl) between build and runtime environments is mandatory.

---

## Architecture Concept

![Pythonx Concept](./python_uv_concept.svg)

## Key Components

### 1. Pythonx (The Bridge)
- **Type:** NIF-based library (Native Implemented Functions).
- **Role:** Embeds a Python interpreter directly into the Erlang VM (BEAM).
- **Data Exchange:** Handles transparent conversion between Elixir terms and Python objects.

### 2. `uv` (The Manager)
- **Role:** Automatically downloads a specific Python version and installs dependencies.
- **Integration:** Configured via `config/config.exs`. `Pythonx` invokes `uv` to ensure the environment matches the `pyproject.toml` definition provided in the Elixir config.
- **Benefit:** No need to pre-install Python or manage virtualenvs manually on the host machine.

## Runtime & Docker Environment

Deployment in Docker requires careful handling of system dependencies and build artifacts.

### System Dependencies (`glibc` vs `musl`)
*   **The Problem:** Python wheels and `uv`-managed interpreters are compiled against specific C libraries.
*   **Recommendation:** Use **Debian-based images** (e.g., `debian:bookworm-slim`, `hexpm/elixir:X.Y.Z-erlang-A.B.C-debian-bookworm-slim`) for broad compatibility with standard Python wheels (`manylinux`).
*   **Alpine/Musl Warning:** If using Alpine, you **must** ensure `uv` downloads `musl`-compatible Python builds and that all Python wheels have `musl` variants (or compile them from source). Mixing glibc-built artifacts with a musl runtime will fail.

### Docker Best Practices

1.  **Multi-Stage Builds:**
    *   **Builder Stage:** Install `uv`, compilers, and system libs. Let `Pythonx` fetch/build the Python environment.
    *   **Runtime Stage:** Copy the *entire* `_build/prod/lib/pythonx` (or relevant priv directory) artifacts. Ensure the runtime image has the same OS/libc as the builder.

2.  **Cache Management:**
    *   Mount `uv`'s cache directory during the build to speed up dependency resolution.
    *   Example: `RUN --mount=type=cache,target=/root/.cache/uv mix compile`

3.  **Environment Variables:**
    *   Ensure `uv` can run in "offline" or "frozen" mode in production if desired, though `Pythonx` typically handles the environment setup at boot/init.

## Best Practices for Development & Production

### 1. Concurrency & Safety
*   **Treat Python as a Shared Resource:** The embedded interpreter is effectively a singleton. Avoid global variables in Python scripts (`module-level` state) as they are visible to all Elixir processes.
*   **Offload Heavy Compute:** Be aware of the GIL. For long-running CPU tasks, consider if `Pythonx` (NIF) is safer than a Port, or if the calculation releases the GIL (like NumPy).

### 2. Dependency Management
*   **Pin Versions:** Explicitly pin the Python version in your Elixir config (e.g., `requires-python = "==3.12.*"`) to match your production Docker image capabilities.
*   **Lockfiles:** Trust `uv.lock` (managed via the `config`) to ensure reproducibility.

### 3. Usage Pattern
*   **"Script-like" Execution:** Use `Pythonx` for stateless function calls (input -> processing -> output).
*   **Avoid Complex State:** Do not try to maintain complex object lifecycles across the Elixir/Python boundary if possible. Pass data, get results.

## Configuration & Usage Example

### Setup in `config/config.exs`

You define your Python requirements directly in Elixir. `uv` takes care of the rest.

```elixir
import Config

config :pythonx, :uv_init,
  pyproject_toml: """
  [project]
  name = "dspy_ex_python_host"
  version = "0.1.0"
  requires-python = "==3.12.*"
  dependencies = [
    "numpy",
    "pandas",
    "dspy-ai" # Example: Installing DSPy python lib if needed
  ]
  """
```

### Execution

Code can be executed inline using the `~PY` sigil or `Pythonx.eval/2`.

```elixir
defmodule MyPythonModule do
  import Pythonx

  def run_calculation(data) do
    Pythonx.eval(~PY"""
    import numpy as np
    # 'data' is automatically converted from Elixir list/map
    arr = np.array(data)
    result = np.mean(arr)
    result
    """, %{data: data})
  end
end
```

## Detailed Evaluation

### Pros
*   **Seamless Integration:** `Pythonx` embeds Python directly into the BEAM, allowing for zero-serialization overhead for compatible data types and efficient memory sharing.
*   **Simplified Management:** `uv` handles the entire Python lifecycle (download, install, venv creation) automatically based on Elixir configuration.
*   **Performance:** Significantly lower latency for function calls compared to Port-based solutions.
*   **Developer Experience:** Inline `~PY` sigils allow for rapid prototyping.

### Cons
*   **Crash Risk:** A NIF crash (segfault) brings down the entire VM.
*   **Concurrency Limitations:** Python's GIL limits parallelism for CPU-bound tasks.
*   **Maturity:** Library is new (v0.1.0 Feb 2025); ecosystem is evolving.

### Caveats
*   **"One Interpreter per Node":** Global state is shared across all processes.
*   **Debugging:** Stack traces across the boundary can be opaque.
*   **Deployment Constraints:** Target machine must support the specific Python builds `uv` fetches; network access required for initial setup unless artifacts are carefully bundled.