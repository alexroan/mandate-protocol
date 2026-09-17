# Design Decisions

Scope: the `FixedMandate` implementation at `d13c12d`. These are current design choices and their tradeoffs, not a
historical decision log or a description of a variable-payment executor. See [PROTOCOL.md](../PROTOCOL.md) for the API.

## 1. Immutable, Shared, Noncustodial Spender

`FixedMandate` has no owner, upgrade, pause, rescue, or arbitrary-call facility. Settlement calls the signed token's
`transferFrom(payer, recipient, amountPerPayment)` directly. This keeps payment authority in immutable rules rather
than an operator. An ERC-20 allowance is shared across that payer's mandates for the same token and executor; it is not
reserved per mandate. The executor provides no recovery path for accidental transfers. See the
[trust model](./trust-model.md).

## 2. Bilateral Opening, With Direct-Caller Alternatives

Opening requires payer authorization and biller acceptance of every mandate field. Separate EIP-712 wrapper types
distinguish the two approvals. Each direct route substitutes `msg.sender` for only the calling party's signature,
reducing signing and calldata requirements without removing counterparty approval. Even when payer and biller are the
same address, the other role's signature is still required. Opening neither transfers tokens nor checks funding or
allowance; payment readiness is independent of agreement formation.

## 3. Hash-Committed Terms, Minimal Stored State

The domain-separated mandate digest is the storage key. Callers supply the full terms for later operations rather than
loading another stored copy. Changing a party, recipient, token, amount, cadence, total, metadata hash, or nonce selects
a different mandate; it cannot modify an opened mandate. `MandateOpened` publishes the terms for reconstruction.
`termsHash` commits to external material, but the contract neither retrieves nor enforces that material.

## 4. Opening Anchors A Nonexpiring Schedule

Opening records the block timestamp and immediately unlocks index `0`; each `periodLength` seconds unlocks another
occurrence. There is no signed start time, expiry, settlement window, or calendar-month calculation. An eligible opener
can choose when to submit within the required signature deadlines, affecting the schedule anchor. Unpaid unlocked
occurrences remain collectible in rapid sequential catch-up. Positive `totalPayments` caps the schedule; zero selects
an open-ended schedule, subject to the implementation limit below.

## 5. Permissionless, Sequential Settlement Without Fees

Anyone can call `settle`, with no invoice, further party signature, appointed settler, or protocol fee. This allows
independent automation without granting it payment authority. `nextPaymentIndex` must equal the stored count, so a
stale or racing call cannot silently collect a different occurrence. Each invocation consumes one unlocked occurrence
and requests one fixed transfer to the pinned recipient. The recorded `submitter` is provenance, not authorization or
a reward entitlement. Offchain grace periods and preferred-operator policies cannot prevent collection.

## 6. Separate Opening And Cancellation Nonce Namespaces

Payer-scoped unordered bitmap nonces allow parallel opening authorizations and bulk invalidation without a sequential
nonce bottleneck. Signed cancellations instead consume an authorizer-scoped nonce, independent of the opening bitmap
and shared across that address's mandates. Their digest binds both mandate ID and authorizer address; different
wallets sharing an owner cannot interchange role signatures merely for that reason. An address acting as both payer
and biller shares one cancellation namespace: the digest binds an address, not a separate role tag. Direct cancellation
does not consume a cancellation nonce. There is no dedicated cancellation-nonce invalidation entrypoint; see
[known issues](./known-issues.md).

## 7. Either Party Can End All Unpaid Collection

Payer or biller cancellation permanently blocks new settlement calls, including collection of accrued unpaid
occurrences. It does not undo completed or already-consumed in-flight settlements, or revoke allowance. This is not
enforcement of commercial debt or refund obligations. Cancellation applies only after opening; pending payer
authorizations can instead be blocked through opening-nonce invalidation. Revoking allowance affects every mandate
sharing that payer, token, and executor, but does not cancel mandates or stop their schedules from accruing.

## 8. Effects And Events Before Transfer, Without A Mutex

`settle` increments the counter and emits `PaymentSettled` before calling the token. A callback cannot reuse the consumed
index, but may submit later already-unlocked occurrences or another eligible mandate under the ordinary permissionless
rules. This allows nested settlement; it is not a one-payment-per-transaction guarantee. Event ordering follows index
consumption even during callbacks, and a propagated failure rolls back affected state, logs, and transfers. Other
entrypoints retain their ordinary authorization checks during callbacks. These guarantees concern executor state, not
the honesty of token accounting. See [invariants](./invariants.md) and the callback tests linked below.

## 9. Wallet Policy Is Authoritative For Contract Signatures

Code-bearing signers are checked exclusively through ERC-1271, with signature bytes passed unchanged. EOA recovery
cannot bypass a contract wallet's policy, and EOA-specific compact-signature handling and `v` normalization do not
modify wallet-specific formats. Addresses without code additionally support EIP-2098 and `v = 0/1`. Wallet policy can
change before submission; validation uses its current state. Real Safe 1.3.0 and 1.4.1 integration tests exercise matching
fallback handlers, threshold signatures, direct transactions, and policy changes, not every possible wallet setup.

## 10. Token Return Validation, Not Economic Attestation

Token selection is permissionless. `SafeERC20` handles call failure and return-value conventions; the executor does not
measure payer or recipient balance deltas or enforce token semantics. A successful settlement records the nominal
amount requested, not independent proof of delivery or value. Exact-amount economic claims therefore depend on the
token and address relationships. See [supported tokens](./supported-tokens.md); acceptance by the contract is not a
token endorsement.

## 11. Packed State Has A Numerical Limit

Two flags and two `uint120` fields fit `MandateState` into one storage slot, reducing storage footprint. However, the
signed `totalPayments` is `uint256`: opening currently accepts positive totals above `type(uint120).max`, which cannot
complete because the settlement counter overflows first. This validation gap is a [known issue](./known-issues.md),
not an intended supported configuration. Open-ended mandates also have that counter ceiling; it is not a meaningful
lifetime spending limit. The `startedAt` cast assumes chain timestamps fit `uint120`.

## Evidence

- [Executor](../src/FixedMandate.sol), [types](../src/interfaces/IFixedMandate.sol), [signatures](../src/Signatures.sol), [opening nonces](../src/UnorderedNonces.sol).
- [Unit and callback tests](../test/FixedMandateExecutor.t.sol), [stateful model tests](../test/FixedMandateExecutor.invariant.t.sol).
- [Safe opening and settlement tests](../test/FixedMandate.safe.t.sol), [Safe cancellation tests](../test/FixedMandate.safe.cancellation.t.sol), [fixture provenance](../test/fixtures/safe/README.md).
