# Known Issues And Limitations

Scope: `FixedMandate` and its inherited helpers at commit `d13c12d85ad6b61d0b47fd36bec07b66e11516db`.
Reviewed against source and repository tests on 2026-09-17. This is a code-grounded register, not an exhaustive
vulnerability list, independent audit opinion, or production approval. Statuses describe this snapshot; proposed
changes below are not implemented.

## KI-01: Finite Payment Count Exceeds Storage Capacity

**Status:** Present; validation fix recommended before production. **Impact:** Specification/input mismatch with
negligible practical reach, not an authorization or overspending bypass.

`totalPayments` is `uint256`, but `settledPaymentCount` is `uint120`. Opening accepts positive totals greater than
`2^120 - 1`. Such a mandate cannot complete: once the counter reaches that maximum, a further unlocked settlement
reverts on checked increment before calling the token. Open-ended schedules have the same implementation ceiling.

**Current integration constraint:** Accept `totalPayments == 0` or `1 <= totalPayments <= 2^120 - 1`. The open-ended
counter ceiling is not a meaningful spending budget. **Fix direction:** Reject oversized positive totals during
opening, or deliberately change the storage representation; add boundary regression tests.

**Evidence:** [Mandate/state types](../src/interfaces/IFixedMandate.sol), `_validateMandate` and `settle` in
[FixedMandate](../src/FixedMandate.sol). Existing schedule fuzz tests do not reach counter exhaustion; this conclusion
follows from the checked `uint120` increment, not an exhaustive settlement run.

## KI-02: No Biller-Controlled Pre-Opening Revocation

**Status:** Present integration limitation; changing it requires an authorization-design decision.
**Impact:** A valid biller acceptance can remain usable after the biller changes its mind.

Opening nonces belong to the payer. A biller calling `invalidateUnorderedNonces` affects its own bitmap, not a distinct
payer's authorization. There is no biller-acceptance nonce or pre-opening cancellation state. A holder with the required
counterparty authority can still open before the acceptance deadline; payment index `0` then unlocks immediately.
Cancelling after opening does not guarantee that it precedes collection.

**Current mitigation:** Use deliberate acceptance deadlines and coordinate payer nonce invalidation when withdrawing
unopened terms. An ERC-1271 wallet may invalidate a signature by changing its own policy, but this is wallet-specific,
not a general protocol revocation mechanism. **Possible change:** Add biller-controlled acceptance revocation only
after deciding its scope and nonce semantics.

**Evidence:** Opening verification and `_cancel` in [FixedMandate](../src/FixedMandate.sol);
[caller-scoped opening nonce invalidation](../src/UnorderedNonces.sol).

## KI-03: No Dedicated Cancellation-Signature Revocation

**Status:** Present integration limitation; a dedicated invalidation entry point is optional hardening.
**Impact:** An unused valid cancellation signature may be submitted until its deadline, even if its authorizer no
longer wants the mandate cancelled. It does not authorize new terms, transfers, or another authorizer's cancellation.

Cancellation nonces are separate from opening nonces. `invalidateUnorderedNonces` does not revoke them; direct
cancellation does not consume them; a failed signed cancellation rolls its nonce update back. There is no operation
whose sole purpose is to invalidate cancellation nonces while keeping mandates active.

**Current mitigation:** Use deliberate signature deadlines and avoid issuing speculative cancellation signatures.
An authorizer can consume the same cancellation nonce by successfully executing a signed cancellation of another opened
mandate, but that also cancels that other mandate and is not a dedicated revocation workflow. Contract-wallet policy
changes may independently make a signature invalid. **Possible change:** Add authorizer-scoped cancellation-nonce
invalidation with an event, preserving independence from opening nonces.

**Evidence:** `_cancelMandateWithSignature`, direct cancellation routes, and `cancellationNonceUsed` in
[FixedMandate](../src/FixedMandate.sol); failed-cancellation nonce tests in
[FixedMandateExecutor.t.sol](../test/FixedMandateExecutor.t.sol).

## Numeric Assumption

Opening casts `block.timestamp` to `uint120` without a range check. An opening timestamp above `2^120 - 1` would be
truncated and produce an incorrect schedule anchor. This is not a plausible current-chain timestamp, but exact-anchor
claims assume that bound and nondecreasing canonical time. The timestamp fuzz test covers `uint64`, not the truncation
boundary. See [invariant assumptions](./invariants.md).

## Deliberate Behavior, Not Additional Findings

- Anyone may collect all unlocked arrears sequentially; offchain pauses and preferred keepers are not enforced.
- Either party can cancel all unpaid occurrences; cancellation leaves token allowance intact and cannot undo a
  settlement already ordered before it.
- Token callbacks may settle subsequent unlocked indexes. No mutex, exact balance-delta enforcement, protocol fee,
  admin pause, or rescue function exists.
- Opening does not establish token compatibility, funding, allowance, or future settlement availability.

These boundaries are described in [design decisions](./design-decisions.md), [trust model](./trust-model.md), and
[supported tokens](./supported-tokens.md). The existing `CancellationNonceConsumed` event already exposes successful
signed-cancellation nonce consumption; missing nonce visibility is not an open issue in this snapshot.
