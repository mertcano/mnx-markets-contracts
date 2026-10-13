# Older deployed builds

A few mainnet contracts run builds older than [`../contracts`](../contracts).
Each directory here holds the source files one of those builds compiled
from, taken from the commit that was live when it was deployed. As in
`contracts/`, a few comments were edited for publication; the code is
unchanged.

| Directory | Deployed | Contracts | Mainnet addresses |
| --- | --- | --- | --- |
| `2026-08-06/` | 2026-08-06 | `Evaluator`, `IsolatedTrader` | the implementations behind those proxies on CRWV, SPCX, ANTHROPIC, OPENAI, ASML, DEEPSEEK, DRAM, GOOGL, H100, META, MOONSHOT, MU, NVDA, SNDK, TSM, MINIMAX, and ZAI |
| `2026-07-18/` | 2026-07-18 | `SignatureVerifier` | the MarginBank withdrawal verifier, `0xd1bed9ff7d14dad059e124645b86dc5d5463c2ed` |

Each has a Foundry profile in [`../foundry.toml`](../foundry.toml). The check
compares every in-scope contract, so run all four builds from the repository
root first:

```sh
forge build
FOUNDRY_PROFILE=forwarder forge build contracts/MinimalForwarder.sol
FOUNDRY_PROFILE=deployed-2026-08-06 forge build
FOUNDRY_PROFILE=deployed-2026-07-18 forge build
python3 scripts/verify-mainnet.py
```

Both builds use 1,000,000 optimizer runs.
