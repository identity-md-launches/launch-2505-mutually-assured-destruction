# Mutually Assured Destruction (MAD)

An immutable, fixed-supply ERC-20 token. The constructor creates the entire supply once and gives it to the immediate deployer (`msg.sender`). In the IdentityMD launch, that deployer is the factory.

## Token and deployment parameters

| Parameter | Value |
| --- | --- |
| Solidity contract | `MADToken` |
| Source | `src/MADToken.sol` |
| Name | `Mutually Assured Destruction` |
| Symbol | `MAD` |
| Decimals | `18` |
| Whole-token supply | `1,000,000,000` |
| Supply in smallest units | `1000000000000000000000000000` (`10^27`) |
| Named supply constant | `INITIAL_SUPPLY` |
| Constructor arguments | None (`[]`) |
| Constructor ETH value | `0` |
| Launch chain | Ethereum, chain ID `1` |
| Compiler | Solidity `0.8.26` |
| EVM target | Cancun |
| Optimizer | Enabled, 200 runs |
| Metadata hash | `none` |

Deploy the creation bytecode for `src/MADToken.sol:MADToken` directly, with no arguments or initialization call. The constructor calls no outside contracts and requires no configured addresses. The runtime has no linked external libraries. This project contains one production contract and no application contracts, proxy, or deployment wrapper.

The factory must receive the tokens at construction so it can perform the launch distribution. An EOA deploying the bytecode directly instead receives all tokens itself. Deploying through another wrapper gives the wrapper the tokens; its operator must ensure it can distribute them. `tx.origin` is never used.

## Behavior and assumptions

The brief specifies a name, symbol, supply, and initial recipient. The name does not imply a destruction, retaliation, or burn mechanism. The implementation therefore uses ordinary ERC-20 transfers and approvals from the vendored OpenZeppelin Contracts v5.4.0 implementation.

- The supply never changes after construction. No public mint, burn, or `burnFrom` exists.
- Every successful transfer credits exactly the requested amount. There are no transfer taxes, fees, exemptions, limits, rebases, or callbacks to recipients.
- There is no owner, admin, pause, blacklist, confiscation, upgrade, or initializer capability. The deployer has the same transfer and approval rights as any other holder.
- Transfers to the zero address revert, including zero-value transfers. Zero-value transfers between nonzero addresses succeed and emit `Transfer`. Self-transfers require a sufficient balance and preserve that balance.
- `approve` replaces the caller's allowance for the spender. A zero spender is rejected. An allowance can exceed the holder's current balance, but spending still requires both allowance and balance.
- `transferFrom` requires allowance even when called by the holder. Finite allowances decrease on spending; `type(uint256).max` represents unlimited approval and does not decrease. Failed transfers roll back allowance changes.
- Minting and transfers emit `Transfer`. Explicit approvals emit `Approval`. As in the vendored implementation, spending an allowance does not emit an additional `Approval`; indexers should read `allowance` for current values.

The pool's trading fee is separate from this token's transfer behavior. The token applies no trading policy and queries no RPC, price feed, router, or external service.

## Launch integration

The supplied launch policy performs distribution outside the token: 10% to the launch's Merkle distributor, 80% to pool seeding, and the remaining 10% to `0x1ee3ffadfe138415a2ddaedeebe5f46616fa413d`. All tokens remain with the factory until it transfers them; the constructor reserves or distributes nothing separately.

The policy specifies FWA at `0xa0df17b5ac76ababa36e1450e2cbcd18a620c845` as the paired currency (18 decimals), pool fee `12500` (1.25%), tick spacing `60`, and `pool.initialPrice` provenance value `79228162514264337593543950336`. The deployer derives the actual opening price from the supplied initial market cap and the eventual token address.

The supplied economics are:

```json
{"poolBps":8000,"initialMarketCapWei":"2000000000000000000000000","remainderTo":"0x1ee3ffadfe138415a2ddaedeebe5f46616fa413d"}
```

These are inputs for the later launch process, not token constructor parameters or hardcoded token dependencies. The network's separate manifest step supplies `launch.json`; this project does not create it. No transaction has been broadcast.

## Build and checks

All Solidity dependencies are included as ordinary source files under `lib/`, with their licenses and checksums. No dependency installation, network, environment file, wallet, RPC, FFI, or filesystem cheatcode permission is required to build or run the tests. Foundry and the pinned Solidity compiler must already be installed for an offline build.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x3a888a0790a9c92c7ba3a1780edc96b941af60bfb9450c599d2d2f6eae95f41a forge test
forge fmt --check
sha256sum --check DEPENDENCIES.sha256
```

`test/MADToken.t.sol` checks metadata, the constructor mint event, factory CREATE2 deployment and recipient identity, exact distribution and claim transfers, contract recipients, transfer and approval events, zero values, self-transfers, full-balance transfers, allowance consumption/revocation, and maximum allowances. Failure tests cover insufficient balances and allowances, the wrong spender, zero addresses, state rollback, native currency, and attempted privileged operations. Four fuzz tests exercise transfer conservation, delegated spending, and invalid balance/allowance inputs at 512 runs each.

`test/MADToken.invariant.t.sol` runs 128 sequences of 64 randomized approvals, transfers, and delegated transfers. A separate accounting model checks all balances and allowances across four actors, plus constant supply and conservation of their aggregate balance. Self-transfers and both finite and unlimited allowances are included.

Tests use isolated local deployments and fixture addresses; they do not read or modify environment variables. The launch-flow unit test models token movements only. It does not implement Uniswap or validate pricing, liquidity calculations, or live-chain swaps. The supplied protected suite depends on the network's separate factory/pool harness and resolved manifest values and is run by that verifier.

## After launch

There are no owner-settable values, privileged accounts, initialization calls, or recurring maintenance transactions. The network deployer is responsible for the manifest, independent review, factory distribution, pool setup, and explorer verification against the pinned build. Before distribution it should confirm the deployed metadata, total supply, and the factory's full starting balance, then verify the final recipients and allocations.

Holders are responsible for recipient addresses and approvals. Approve only the amount a spender needs. To change an existing nonzero approval safely, revoke it first and wait for confirmation before granting the replacement; this mitigates the usual ERC-20 approval replacement race. Unlimited approval remains supported for compatibility and exposes the holder's future balance to that spender.

There is no recovery method for tokens accidentally sent to the token contract or other incapable recipients. Ordinary ETH transfers to the token revert, and any ETH forced into its address cannot be recovered. The contract is immutable; defects cannot be patched in place or paused.

## Review scope

The production extension adds only a constant and a constructor mint to the vendored ERC-20. Manual review checked the exposed ABI, mint reachability, allowance authorization, zero-address validation, rollback behavior, absence of external interactions, and absence of privileged or upgrade paths. The contract does not use signatures, oracles, randomness, vault math, or external token custody.

Local Foundry tests and review are not an independent security audit. Slither and Mythril were not run. The separate contributor review and full launch integration verification remain responsibilities of the launch process.

