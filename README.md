# Fixed Mandate Executor

Foundry reference implementation for exact recurring ERC-20 pull payments authorized when a fixed mandate opens.

For the protocol architecture, state machine, event model, and integration details, see
[PROTOCOL.md](./PROTOCOL.md).

The core flow is:

```text
payer grants ERC-20 allowance to FixedMandateExecutor
payer authorizes exact recurring-payment terms with typed data
biller accepts the same terms
opening anchors the schedule and unlocks the first occurrence
each elapsed period unlocks one more occurrence
an eligible caller settles the next unlocked occurrence
the executor enforces the signed recipient, amount, caller policy, fee, cancellation, and payment index
```

## Status

Prototype/reference implementation. It is **not audited** and should not be used on production.

Implemented:

- immutable executor with no owner, proxy, upgrade path, custody, or arbitrary external calls
- any nonzero token address can be signed into a mandate as permissionless input
- three mandate creation entrypoints:
  - `openMandate(...)`: any caller submits payer authorization and biller acceptance
  - `openMandateAsPayer(...)`: the payer calls directly and submits biller acceptance
  - `openMandateAsBiller(...)`: the biller calls directly and submits payer authorization
- ERC-1271 contract-signature support for payer and biller
- EIP-2098 compact EOA signatures and ECDSA `v` values of `0/1`
- Permit2-style unordered nonce bitmap for payer opening nonces
- payer- or biller-authorized cancellation through direct and authorizer-bound signed paths
- exact recurring payments with a contract-generated start and immediate first unlock
- finite or open-ended schedules with sequential catch-up for missed payments
- mandate-level named or open external settlement, with independent direct biller authority
- an optional exact `settlerFeePerPayment` transfer routed from within payer gross to an eligible non-biller caller
- settlement events emitted after consuming the payment index and before token calls, preserving index order across
  nested settlement callbacks
- SafeERC20-style `transferFrom` handling for tokens that return `bool` or no return data
- Foundry unit, fuzz, callback, gas, and stateful invariant coverage

Not implemented:

- permit adapters or Permit2 activation wrappers
- batch settlement
- calendar-month billing semantics
- arbitrary-token economic accounting guarantees for fee-on-transfer, rebasing, excessive-debit, or malicious tokens
- a signed future schedule start or collection deadline
- SDK, typed-data generation helpers, indexer, dashboard, or merchant API

## Contract Surface

### Fixed Mandate

```solidity
struct Mandate {
    address payer;
    address biller;
    address recipient;
    address settler;
    address token;
    uint256 payerGrossPerPayment;
    uint256 settlerFeePerPayment;
    uint256 periodLength;
    uint256 totalPayments; // zero means open-ended
    bytes32 termsHash;
    uint256 nonce;
}
```

**Known prototype limit:** `totalPayments` is `uint256`, while the stored settlement counter is `uint120`. Opening
currently accepts larger positive counts even though they cannot complete. Integrations must reject values above
`type(uint120).max`; before production, the contract should enforce the bound or widen the counter. This implementation
ceiling is not meaningful payer protection for an open-ended mandate.

The `mandateId` is the EIP-712 digest of `Mandate` under the executor's domain, so it is chain- and
deployment-specific. Payer authorization signs
`MandateAuthorization(Mandate mandate,uint256 signatureDeadline)`, while biller acceptance signs
`MandateAcceptance(Mandate mandate,uint256 signatureDeadline)`. Both wrappers commit to the complete fixed
terms.

`openMandate` treats its submitter as neutral and requires both typed signatures. `openMandateAsPayer` and
`openMandateAsBiller` require the corresponding party to call and replace only that party's signature with transaction
authority. All three routes consume the payer's unordered nonce, derive the same mandate id, store
`startedAt = block.timestamp`, and emit `MandateOpened`. Opening does not check token balance or allowance.

The generated start is not part of the signed terms. Payment index `0` unlocks immediately, and index `i` unlocks at
`startedAt + i * periodLength`. Signature deadlines limit how long a neutral holder of both opening signatures may wait
before seeking inclusion; the confirmed block timestamp supplied by the block producer becomes the schedule anchor.

`settle(mandate, nextPaymentIndex)` pulls exactly one unlocked occurrence. The supplied index must equal the stored
settled count, so stale or racing transactions cannot consume a later occurrence. Missed payments remain available and
may settle in rapid succession. A positive `totalPayments` caps the schedule; zero continues unlocking until
cancellation. Finite arrears remain collectible after the final scheduled unlock.

The biller may always call `settle`. Otherwise, a nonzero `settler` restricts settlement to that address, while a zero
`settler` permits any caller. For an eligible non-biller, the executor requests `gross - fee` to the recipient and the
exact signed `settlerFeePerPayment` to the caller. A biller call waives the fee and requests one full-gross transfer to
the recipient. These are nominal `transferFrom` amounts: if the payer is also a transfer destination, that self-transfer
leg can consume allowance without producing the same net balance movement.

