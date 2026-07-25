# Fixed Mandate

Foundry reference implementation for exact recurring ERC-20 pull payments authorized when a fixed mandate opens.

For the protocol architecture, state machine, event model, and integration details, see
[PROTOCOL.md](./PROTOCOL.md).

The core flow is:

```text
payer grants ERC-20 allowance to FixedMandate
payer authorizes exact recurring-payment terms with typed data
biller accepts the same terms
opening anchors the schedule and unlocks the first occurrence
each elapsed period unlocks one more occurrence
any address may submit settlement for the exact next unlocked occurrence
FixedMandate enforces the opened and uncancelled schedule, pinned token and recipient, full amount, timing, and payment index
one transfer moves the full signed amount to the recipient; the submitter receives no protocol funds
```

## Status

Prototype/reference implementation. It is **not audited** and should not be used on production.

Implemented:

- immutable `FixedMandate` contract with no owner, proxy, upgrade path, custody, or arbitrary external calls
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
- permissionless settlement submission: any address may settle the exact next unlocked occurrence
- exactly one nominal transfer of the full amount from the payer to the pinned recipient for every successful occurrence
- no protocol payment or special settlement authority for the submitter, including when the submitter is the biller
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
- onchain grace periods, payment pauses, preferred submitters, or retry pacing
- protocol-funded compensation for settlement submission
- SDK, typed-data generation helpers, indexer, dashboard, or merchant API

## Contract Surface

### Fixed Mandate

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

**Known prototype limit:** `totalPayments` is `uint256`, while the stored settlement counter is `uint120`. Opening
currently accepts larger positive counts even though they cannot complete. Integrations must reject values above
`type(uint120).max`; before production, the contract should enforce the bound or widen the counter. This implementation
ceiling is not meaningful payer protection for an open-ended mandate.

The `mandateId` is the EIP-712 digest of `Mandate` under the `FixedMandate` domain, so it is chain- and
deployment-specific. The domain name and version are `FixedMandate` and `1`; version `1` remains appropriate because
this is still the first undeployed schema. The canonical type strings are:

```text
Mandate(address payer,address biller,address recipient,address token,uint256 amountPerPayment,uint256 periodLength,uint256 totalPayments,bytes32 termsHash,uint256 nonce)

MandateAuthorization(Mandate mandate,uint256 signatureDeadline)Mandate(address payer,address biller,address recipient,address token,uint256 amountPerPayment,uint256 periodLength,uint256 totalPayments,bytes32 termsHash,uint256 nonce)

MandateAcceptance(Mandate mandate,uint256 signatureDeadline)Mandate(address payer,address biller,address recipient,address token,uint256 amountPerPayment,uint256 periodLength,uint256 totalPayments,bytes32 termsHash,uint256 nonce)
```

Payer authorization signs `MandateAuthorization`, while biller acceptance signs `MandateAcceptance`. Both wrappers
commit to the complete nine-field mandate. This is a breaking pre-deployment schema; the contract does not accept
signatures or mandate IDs from the earlier field layout.

`openMandate` treats its submitter as neutral and requires both typed signatures. `openMandateAsPayer` and
`openMandateAsBiller` require the corresponding party to call and replace only that party's signature with transaction
authority. All three routes consume the payer's unordered nonce, derive the same mandate id, store
`startedAt = block.timestamp`, and emit `MandateOpened`. Opening does not check token balance or allowance.

The generated start is not part of the signed terms. Payment index `0` unlocks immediately, and index `i` unlocks at
`startedAt + i * periodLength`. Signature deadlines limit how long a neutral holder of both opening signatures may wait
before seeking inclusion; the confirmed block timestamp supplied by the block producer becomes the schedule anchor.

`settle(mandate, nextPaymentIndex)` is permissionless and pulls exactly one unlocked occurrence. Any address may submit
it; the biller has the same settlement access and economics as every other address. The supplied index must equal the
stored settled count, so racing transactions cannot both consume an occurrence and a stale transaction cannot silently
consume a later one.

Every successful call makes exactly one nominal transfer:

```solidity
IERC20(mandate.token).safeTransferFrom(
    mandate.payer,
    mandate.recipient,
    mandate.amountPerPayment
);
```

The submitter cannot redirect this transfer and receives no funds from `FixedMandate`. Under standard ERC-20 semantics,
and when payer and recipient are distinct, the payer debit and recipient credit both equal
`amountPerPayment`. If payer and recipient are the same address, the self-transfer can consume allowance without the
same net balance movement.

**Collection is immediate and permissionless after unlock.** Any address may cause the next unlocked occurrence to be
collected, and missed occurrences may be collected sequentially in rapid succession, including after the final unlock
of a finite schedule. A positive `totalPayments` caps the schedule; zero continues unlocking until cancellation.
Offchain grace, pause, preferred-operator, retry-pacing, or service-level policies do not restrict the contract. Only
onchain ordering, cancellation, the next-index and unlock checks, finite completion, or a failed token transfer can stop
a submitted collection.

