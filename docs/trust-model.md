# Trust Model

Scope: the current `FixedMandate` implementation, including signed first-payment timing, not an audit certification.
See [invariants](invariants.md) for properties and [known issues](known-issues.md) for unresolved limitations.

## Authority And Funds

| Actor | Authority and exposure |
| --- | --- |
| Payer | Authorizes exact mandate terms, supplies the token allowance, can invalidate unused opening nonces, and can cancel an opened mandate. Compromised payer authority can authorize new spending. |
| Biller | Must accept opening terms and can cancel. Cannot unilaterally change an opened mandate or redirect its payments. Compromise permits cancellation and submission of already-authorized payments, not arbitrary payer debits through this executor. |
| Recipient | Receives the signed nominal payment. Being recipient alone confers no opening or cancellation authority. Roles may overlap. |
| Submitter | Anyone can relay valid signatures or settle unlocked occurrences. Cannot alter signed terms; receives no protocol fee merely for submitting. |
| Deployer/operator | Has no privileged runtime role: no owner, upgrade mechanism, administrative pause, rescue function, or configurable operator. |

The executor spends directly from payer to recipient; it does not escrow payments or maintain user balances.
Tokens accidentally sent to it have no dedicated recovery path. Confirm the deployed code and domain before approving
it; a claimed deployment address or dashboard label is not an authorization guarantee.

The ERC-20 allowance is shared across **all mandates for the same payer, token, and executor**, not reserved per mandate.
One mandate's collection can exhaust funds or allowance needed by another. Cancellation stops only that mandate and
does not revoke allowance. Revoking allowance stops otherwise-valid pulls until approval is restored; it does not cancel
mandates, clear arrears, or prevent opening. An open-ended mandate has no payer-selected lifetime spending ceiling.

## Authorization Boundary

- Opening requires both parties: either two signatures, or the caller's direct authority and the other party's signature.
  Even when payer and biller are the same address, a direct opening still requires the counterparty signature check.
- Mandate identity commits to every supplied term. Changing a party, recipient, token, or amount selects a different id,
  not a different interpretation of existing state. This relies on the usual cryptographic hash and signature assumptions.
- EIP-712 binds signatures to `FixedMandate`, version `1`, chain id, and executor address. Different chain ids or executor
  addresses separate domains; distinct networks sharing both chain id and address are **not** independently separated.
- Addresses with code are validated exclusively through ERC-1271 `staticcall`; their signature bytes are passed unchanged.
  Their wallet implementation, validator, owners, threshold, modules, and upgrades determine their authorization policy.
  A permissive or compromised validator grants authority for that wallet, not for unrelated payer or biller addresses.
- Contract-signature validity can change between signing, simulation, and execution. It is checked when opening or
  submitting a signed cancellation. **Settlement does not recheck opening signatures**: owner rotation or signature
  revocation alone does not stop an already-open mandate. Cancel it or revoke the token allowance.
- Cancellation signatures bind the selected payer/biller address as `authorizer`. Sharing owners alone does not let
  two correctly validating wallets substitute one role's signature for the other. If payer and biller are the same
  address, their cancellation nonce namespace is intentionally the same.

See [signature verification](../src/Signatures.sol), [executor entry points](../src/FixedMandate.sol), and
[opening nonce ownership](../src/UnorderedNonces.sol).

## Timing, Availability, And Ordering

Opening records the executing block's timestamp as `startedAt`. The signed `firstPaymentAt` selects the schedule anchor;
zero instead uses `startedAt` and immediately unlocks index zero on opening. A nonzero future timestamp unlocks nothing
early; opening after a past timestamp makes accrued occurrences eligible immediately. The opener cannot shift an
explicit anchor, but can influence a zero-selected anchor by choosing when to submit within signature deadlines.
Block production, transaction inclusion, timestamp behavior, and finality are chain assumptions, not executor guarantees.

Anyone may collect all accrued occurrences sequentially, including in one transaction through an external caller.
No offchain grace period, preferred keeper, retry policy, or merchant instruction restricts this right. Token callbacks
can also settle later already-unlocked occurrences: there is no reentrancy mutex, and each call must pass the same checks.
See [design decisions](design-decisions.md) and [supported token assumptions](supported-tokens.md).

Cancellation is effective in execution order, not when requested or signed. It cannot undo an earlier settlement;
subsequent settlement attempts fail. A cancellation during a token callback does not undo the occurrence already
consumed by the outer call. Failed transfers roll back that call and its nested effects.

No party is obliged by the contract to submit transactions or pay gas. Keepers can withhold service, signatures can
expire, token policy can block transfers, and users can lack funds or allowance. Payment liveness is not guaranteed.

## Integration Responsibilities And Evidence

UIs and relayers have no special contract authority, but users trust them to display accurate terms, amounts, addresses,
first-payment timing, deadlines, and aggregate exposure. `termsHash` is only a nonzero commitment: the executor neither
retrieves its content nor enforces delivery, refunds, disputes, or commercial promises. Indexers must authenticate
executor logs and handle reorgs; successful outer smart-wallet transactions do not necessarily mean their inner Mandate call succeeded.

[Safe integration tests](../test/fixtures/safe/README.md) deploy real Safe **1.3.0 and 1.4.1** bytecode locally with
version-matched handlers and initially 2-of-3 EOA owners. They cover signature and direct-transaction flows, policy changes,
and failures. They are not fork tests or certification of every Safe handler, module, guard, contract owner, or deployment.
Recurring pulls use the token allowance, not a new Safe owner-approved transaction for each occurrence.

[Core tests](../test/FixedMandateExecutor.t.sol) and [stateful tests](../test/FixedMandateExecutor.invariant.t.sol) exercise
authorization, sequencing, rollback, role overlaps, and standard-token accounting. Their economic guarantees depend on
the [token assumptions](supported-tokens.md); neither token correctness nor external wallet security is established
by these tests.
