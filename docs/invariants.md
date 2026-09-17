# Invariants

Scope: `FixedMandate`, `UnorderedNonces`, and `Signatures` at baseline
`d13c12d`. These are implementation properties and review targets, not a formal
proof. Sources: [executor](../src/FixedMandate.sol),
[nonces](../src/UnorderedNonces.sol), [signatures](../src/Signatures.sol), and
[interface](../src/interfaces/IFixedMandate.sol).

## Assumptions And Notation

- EVM execution and rollback behave correctly; hashes resist collisions and EOA
  signatures cannot be forged. ERC-1271 authorization means the wallet's policy
  accepts the digest at execution time, not necessarily that an owner signed it.
- Time never moves backwards within the canonical execution history. Opening
  occurs at a timestamp no greater than `type(uint120).max`; otherwise the
  unchecked narrowing cast truncates the stored start time.
- For an opened mandate, `s` is `startedAt`, `p` is its positive `periodLength`,
  `n` is `totalPayments`, `c` is `settledPaymentCount`, and `t >= s` is the current
  timestamp. Let `M = 2^256 - 1` and `C = 2^120 - 1`.
- Token balance guarantees additionally require the behavior in
  [supported tokens](supported-tokens.md). A successful token call is not proof
  of an economic transfer. See [trust model](trust-model.md).

## Identity And Authorization

1. **Terms are immutable for a mandate ID.** The ID commits to all mandate fields
   and the EIP-712 domain: name `FixedMandate`, version `1`, chain ID, and executor
   address. Changing a field produces a different ID, assuming no hash collision.
   Changing chain ID or executor changes the signed digests; this does not prevent
   replay on forks retaining the same chain ID, address, and valid state.
2. **Opening requires both parties.** Each party supplies its role-specific
   signature or calls its own direct entry point. The other party's signature is
   still required when payer and biller are the same address. Signature deadlines
   are inclusive: `t == signatureDeadline` is valid.
3. **Contract-account policy cannot be bypassed with ECDSA recovery.** Accounts
   with deployed code use ERC-1271 exclusively, with signature bytes unchanged.
   Accounts without code additionally support EIP-2098 and 65-byte EOA signatures
   with `v = 0/1`.
4. **Only a mandate party can cancel.** Direct calls authenticate `msg.sender`;
   signed calls select the authorizer from `mandate.payer` or `mandate.biller`.
   The cancellation digest binds the mandate ID, authorizer address, nonce, and
   deadline. Substituting a party changes the ID; no arbitrary authorizer can be
   supplied to a cancellation entry point.

## Lifecycle And Nonces

5. **Lifecycle is one-way.** Each ID opens at most once; `opened` never clears,
   `startedAt` never changes, and `cancelled` can only change from false to true.
   Opening itself neither transfers tokens nor consumes a payment occurrence.
6. **One opening per payer nonce.** A successful opening sets exactly the nonce's
   bit in the payer's bitmap. Bits only change from zero to one, whether consumed
   by opening or invalidated by their owner. The same payer nonce cannot open
   another mandate, even with different terms; other payers have separate maps.
7. **Cancellation replay protection is separate.** A successful signed
   cancellation consumes `(authorizer, cancelNonce)` permanently. Its namespace
   is shared across that address's mandates and payer/biller roles, not keyed by
   role. Distinct addresses are independent; payer equal to biller shares one
   namespace. Direct cancellation consumes no cancellation nonce. Neither route
   clears the opening nonce or changes token allowance.
8. **Cancellation blocks further occurrences.** Once cancellation succeeds, no
   subsequent settlement invocation for that ID can increment its counter,
   including accrued payments. If cancellation occurs during a token callback,
   the already-counted in-flight payment may finish; cancellation does not undo
   it. Reverting an enclosing call also reverts the cancellation.

## Schedule And Settlement

For an opened mandate, the unlocked count is mathematically equivalent to:

```text
elapsed = floor((t - s) / p)
base    = min(elapsed + 1, M)       // mathematical addition, not uint256 overflow
U(t)    = base                     if n == 0
          min(base, n)            otherwise
```

9. **Unlocks accumulate.** The first occurrence unlocks at `s`, then one each
   `p` seconds. Missed occurrences remain available without expiry; finite
   schedules never unlock more than `n`. The public getter rejects unopened or
   cancelled mandates. For cancelled mandates, the formula is a mathematical
   schedule, not a right to collect. Unopened mandates have no schedule anchor.
