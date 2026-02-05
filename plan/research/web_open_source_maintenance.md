I will search for best practices in maintaining open-source Elixir libraries, focusing on issue templates, labels, triage, and release processes using Hex and Mix.
I will now research specific examples of issue templates and `mix.exs` configurations from top Elixir projects, as well as community-standard GitHub Actions and triage tools used in the Elixir ecosystem.
I will conduct a final search for Elixir-specific GitHub Actions and official maintenance recommendations from Dashbit or the Elixir Core Team to ensure the answer is as authoritative as possible.
Maintaining an open-source Elixir library involves a combination of community-standard tooling (Mix/Hex) and specialized automation workflows. Below are the best practices for issue management, triage, and release processes in the Elixir ecosystem.

### 1. Issue Templates & Labels
Templates reduce "back-and-forth" by forcing contributors to provide necessary environment details (Elixir/OTP versions).

*   **Templates (`.github/ISSUE_TEMPLATE/`):**
    *   **Bug Report:** Must include sections for: Elixir/OTP version, library version, steps to reproduce, and a minimal reproducible example (ideally a single `.exs` script).
    *   **Feature Request:** Focus on the "Problem" before the "Solution."
*   **Labeling Strategy:** Use a prefix-based system for easy filtering:
    *   `kind:bug`, `kind:feature`, `kind:discussion`
    *   `area:documentation`, `area:performance`, `area:types`
    *   `status:needs-info`, `status:blocked`, `status:ready-to-work`
    *   `difficulty:starter` or `good first issue` (crucial for community growth).

### 2. Triage Process
Efficient triage in Elixir projects often involves balancing automated "housekeeping" with manual technical review.

*   **Manual Triage:** Aim for a "First Response" within 48 hours. If an issue lacks a reproduction script, apply `status:needs-info` and use a "No Response" bot to auto-close after 14 days.
*   **Stale Management:** Use the [GitHub Stale Action](https://github.com/actions/stale) to keep the issue tracker clean.
*   **Reproduction Scripts:** Encourage users to provide a `repro.exs` using `Mix.install/2`. This allows maintainers to run the reproduction instantly without cloning a full repo.

### 3. Release Process (Hex & Mix)
The Elixir community strictly follows **Semantic Versioning (SemVer)**.

*   **Pre-release Automation:** 
    *   **Changelog:** Maintain a `CHANGELOG.md` manually or use `git-cliff` / `semantic-release` to generate it from [Conventional Commits](https://www.conventionalcommits.org/).
    *   **Version Bump:** Use `mix hex.build` to verify the package is valid before publishing.
*   **Publishing:**
    *   `mix hex.publish` automatically pushes to Hex.pm and generates HexDocs.
    *   **Secret Management:** In CI (GitHub Actions), use a `HEX_API_KEY` stored in repository secrets.
*   **Package Metadata (`mix.exs`):** Ensure your `package/0` function includes `licenses`, `links` (GitHub, Docs), and `files` (only include `lib`, `mix.exs`, `README.md`, `LICENSE`, and `CHANGELOG.md`).

### 4. Elixir-Specific CI/CD (GitHub Actions)
A "Golden Path" Elixir CI pipeline should use `erlef/setup-beam` and include the following checks:

| Task | Command | Purpose |
| :--- | :--- | :--- |
| **Setup** | `erlef/setup-beam` | Configures Elixir/OTP environment. |
| **Lint** | `mix format --check-formatted` | Enforces community style guide. |
| **Analysis** | `mix credo --strict` | Checks for code consistency and design smells. |
| **Security** | `mix sobelow --config` | Static analysis for security vulnerabilities. |
| **Auditing** | `mix hex.audit` | Detects retired or vulnerable dependencies. |
| **Types** | `mix dialyzer` | Success typing (requires PLT caching for speed). |
| **Tests** | `mix test --cover` | Ensures logic correctness and tracks coverage. |

### 5. Community "Gold Standards" to Reference
To see these practices in action, study these highly-regarded repositories:
*   **[Phoenix Framework](https://github.com/phoenixframework/phoenix):** Exemplary issue templates and contribution guidelines.
*   **[Req](https://github.com/wojtekmach/req):** Modern library using `Mix.install` for issues and clean `mix.exs` configuration.
*   **[Ecto](https://github.com/elixir-ecto/ecto):** Best-in-class documentation and versioning management.

### Recommended Tooling Summary
*   **Static Analysis:** [Credo](https://github.com/rrrene/credo)
*   **Security:** [Sobelow](https://github.com/nccgroup/sobelow)
*   **Documentation:** [ExDoc](https://github.com/elixir-lang/ex_doc)
*   **CI Environment:** [erlef/setup-beam](https://github.com/erlef/setup-beam)
*   **Dependency Audit:** [MixAudit](https://github.com/mirego/mix_audit)