Monitoring, transaction submission, replacement, retries, dunning, reconciliation, gas management, and any associated
commercial arrangements are execution-layer concerns outside this protocol.

The payer and biller can each cancel directly or authorize cancellation by EIP-712 signature. Signed cancellations bind
the payer or biller address as `authorizer` and use a separate per-authorizer replay mapping. Cancellation blocks both
accrued and future payments but does not revoke ERC-20 allowance.

Useful views expose the EIP-712 domain, mandate and signature digests, stored mandate state, the payer nonce bitmap,
used cancellation nonces, and the current `unlockedPaymentCount`.

## Events And Indexing

The lifecycle event schemas are:

```solidity
event MandateOpened(
    bytes32 indexed mandateId,
    address indexed payer,
    address indexed biller,
    address token,
    address recipient,
    uint256 amountPerPayment,
    uint256 periodLength,
    uint256 totalPayments,
    uint256 startedAt,
    uint256 nonce,
    bytes32 termsHash
);

event PaymentSettled(
    bytes32 indexed mandateId,
    uint256 indexed paymentIndex,
    address indexed payer,
    address biller,
    address recipient,
    address token,
    uint256 amountPerPayment,
    address submitter
);
```

- `MandateOpened` contains every signed mandate field plus the generated `startedAt`.
- `PaymentSettled` records the immediate `submitter` as factual provenance only, not as an authorized protocol role.
- `MandateCancellation` indexes `mandateId`, `payer`, and the payer or biller that authorized cancellation.
- `UnorderedNonceInvalidation` records the mask submitted for the payer's nonce bitmap; the mask may be zero or include
  bits that were already set.

`PaymentSettled` is emitted after its payment index is consumed but before token interactions. If a token callback
settles another unlocked occurrence, logs for the mandate remain ordered by `paymentIndex`. Any later transfer failure
reverts the entire call stack, including state changes and logs. Indexers that need to distinguish the three opening
routes must inspect the selector of the `FixedMandate` call frame, using a trace or decoded smart-account/router
execution when it is not the top-level transaction call. Their resulting mandate state is otherwise identical.

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
forge script script/DeployFixedMandate.s.sol:DeployFixedMandate \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

Add verifier flags only when the chain verifier is configured:

```bash
forge script script/DeployFixedMandate.s.sol:DeployFixedMandate \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY"
```

## Security Notes

`FixedMandate` deliberately has **no token allowlist**. Any token address can be signed into a mandate as permissionless
input. Settlement reverts if the token address has no code, but nominal amount accounting assumes standard
ERC-20 semantics: `transferFrom(from, to, amount)` debits exactly `amount` and credits exactly `amount`.
Fee-on-transfer, rebasing, excessive-debit, pausable, blocklist, callback-heavy, and malicious tokens are outside the
current economic guarantee boundary. This token-level fee-on-transfer warning is unrelated to protocol-funded
submission compensation. Payer, biller, and recipient addresses may overlap, so net proceeds and payer outflow also
depend on whether the one transfer is a self-transfer.

`FixedMandate` has no reentrancy mutex. It consumes the current payment index before token interactions, preventing a
same-index replay. Because settlement is permissionless, a callback-capable token can submit the next already-unlocked
index just like any other address. The callback receives no protocol funds and cannot redirect payment away from the
pinned recipient. Every nested settlement must independently pass the opened, cancellation, next-index, unlock, and
finite-count checks. Events remain ordered by payment index, and all nested state, logs, and transfers revert if the
outer transfer fails.

`FixedMandate` is a shared ERC-20 spender. Users should approve finite amounts sized to expected exposure. For a finite
mandate, allowance should cover unpaid occurrences, including any unlocked backlog. For an open-ended mandate, choose
a deliberate runway budget and replenish it as needed rather than treating exposure as finite.

Cancellation stops one mandate. Reducing or revoking ERC-20 allowance prevents pulls while allowance is insufficient,
but does not cancel the mandate. Any address can collect several accrued payments consecutively, and an open-ended
schedule has no payer-selected lifetime count before cancellation. Cancellation and allowance changes take effect only
according to onchain ordering; an already ordered settlement may land first. Applications should display currently
unlocked arrears and immediate nominal exposure, not only the per-payment amount, and must not present offchain grace or
pacing as an onchain guarantee.

## Future Work

Variable Mandate is future work. It will be designed from evidence and learnings gathered during a full-stack rollout
of `FixedMandate`; no Variable Mandate design is specified here.

## Design Pressure

See [PROTOCOL.md](./PROTOCOL.md) for the current protocol surface, `docs/TECHNICAL_GRILL.md` for open technical
decisions, and `docs/SECURITY_NOTES.md` for automated-analysis findings reviewed during implementation.