10. **Sequential consumption.** Every successful settlement invocation requires
    an open, uncancelled mandate, `nextPaymentIndex == c`, and `c < U(t)`. It
    increments the counter before interacting with the token. Thus `0 <= c <= C`
    and `c <= U(t)`; for finite schedules, also `c <= n`. Counter overflow reverts,
    so a schedule with `n > C` cannot fully complete.
11. **One instruction per invocation, not per transaction.** Each successful
    invocation calls the committed token's `transferFrom(payer, recipient,
    amountPerPayment)`, once. Anyone may submit it; no caller-selected recipient,
    amount, or protocol fee exists. Callback reentry may consume additional
    unlocked occurrences using subsequent indices, so an outer transaction can
    increase the count by more than one. Replaying the current index fails.
12. **Effects and logs follow consumption order.** `PaymentSettled` is emitted
    after the increment and before the token interaction, so nested settlement
    logs appear in increasing index order for that mandate. Rejected token calls
    roll back the invocation's counter, logs, and nested effects. Failed signed
    cancellation likewise leaves nonce state unchanged and retains no new logs.
13. **State isolation is not funding isolation.** Each invocation's own lifecycle
    and count writes target its mandate; cancellation nonces and opening
    nonces remain address-scoped as above. Multiple mandates may compete for the
    same payer balance and executor allowance. Cancellation is not revocation of
    that shared allowance.

## Conditional Token Accounting

For an exact-transfer token, each completed settlement debits the payer and
credits the recipient by `amountPerPayment`, with no protocol deduction or
submitter reward. If payer equals recipient, the net balance change is zero.
Over multiple calls, balance-delta assertions additionally exclude unrelated
transfers, rebases, and other balance mutations. Role overlap can make a submitter
the legitimate recipient; that is not a fee. Mandate neither measures balance
deltas nor enforces these economic properties against a malicious token.

## Existing Test Evidence

| Properties | Evidence |
| --- | --- |
| 1-4 | [Unit suite](../test/FixedMandateExecutor.t.sol): `test_DomainSeparatorAndCanonicalTypedData`, `test_RevertWhen_SignaturesTargetAnotherChainOrFixedExecutor`, `test_RevertWhen_ECDSASignaturesBypassERC1271Policy`, `test_AttackerCannotCancelBySubstitutingThemselfAsMandateParty`. |
| 5-7 | Unit suite: `testFuzz_SameNonceCannotOpenDifferentFixedMandates`, `testFuzz_NonceInvalidationIsMonotonicAndOwnerScoped`, `test_SameAddressPayerAndBillerShareCancellationNonceNamespace`, `test_ExpiredMalformedAndFailedCancellationDoNotConsumeNonce`. |
| 8-10 | Unit suite: `test_CancellationBlocksAccruedAndFuturePayments`, `test_PaymentUnlocksExactlyAtEachBoundary`, `testFuzz_SettlementTransitionsMatchScheduleModel`, `test_UnlockedCountSaturatesAtUintMax`. |
| 11-12 | Unit suite: `test_SettlementUsesExactlyOneTransferFrom`, `test_CallbackSubmitterCanSettleNextUnlockedOccurrence`, `test_CallbackCannotReplayCurrentPaymentIndex`, `test_CallbackCannotRedirectPayment`, `test_OuterTransferFailureRollsBackNestedStateAndEvents`. |
| 5, 8-10, 13 and token accounting | [Stateful suites](../test/FixedMandateExecutor.invariant.t.sol): `FixedMandateFiniteInvariantTest`, `FixedMandateIndefiniteInvariantTest`, `FixedMandateCancellationInvariantTest`, `FixedMandateMultiInvariantTest`. |
| Wallet authorization and nonce ownership | [Opening/settlement Safe suites](../test/FixedMandate.safe.t.sol) and [cancellation Safe suites](../test/FixedMandate.safe.cancellation.t.sol), each instantiated for real Safe 1.3.0 and 1.4.1 with matching handlers. See [fixture scope](../test/fixtures/safe/README.md). |
| Conditional economics | Unit suite: `test_UnsupportedTokenEconomicsRemainExplicit`, `test_PayerRecipientSelfTransferConsumesAllowanceWithoutChangingNetBalance`, `testFuzz_PermissionlessSettlementTransfersFullAmount`. |

Tests provide bounded evidence, not exhaustive proof. Stateful handlers use
standard mock tokens, bounded forward time, one or three pre-opened mandates,
and direct payer cancellation; they do not model arbitrary callbacks or wallet
policies. Timestamp fuzzing covers `uint64`, not the `uint120` cast boundary.
The counter's `uint120` overflow boundary and cancellation during a token callback
currently have no dedicated tests. See [known issues](known-issues.md).