The payer and biller can each cancel directly or authorize cancellation by EIP-712 signature. Signed cancellations bind
the payer or biller address as `authorizer` and use a separate per-authorizer replay mapping. Cancellation blocks both
accrued and future payments but does not revoke ERC-20 allowance.

Useful views expose the EIP-712 domain, mandate and signature digests, stored mandate state, the payer nonce bitmap,
used cancellation nonces, and the current `unlockedPaymentCount`.

## Events And Indexing

- `MandateOpened` indexes `mandateId`, `payer`, and `biller`, and emits every signed mandate field plus the generated
  `startedAt`.
- `PaymentSettled` indexes `mandateId`, `paymentIndex`, and `payer`, and records payer gross, actual fee, and the
  settlement caller.
- `MandateCancellation` indexes `mandateId`, `payer`, and the payer or biller that authorized cancellation.
- `UnorderedNonceInvalidation` records the mask submitted for the payer's nonce bitmap; the mask may be zero or include
  bits that were already set.

`PaymentSettled` is emitted after its payment index is consumed but before token interactions. If a token callback
settles another unlocked occurrence, logs for the mandate remain ordered by `paymentIndex`. Any later transfer failure
reverts the entire call stack, including state changes and logs. Indexers that need to distinguish the three opening
routes must inspect the selector of the executor call frame, using a trace or decoded smart-account/router execution
when it is not the top-level transaction call. Their resulting mandate state is otherwise identical.

## Development

Clone with submodules, or initialize them after clone:

```bash
git clone --recurse-submodules <repo-url>
# or, after a normal clone:
git submodule update --init --recursive
```

Then run:

```bash
forge build
forge test -vvv
forge test --fuzz-runs 10000
forge fmt --check
```

Tests containing inline gas measurements emit committed `snapshots/*.json` files during an ordinary `forge test` run;
no separate snapshot command is required. Foundry runs tests in isolation so these measurements are accurate. Review
and commit regenerated snapshot files whenever an intentional change affects measured gas usage.

The contract is pinned to Solidity `0.8.35`. CI and the committed gas baselines use Foundry `v1.5.1`; use that Foundry
version when regenerating snapshots.

## Deploy

Create `.env` from `.env.example`, then:

```bash
source .env
forge script script/DeployFixedMandateExecutor.s.sol:DeployFixedMandateExecutor \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

Add verifier flags only when the chain verifier is configured:

```bash
forge script script/DeployFixedMandateExecutor.s.sol:DeployFixedMandateExecutor \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY"
```

## Security Notes

The executor deliberately has **no token allowlist**. Any token address can be signed into a mandate as permissionless
input. Settlement reverts if the token address has no code, but fee and gross guarantees assume standard ERC-20
semantics: `transferFrom(from, to, amount)` debits exactly `amount` and credits exactly `amount`. Fee-on-transfer,
rebasing, excessive-debit, pausable, blocklist, callback-heavy, and malicious tokens are outside the current economic
guarantee boundary. The contract permits role addresses to overlap, so net proceeds and net payer outflow also depend
on whether a transfer is a self-transfer.

The executor has no reentrancy mutex. It consumes the current payment index before token interactions, preventing a
same-index replay. On an open-settler mandate, a callback token can nevertheless settle another already-unlocked index
and, when configured, receive that nested occurrence's fee. A token that is neither the biller nor the named settler
cannot settle or receive a fee under a named-settler mandate. Every nested settlement still has to satisfy the caller,
next-index, unlock, and finite-count rules, and all nested effects revert if the outer call fails.

The executor is a shared ERC-20 spender. Users should approve finite amounts sized to expected exposure. For a finite
mandate, allowance should cover unpaid occurrences, including any unlocked backlog. For an open-ended mandate, choose
a deliberate runway budget and replenish it as needed rather than treating exposure as finite.

Cancellation stops one mandate. Reducing or revoking ERC-20 allowance prevents pulls while allowance is insufficient,
but does not cancel the mandate. A delayed caller can collect several accrued payments consecutively, and an open-ended
schedule has no payer-selected lifetime count before cancellation. Products should display currently unlocked arrears
and immediate gross exposure, not only the per-payment amount.

## Future Work

Variable Mandate is future work. It will be designed from evidence and learnings gathered during a full-stack rollout
of `FixedMandateExecutor`; no Variable Mandate design is specified here.

## Design Pressure

See [PROTOCOL.md](./PROTOCOL.md) for the current protocol surface, `docs/TECHNICAL_GRILL.md` for open technical
decisions, and `docs/SECURITY_NOTES.md` for automated-analysis findings reviewed during implementation.
