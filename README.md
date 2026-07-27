# Mandate

**Recurring onchain payments, authorized once and enforced by code.**

Mandate gives stablecoins and other ERC-20 tokens a direct-debit primitive. A payer authorizes an exact recurring
payment schedule, the biller accepts those terms, and automation can submit each payment when it becomes due. The
contract enforces the token, amount, recipient, cadence, and number of payments every time.

**No monthly signatures. No protocol custody. No unrestricted merchant access.**

## Why Mandate?

An ERC-20 allowance only says:

```text
this spender may transfer up to X tokens
```

It does not describe a commercial relationship: who is billing, how much may be collected per payment, where the funds
must go, how often collection is allowed, or when the agreement ends.

Mandate adds those constraints above an ordinary allowance:

```text
Acme may collect exactly 15 USDC every 30 days
to Acme Treasury
for 12 payments
until the payer or biller cancels
```

This separates **authorization** from **execution**. The payer and biller agree the terms once. After opening, any
merchant, keeper, or automation service can submit a due payment, but the submitter cannot change the signed terms,
redirect the funds, or collect a payment before it unlocks.

## How It Works

1. **Agree:** the payer authorizes the complete payment schedule and the biller accepts it.
2. **Open:** the mandate is registered onchain, anchoring its schedule and unlocking the first payment.
3. **Settle:** anyone can submit the exact next unlocked payment. Funds move directly from payer to recipient.
4. **Cancel:** either the payer or biller can stop further collection.

Missed payments do not disappear. Unlocked payments remain available and can be settled sequentially, allowing an
automation service to recover arrears without changing the original agreement.

## What Mandate Provides

- **Authorize once:** neither party signs every recurring payment.
- **Bounded collection:** token, amount, recipient, cadence, and payment count are enforced onchain.
- **Automatable execution:** settlement needs no privileged operator or recurring signer.
- **Direct settlement:** tokens move from the payer to the agreed recipient without protocol custody.
- **Missed-payment recovery:** unlocked payments can be collected later in their original order.
- **Bilateral terms:** payer authorization and biller acceptance cover the same complete mandate.
- **Smart-account support:** payer and biller signatures support ERC-1271.
- **Minimal trust surface:** the contract has no owner, proxy, upgrade authority, custody, or arbitrary calls.

## Use Cases

- Stablecoin subscriptions
- Memberships and retainers
- Instalment plans
- Recurring invoices
- Fixed recurring payouts
- Automated machine or agent payments

## Current Implementation

This repository contains `FixedMandate`, the first Mandate reference implementation. It supports exact fixed-amount
payments at fixed-duration intervals over an existing ERC-20 allowance.

> [!WARNING]
> This is a prototype/reference implementation. It has not received an external security audit and should not be used
> in production or deployed with meaningful funds.

The current implementation includes:

- finite and open-ended schedules;
- three opening paths for neutral, payer, or biller submission;
- direct and signature-authorized cancellation by either party;
- permissionless settlement of the next unlocked payment;
- Permit2-style unordered opening nonces;
- EIP-712, ERC-1271, and EIP-2098 signature support;
- SafeERC20-style handling of standard and no-return ERC-20 tokens; and
- unit, fuzz, callback, gas, and stateful invariant tests.

`FixedMandate` deliberately does not schedule transactions itself, guarantee payer balance or allowance, implement
calendar-month billing, custody funds, or pay settlement submitters. Monitoring, transaction submission, retries,
dunning, and reconciliation belong to the execution layer built around the protocol.

Variable-amount mandates are future work and are not specified by this implementation.

## Integration Overview

An integration follows five steps:

1. Construct the complete `Mandate` terms.
2. Obtain payer authorization and biller acceptance, or use a direct opening path for one party.
3. Ensure the payer has granted the `FixedMandate` contract sufficient ERC-20 allowance.
4. Open the mandate and index its `MandateOpened` event.
5. Monitor unlocked payment indices and call `settle` for each payment that should be collected.

```solidity
struct Mandate {
    address payer;
    address biller;
    address recipient;
    address token;
    uint256 amountPerPayment;
    uint256 periodLength;
    uint256 totalPayments; // zero means open-ended
    bytes32 termsHash;
    uint256 nonce;
}
```

The first payment unlocks immediately when the mandate opens. Later payments unlock after each `periodLength`, measured
in seconds from the onchain opening timestamp. A fixed duration is not the same as a calendar month.

For the complete function surface, typed-data schemas, state machine, events, indexing requirements, and security
boundary, read [PROTOCOL.md](./PROTOCOL.md). For the product thesis and design rationale, read the
[working whitepaper](./WHITEPAPER-WIP.md).

## Development

Clone the repository with its submodules:

```bash
git clone --recurse-submodules https://github.com/alexroan/mandate-protocol.git
cd mandate-protocol
```

Build and test:

```bash
forge build
forge test -vvv
forge test --fuzz-runs 10000
forge fmt --check
```

Tests containing inline gas measurements update committed files in `snapshots/`. Review regenerated snapshots whenever
an intentional change affects gas usage.

The contract is pinned to Solidity `0.8.35`. CI and the committed gas baselines use Foundry `v1.5.1`.

## Security

`FixedMandate` is a shared ERC-20 spender. Integrations should use well-understood tokens, size allowances deliberately,
display currently unlocked arrears, and make cancellation and allowance revocation easy to access. Cancellation stops
the mandate but does not revoke the underlying token allowance.

The full trust model, token assumptions, reentrancy behavior, ordering considerations, and known implementation limits
are documented in [PROTOCOL.md](./PROTOCOL.md#trust-andå-security-model).

Security reports should not be opened as public issues. Contact the repository maintainers privately before disclosing
a vulnerability.

## License

Licensed under the [MIT License](./LICENSE).
