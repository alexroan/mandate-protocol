# Supported Tokens

Scope: `FixedMandate` at source revision `d13c12d`. This is a behavioral compatibility policy, **not a token allowlist or
certification of any asset or network deployment**. No production token is certified by the repository's mock-token tests.

## Required Behavior

For the advertised exact-amount payment semantics, the signed token must implement ERC-20 `transferFrom` such that:

- The executor can spend the payer's allowance, and insufficient balance or allowance causes failure.
- A successful transfer debits exactly `amountPerPayment` from the payer and credits that amount to the recipient,
  without additional deductions, transfer taxes, or misleading success responses.
- It returns ABI-encoded `true`, or returns no data and reverts on failure. Both forms are accepted by the pinned
  [OpenZeppelin SafeERC20](../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol) implementation.

When payer equals recipient, an ordinary self-transfer has **zero net balance change**, not a recipient balance increase.
It still consumes the occurrence and may consume allowance. Mandate permits this role overlap.

Amounts are raw integer token units. The executor never queries `decimals`, prices, symbols, or exchange rates. A fixed
token amount is not a guarantee of fixed fiat value or purchasing power. Native currency is not supported; a wrapped
asset must independently satisfy the same ERC-20 requirements.

## What The Contract Actually Checks

[Opening](../src/FixedMandate.sol) checks only that the token address is nonzero. It does not require deployed code,
probe the interface, verify balances or allowance, or determine economic suitability. Permissionless acceptance of a
token address is not a promise that it can settle.

Each successful settlement invocation consumes one occurrence and calls
`token.transferFrom(payer, recipient, amountPerPayment)` through `SafeERC20`. It does **not** compare pre/post balances,
inspect token events, or prove that value moved. A token that falsely reports success can consume an occurrence without
paying the recipient; `PaymentSettled` records the nominal call, not independently verified delivery.

| Token behavior | Executor result and integration policy |
| --- | --- |
| Exact-transfer ERC-20 returning `true` | Intended behavior, assuming its balance and allowance accounting is sound. |
| Exact-transfer ERC-20 returning no data | Accepted; missing return data alone is not incompatibility. |
| Returns `false`, reverts, or returns an invalid ABI boolean | Settlement reverts; occurrence consumption and nested effects roll back. |
| Ordinary address without code | Opening can succeed; settlement fails the `SafeERC20`/`Address` code check. |
| Fee-on-transfer, recipient deduction, or extra payer debit | Can report success and consume an occurrence with incorrect economics. Unsupported for exact-amount guarantees; not rejected onchain. |
| Rebasing or other externally changing balances | No special accounting or protection. Exclude from exact-balance expectations unless separately evaluated; nominal occurrence amounts do not adjust. |
| Pausable, blacklistable, or restricted transfers | May work while permitted and fail later. Acceptance requires explicit reliance on issuer policy and availability. |
| Upgradeable token | Current behavior is insufficient evidence of future compatibility. Review upgrade authority and monitor changes. |
| Callback-capable token | Not categorically rejected. Review callbacks and accounting; see the reentrancy boundary below. |
| Dishonest token/fallback returning success without transfer | Can advance the counter without payment. `SafeERC20` does not establish token honesty. |

## Allowances And Callbacks

Approval is performed separately by the payer or its wallet; the executor does not call `approve`, `permit`, or Permit2.
Token-specific approval requirements, including resetting a nonzero allowance first, belong in the integration.
Allowance is shared across mandates for the same payer/token/executor. Cancellation leaves it unchanged.

There is no reentrancy mutex. The counter increments and `PaymentSettled` is emitted before the token call, so a callback
cannot reuse the same index. It may settle other eligible occurrences, including the next unlocked index of the same
mandate. Each invocation independently enforces its signed terms and lifecycle checks; there is no callback reward or
recipient redirection. A failing outer transfer rolls back nested settlements as well.

These are **executor-state protections**, not a defense against a token rewriting its own balances or allowance rules.
Payers and billers must assess the chosen token's implementation, administrators, upgrades, and callback behavior before
relying on it. No onchain allowlist enforces this policy.

## Evidence And Limits

[Unit tests](../test/FixedMandateExecutor.t.sol), using [token fixtures](../test/helpers/MandateMocks.sol), cover:

- Exact-transfer, no-return, false-return, no-code, insufficient-balance, and insufficient-allowance outcomes.
- Self-transfers and role overlaps.
- Fee-on-transfer and excessive-debit counterexamples that **succeed** but violate advertised payment economics.
- Callback catch-up, stale-index rejection, attempted redirection, event ordering, and outer-failure rollback.

[Stateful tests](../test/FixedMandateExecutor.invariant.t.sol) verify accounting under the standard mock token's semantics.
[Real Safe tests](../test/fixtures/safe/README.md) still use a mock ERC-20. None of these establishes compatibility with
a live token deployment, issuer policy, rebase mechanism, or future token upgrade. See the [trust model](trust-model.md).
