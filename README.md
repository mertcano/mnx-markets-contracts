# MNX Exchange Contracts

Solidity source of the smart contracts behind [MNX](https://mnx.fi), a
derivatives exchange on MegaETH mainnet (chain ID 4326). It lists perpetual
swaps, binary futures, and numeric futures.

Security reports go through the
[MNX bug bounty](https://docs.mnx.fi/security/bug-bounty). Report
vulnerabilities privately as that page describes. Do not open a public issue.

## What is deployed

The [mainnet contract inventory](https://docs.mnx.fi/security/mainnet-scope.json)
lists the shared contracts and vault accounts. Every market open for trading is
in scope too, and the
[market registry](https://api.app.mnx.fi/v0/markets?include_unlaunched=true)
gives each market's six contract addresses. Every one of those contracts (for a
proxy, its current implementation) is reproduced by a build from this
repository. The check below was run at MegaETH mainnet block 29,066,074
(2026-10-13). It compares runtime code with a local build, ignoring the Solidity
metadata trailer and immutable values. The proxies and their admins are
standard OpenZeppelin contracts and are not compared. Immutable values, such as
each price oracle's update caps and `PythAnchoredOracle.trustedSigner`, are set
at deployment; read them from the contracts.

| Mainnet contracts | Source | Foundry profile | Optimizer runs |
| --- | --- | --- | --- |
| Everything not listed below | [`contracts/`](contracts) | `default` | 1,000,000 |
| `MNXMinimalForwarder` | [`contracts/`](contracts) | `forwarder` | 150 |
| `Evaluator` and `IsolatedTrader` on 17 markets last upgraded on 2026-08-06 (CRWV, SPCX, ANTHROPIC, OPENAI, ASML, DEEPSEEK, DRAM, GOOGL, H100, META, MOONSHOT, MU, NVDA, SNDK, TSM, MINIMAX, ZAI) | [`deployed-builds/2026-08-06/`](deployed-builds/2026-08-06) | `deployed-2026-08-06` | 1,000,000 |
| MarginBank withdrawal `SignatureVerifier` | [`deployed-builds/2026-07-18/`](deployed-builds/2026-07-18) | `deployed-2026-07-18` | 1,000,000 |

Every build uses Solidity 0.8.26, EVM version `cancun`, and `viaIR`; see
[`foundry.toml`](foundry.toml).

To repeat the check (read-only; it needs no keys), install
[Foundry](https://getfoundry.sh) and Python 3, then run:

```sh
git clone --recurse-submodules https://github.com/mnx-markets/contracts
cd contracts
forge build
FOUNDRY_PROFILE=forwarder forge build contracts/MinimalForwarder.sol
FOUNDRY_PROFILE=deployed-2026-08-06 forge build
FOUNDRY_PROFILE=deployed-2026-07-18 forge build
python3 scripts/verify-mainnet.py
```

The metadata hashes differ from mainnet's because the deployed builds used a
different project layout and some comments were edited for publication. The
code itself is unchanged. `OracleFactory` and
`LiquidityVault` deploy other contracts, so their code embeds those contracts'
creation code with its own metadata hashes. The check ignores those hashes too,
and the rest of the embedded code must match byte for byte.

## How the system fits together

The order book and matching engine run off-chain. Orders clear in frequent
batch auctions: every eligible order in a batch clears together at one price.
The contracts settle those batches and enforce risk.

- `MarginBank` holds USDM collateral and records each account's balance.
- Each market has a `Perpetual` (positions and settlement), an
  `IsolatedTrader` (signed-order validation and position math), an
  `IsolatedADL` (automatic deleveraging), an `Evaluator` (the market's
  configuration and the check that a trade is allowed), a `FundingOracle`, and
  a price oracle built by `OracleFactory`.
- Margin is isolated per position.
- `LiquidityVault` is the backstop. It inherits distressed positions and holds
  the vault's child accounts (`SystemAccountHolder`). It is closed to external
  depositors; see the
  [bug bounty policy](https://docs.mnx.fi/security/bug-bounty#vault-accounts).
- `Guardian` holds the emergency controls: it can pause trading or withdrawals
  and switch a market's funding mode. In both modes the funding rate is
  computed off-chain and submitted by the funding rate provider.
- `AccountManager` manages trading keys (sub-accounts), which apply across all
  markets, and per-market permissions for system accounts such as the vault's
  child accounts.
- `MNXMinimalForwarder` relays EIP-2771 meta-transactions.
- `GlobalIndexUpdater` refreshes funding indexes in batches.

The [documentation](https://docs.mnx.fi) covers market specifications, oracle
methodology, and the public API. The contracts descend from the dYdX v1
perpetual contracts by way of
[Bluefin](https://github.com/fireflyprotocol/bluefin-exchange-contracts-evm);
the batch settlement, MegaETH resource
limits, account-state packing, funding cadence, and operational roles are
MNX-specific.

## Audit

Centennial Systems reviewed the contracts from June 23 to July 23, 2026. The
[report](https://docs.mnx.fi/security/smart-contract-audit.pdf) is a
differential review of an earlier revision, not a certification of the code
deployed today.

## Layout

- `contracts/`: the deployed contracts and the libraries and interfaces they
  use. Third-party code is vendored under `contracts/vendor/`.
- `deployed-builds/`: the source of the older builds listed above.
- `lib/`: OpenZeppelin Contracts 5.6.1, as git submodules.
- `NOTICE`, `licenses/`: third-party attributions and license texts.
- `scripts/verify-mainnet.py`: the deployed-bytecode check.

## License

GPL-3.0-or-later; see [LICENSE](LICENSE). Third-party code keeps its
upstream terms; see [NOTICE](NOTICE). Bluefin's repository has an Apache-2.0
root license, while its Solidity files carry GPL-3.0-or-later notices. The
original dYdX code and the Pyth Lazer library are Apache-2.0
([text](licenses/Apache-2.0.txt)); the vendored Chainlink interface and the
OpenZeppelin submodules are MIT.
