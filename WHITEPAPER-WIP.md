# Fixed Mandate

## Exact recurring ERC-20 pull payments over allowances

**Publication draft:** v0.3

**Date:** 2026-07-20

## Abstract

Stablecoins need a standard way to express recurring commercial relationships. ERC-20 approvals let a spender move
tokens, but they do not express who may collect, the exact amount and cadence, which recipient may receive funds, who
may submit a payment, what fee that caller may earn, or when either commercial party has stopped the relationship.

`FixedMandate` is an immutable allowance-based direct-debit primitive for exact recurring payments. A
payer authorizes complete fixed terms and a biller accepts those same terms. Opening the mandate records the current
block timestamp as its schedule anchor and makes payment index zero immediately collectible. One additional occurrence
unlocks after each fixed-duration period. Each successful settlement consumes exactly the next index and pulls the
exact nominal payer gross accepted at creation. Missed occurrences remain collectible in sequence.

The contract does not custody funds, schedule transactions, guarantee balance or allowance, or adjudicate commercial
disputes. It moves ordinary ERC-20 tokens through `transferFrom` after enforcing mandate state. The design therefore
inherits the ERC-20 allowance trust boundary and the economic behavior of the selected token. Its safety case depends
on a small, immutable, no-admin contract, standard token behavior, bilateral terms, sequential state consumption,
cancellation, and clear full-stack presentation.

## 1. Problem

The instruction for a fixed subscription is simple:

```text
Acme Billing may collect exactly 15 USDC every 30 days,
to Acme Treasury,
for 12 payments,
using this settlement caller policy,
until either party cancels.
```

An ERC-20 approval cannot express that instruction. It authorizes a spender and an allowance amount, but it does not
encode the payer-biller relationship, exact payment amount, fixed cadence, schedule size, recipient, settlement caller,
caller fee, commercial terms, or mandate-level cancellation.

Recurring stablecoin payments therefore tend to use one of several incomplete patterns:

- raw approvals to merchant contracts;
- repeated user transfers;
- offchain billing followed by manual settlement;
- prepaid vault balances;
- account-specific plugins;
- token-specific authorization features.

Each pattern can be appropriate. None turns an allowance over an ordinary ERC-20 into a portable, wallet-readable,
bilaterally accepted fixed payment schedule.

`FixedMandate` accepts the existing allowance model and adds those commercial semantics above it.

## 2. Design thesis

`FixedMandate` separates three forms of authority that a raw approval collapses or omits.

The first is **token spending authority**. The payer grants ERC-20 allowance to `FixedMandate`. The token remains the
source of truth for whether `transferFrom` succeeds.

The second is **mandate authority**. The payer authorizes the biller, token, recipient, exact gross amount, cadence,
finite or open-ended schedule, settlement caller policy, exact caller fee, offchain terms commitment, and payer nonce.

The third is **biller acceptance**. The biller accepts the same complete mandate before it can become active. This
prevents one-sided active records and proves that the biller accepted the recipient, schedule, fee, and execution
domain presented to the payer.

The state machine connecting them is:

```text
payer mandate authority
+ biller acceptance
+ opened and uncancelled schedule
+ exact next unlocked payment index
+ eligible settlement caller
+ token acceptance of transferFrom
= successful fixed payment settlement
```

No new payer or biller signature is needed for each occurrence. That is possible because neither the settlement caller
nor the biller can change the amount or schedule after opening. New commercial terms require a new mandate.

`FixedMandate` is not a wallet, custodian, merchant registry, scheduler, dispute court, or token standard. It is a
narrow settlement primitive for exact recurring payments.

## 3. Scope of this paper

This paper describes the semantics, implementation boundary, full-stack responsibilities, risks, observable records,
and validation requirements of the current `FixedMandate` reference implementation.

The Solidity interfaces remain the source of truth for exact calldata, event parameters, storage types, and error
selectors. This paper focuses on the behavior that wallets, billers, settlers, indexers, operators, and auditors need to
understand.

## 4. Target experience

### Payer

The payer should see a commercial schedule rather than raw allowance plumbing:

```text
Authorize Acme Billing
Payment: exactly 15 USDC
Cadence: every 30 days from onchain opening
First payment: collectible immediately after opening
Schedule: 12 payments
Recipient: Acme Treasury
Settlement: Mandate Settler
Settler fee: 0.05 USDC from each payment
Cancellation: payer or biller; a settlement ordered first can still succeed
```

The display must distinguish a fixed number of seconds from a calendar month. It must also show whether the schedule is
finite or open-ended, how many occurrences have settled, how many are currently unlocked, and the total unlocked
backlog that could be collected immediately.

The payer can authorize opening with an EIP-712 signature, an ERC-1271 contract signature, or a direct call from the
payer address. A direct payer call replaces only the payer signature; biller acceptance is still required.

Funds remain in the payer's normal token balance. The payer separately grants allowance to `FixedMandate` and can revoke
that allowance at the token layer.

### Biller

The fixed biller flow is:

```text
1. Negotiate the complete fixed mandate with the payer.
2. Accept those exact terms by signature or direct transaction.
3. Observe the opened mandate and its generated start.
4. Allow an open or named settler to submit unlocked occurrences, or settle directly.
5. Reconcile settlement and cancellation events.
```

Biller acceptance covers every future occurrence in the accepted schedule. The biller does not sign a recurring
authorization for each payment. It also cannot choose a different amount, recipient, token, fee, or occurrence.

The biller always retains direct settlement authority, even when the mandate names an external settler. A direct biller
settlement waives the external-caller fee and sends the full nominal payer gross to the recipient.

### Settler

A settler is an onchain transaction submitter. The contract does not wake itself up when a payment unlocks. A settler
service normally watches mandate state, detects unlocked occurrences, preflights token allowance and balance, submits
`settle`, retries operational failures, and reconciles final receipts.

The mandate supports two external-caller policies:

- `settler == address(0)`: any external caller may settle the next unlocked occurrence;
- `settler != address(0)`: only that address may settle externally.

The biller is independently authorized in both cases. For an eligible non-biller caller, `FixedMandate` routes the exact
`settlerFeePerPayment` transfer accepted in the mandate to that caller. A caller gains no power to alter the payment by
submitting it.

Any caller may relay mandate creation when it has valid payer authorization and biller acceptance. Relaying creation
does not confer later settlement authority beyond the mandate's caller policy.

### Smart accounts and 7702-enabled EOAs

Safes and other contract accounts can participate through ERC-1271 signatures or their own direct transactions. An
ERC-4337 or EIP-7702 account can use its normal batching and sponsorship infrastructure around `FixedMandate` calls.
The contract does not require a wallet-specific module.

This does not remove the allowance granted to `FixedMandate`. In this design, the contract remains the token spender
and calls `transferFrom`.

## 5. Design goals

1. **No vault funding.** Funds remain in the payer's ordinary token balance.
2. **One public spender.** The payer approves the immutable `FixedMandate` contract rather than every biller contract.
3. **Two-sided creation.** No active mandate exists without payer authority and biller acceptance over identical terms.
4. **Relayed and direct opening.** Either party can call directly, or any relayer can submit both signatures.
5. **Exact settlement.** Every occurrence uses the gross amount and fee accepted at creation.
6. **Sequential time unlocks.** Only the exact next index can settle, and never before it unlocks.
7. **Catch-up without rescheduling.** Unpaid unlocked occurrences remain collectible in order.
8. **Pinned destination.** Settlement cannot redirect the recipient after opening.
9. **Open or named external settlement.** The parties can create a caller marketplace or choose one external operator.
10. **Independent biller fallback.** The biller can always settle and does not receive a caller fee.
11. **Bilateral cancellation.** Either payer or biller can stop every unpaid and future occurrence.
12. **No core administration.** No owner, proxy, or arbitrary execution path can widen an opened mandate.

## 6. Non-goals

1. **No payment guarantee.** A valid mandate does not guarantee balance, allowance, or token availability.
2. **No changing payment amounts.** Any material schedule change requires a new mandate.
3. **No calendar billing engine.** Cadence is a fixed number of seconds from the generated start.
4. **No settlement window.** Once an occurrence unlocks, it remains collectible until settlement or cancellation.
5. **No automatic transaction scheduling.** An external actor must submit every settlement.
6. **No built-in batch settlement.** Catch-up uses repeated one-occurrence calls.
7. **No permit entrypoint.** The current contract neither accepts permit data nor makes arbitrary activation calls.
8. **No callbacks to application contracts.** The only external interactions are ERC-20 token transfers and signature
   validation required by ERC-1271.
9. **No refunds or chargebacks.** Completed transfers are final at the contract layer.
10. **No service adjudication.** The contract does not decide whether goods or services were delivered.
11. **No merchant certification.** Biller acceptance does not prove that the biller is trustworthy.
12. **No onchain token allowlist.** Any token address in bilaterally accepted terms may be used; product support is a
    separate policy.

## 7. Actors and trust boundaries

| Actor | Role | Trust boundary |
|---|---|---|
| Payer | Token holder that grants allowance and authorizes a mandate | Trusts `FixedMandate` code up to its remaining token allowance |
| Biller | Commercial counterparty that accepts the mandate | May directly collect only exact unlocked occurrences |
| Recipient | Pinned address receiving settlement proceeds | May differ from the biller and cannot be changed after opening |
| Settler | Open or named external transaction submitter | Can consume only the next unlocked index and is the destination of the exact accepted fee transfer |
| `FixedMandate` | Immutable shared ERC-20 spender and fixed schedule state machine | Must not transfer outside an opened mandate's rules |
| Token | Contract executing balance and allowance changes | Defines actual transfer semantics and may invoke callbacks |
| Wallet/account | Presents terms, signs or calls, manages allowance, and exposes cancellation | Must make exact amount, cadence, backlog, and open-ended exposure legible |
| Indexer | Reconstructs mandate lifecycle from state and successful logs | Mirrors onchain results and handles reorgs; does not define validity |
| Operator | Runs APIs, dashboards, notifications, and settlement automation | Must not be treated as a source of onchain authority unless named in the mandate |

The biller and recipient are distinct concepts. The biller accepts the relationship and retains direct settlement
authority. The recipient receives proceeds. The settler pays transaction gas and may receive a fee. Those addresses may
be controlled by one organization, but the contract does not assume that they are.

`FixedMandate` is a shared spender, not a custodian. A defect in its code can expose any allowance granted to it. This
is why immutability, source verification, constrained external calls, rigorous testing, and conservative token support
are part of the product's trust model.

## 8. Mechanism overview

A fixed settlement succeeds only when all of the following are true:

1. payer authority and biller acceptance opened the exact mandate;
2. the mandate is not cancelled;
3. the caller is the biller, the named external settler, or any caller under open settlement;
4. the supplied payment index equals the stored settled payment count;
5. enough periods have elapsed to unlock that index;
6. a finite schedule has not exhausted its accepted count; and
7. the selected token accepts the required `transferFrom` call or calls.

The contract does not explicitly query balance and allowance before settlement. It relies on the token to accept or
reject `transferFrom`. A failed token call reverts the complete settlement.

Index zero unlocks at opening. Missed occurrences are not assigned to separate settlement windows and do not expire.
If five indices are unlocked and none has settled, the eligible caller can submit indices zero through four in rapid
succession.

## 9. Authorization model

### Fixed mandate terms

The `Mandate` object binds:

| Field | Meaning |
|---|---|
| `payer` | Token holder whose allowance to `FixedMandate` may be spent |
| `biller` | Counterparty accepting the schedule and retaining direct settlement authority |
| `recipient` | Pinned proceeds destination |
| `settler` | Named external caller, or zero for open external settlement |
| `token` | ERC-20 address used for payment |
| `payerGrossPerPayment` | Exact nominal amount pulled for every occurrence |
| `settlerFeePerPayment` | Exact portion of gross paid to an eligible non-biller caller |
| `periodLength` | Fixed number of seconds between occurrence unlocks |
| `totalPayments` | Finite occurrence count, or zero for an open-ended schedule |
| `termsHash` | Nonzero commitment to offchain commercial terms or metadata |
| `nonce` | Payer unordered nonce used for uniqueness, replay protection, and pre-opening invalidation |

The mandate digest is EIP-712 domain-separated by chain and `FixedMandate` deployment. Changing any field produces a
different mandate identity.

The schedule start and signature deadlines are not mandate fields. The contract generates `startedAt` from
`block.timestamp` when opening succeeds. Payer and biller authorization wrappers each carry their own submission
deadline.

### Payer authorization and biller acceptance

The neutral opening path requires both:

- payer signature over `MandateAuthorization(mandate, signatureDeadline)`; and
- biller signature over `MandateAcceptance(mandate, signatureDeadline)`.

The distinct typed-data roles prevent one role's signature from being used as the other role's authorization. EOA and
ERC-1271 contract signers are supported. A direct party-specific opening call substitutes `msg.sender` authority only
for that party and still verifies the counterparty signature.

Acceptance cannot widen payer authority. Any field mismatch changes the digest and causes signature validation or
mandate lookup to fail.

### Fixed payment authority

Opening authorizes the complete schedule. Settlement carries the full mandate terms and an expected next payment
index. The terms reconstruct the mandate ID; the index protects a caller from a stale transaction unexpectedly
consuming a later occurrence.

The caller cannot provide a payment amount, recipient, token, historical period, or fee different from the opened
terms.

### Cancellation authorization

Either party may cancel an opened mandate:

1. the payer calls `cancelMandate`;
2. the biller calls `cancelMandateAsBiller`;
3. anyone submits an authorizer-bound payer cancellation signature; or
4. anyone submits an authorizer-bound biller cancellation signature.

Signed cancellation binds the mandate ID, authorizer address, cancellation nonce, deadline, chain, and the
`FixedMandate` deployment. For distinct payer and biller addresses, the authorizer field prevents one party's
authorization from being attributed to the other, including when two ERC-1271 wallets share an owner or validator.

Cancellation nonce state is scoped by authorizer. If payer and biller are the same address they necessarily share that
address's nonce namespace. Direct cancellation does not consume a signed-cancellation nonce.

Cancellation applies only to an already opened mandate. It blocks every accrued unpaid occurrence and every future
unlock. It does not reverse completed transfers or reduce ERC-20 allowance.

## 10. Mandate creation lifecycle

The lifecycle is:

```text
offchain terms
-> payer authorization
-> biller acceptance
-> opening transaction
-> generated onchain start and immediately unlocked index zero
-> sequential settlement of unlocked occurrences
-> finite payment completion and/or cancellation
```

### Opening routes

The reference implementation exposes three routes:

| Route | Caller authority | Required counterparty authority |
|---|---|---|
| Neutral relay | none | payer signature and biller signature |
| Direct payer | `msg.sender == payer` | biller signature |
| Direct biller | `msg.sender == biller` | payer signature |

A settler does not need a dedicated opening function. It can use the neutral relay route with both authorizations.

### Field validation

Opening rejects a mandate when:

- payer, biller, recipient, or token is zero;
- payer gross is zero;
- period length is zero;
- `termsHash` is zero;
- settler fee is greater than or equal to payer gross; or
- the settler equals the biller while a nonzero external-caller fee is configured.

The settler may be zero, which means open external settlement. The fee may also be zero.

The reference implementation accepts some finite count values that its settlement counter cannot represent. Those
mandates can open but cannot complete. Integrations must reject unsupported counts, and production should align opening
validation with settlement state. An open-ended mandate has the same technical execution ceiling, but it is not a
payer-selected spend limit or useful protection.

### Generated schedule start

Opening records the current block timestamp after authorization checks pass. Index zero is immediately unlocked. The
parties do not sign an intended future start.

This lets the submitter choose when to seek inclusion while the applicable opening-signature deadline or deadlines
remain valid; the block producer supplies the timestamp ultimately recorded. Checkout and billing systems should use
suitable deadlines, submit promptly, wait for finality, and present the actual `startedAt` from the opening event rather
than an offchain estimate.

### Creation identity and replay protection

The EIP-712 digest of the complete mandate is its state key. Successful opening consumes the payer's unordered nonce.
That nonce cannot then open the same or a different mandate. The payer can invalidate unused nonce bits before opening
by calling `invalidateUnorderedNonces`.

Nonce invalidation prevents a future open; it does not cancel a mandate that is already open. The biller has no general
pre-opening nonce invalidation function. Biller acceptance instead has its signed deadline, and an opened mandate can be
cancelled by either party.

## 11. `FixedMandate` state model

For each mandate ID the contract stores:

| State | Purpose |
|---|---|
| `opened` | Proves aligned authority created the mandate |
| `cancelled` | Blocks all later settlement |
| `startedAt` | Contract-generated schedule anchor |
| `settledPaymentCount` | Number of consumed occurrences and exact next payment index |

It also stores:

- the payer unordered-nonce bitmap used for opening replay protection and invalidation; and
- authorizer-scoped used cancellation nonces.

Unlock count is derived rather than advanced by a periodic job. There is no stored current-period bucket, due-date
record, or mutable schedule cursor beyond the settled count.

## 12. Allowance activation

`FixedMandate` needs token allowance before it can pull. The current contract has no permit-assisted opening or
settlement entrypoint and makes no arbitrary activation call.

For a token with compatible EIP-2612 support, the payer may submit a permit to the token separately. That still requires
a permit signature distinct from mandate authorization. A smart account may batch its token approval and
`FixedMandate` call through account infrastructure. Neither flow changes the contract's security model: `FixedMandate`
remains the approved spender.

Most token permit implementations cannot validate an ERC-1271 contract-wallet signature. A contract account therefore
normally approves `FixedMandate` through its own transaction execution path.

The permit deadline, where permit is used externally, ordinarily limits submission of the permit. It does not cause the
resulting ERC-20 allowance to expire.

## 13. Settlement lifecycle

### Unlock calculation

For an opened mandate:

```text
elapsed periods = floor((current block time - startedAt) / periodLength)
unlocked count = elapsed periods + 1

if totalPayments is nonzero:
    unlocked count = min(unlocked count, totalPayments)
```

An attempted index must equal `settledPaymentCount` and be lower than the unlocked count. This enforces both sequencing
and time. It also caps a finite schedule without mutating separate period state.

### Caller and fee policy

The biller may always call. Otherwise:

- a nonzero `settler` requires that exact caller; or
- a zero `settler` permits any caller.

The actual settlement fee is:

```text
if caller == biller:
    fee = 0
else:
    fee = settlerFeePerPayment
```

For a standard ERC-20, a zero-fee settlement requests one transfer of full gross to the recipient. A fee-bearing
settlement requests `gross - fee` to the recipient and `fee` to the caller. The sum of requested `transferFrom` amounts
is therefore constant across both paths. These are nominal call amounts, not guaranteed net balance deltas when the
payer is also a destination; a standard-token self-transfer can consume allowance while leaving net balance unchanged.

### State, event, and token-call ordering

The implementation orders a successful attempt as follows:

```text
1. derive mandate ID and load state
2. validate opened, cancellation, caller, index, unlock, and finite count
3. increment settledPaymentCount
4. derive actual fee
5. emit PaymentSettled
6. call token transferFrom once or twice
```

The state update and settlement event occur before token interactions. If a later token call reverts, EVM atomicity
rolls back the count, token effects, and event, leaving the index retryable.

Emitting before token calls also makes callback nesting indexable. An outer settlement emits its lower payment index
before a token callback can make a nested settlement for the next index. Indexers should still regard the record as
final only after the whole transaction succeeds.

### Callback behavior

The contract intentionally has no reentrancy mutex. A callback cannot replay the outer index because the count has
already advanced. Every nested call must independently pass mandate, cancellation, caller, expected-index, unlock, and
finite-count checks.

Under open external settlement, a callback-capable token can call `settle` and consume another already-unlocked index.
As the nested caller, the token contract can receive that occurrence's settler fee. This behavior remains bounded by
the number of unlocked occurrences, the accepted fixed terms, and token-call success.

When a mandate names a settler, a token callback fails the caller check only when the token is neither the biller nor the
named settler. It then consumes no occurrence and receives no fee. This is a settlement-caller property, not a general
claim that callbacks are harmless. A token signed as the biller or named settler has that role's authority, and a
malicious token can fabricate balance behavior outside the contract entirely.

Production integrations should use stablecoins with understood behavior and treat callback-heavy tokens as outside the
supported economic boundary.

### Catch-up and finite completion

Unlocked occurrences never expire. Several missed occurrences can be settled one after another at the same timestamp.
There is no requirement to identify which historical billing period an occurrence belongs to; its zero-based index is
the canonical identity.

A finite schedule has a payer-selected count. Within the supported implementation range, it stops unlocking at
`totalPayments` and reaches payment completion only after every authorized index settles. Cancellation blocks any
remaining settlement. If it happens before payment completion, the schedule ends incomplete; the contract can also
record cancellation after payment completion. An open-ended schedule continues unlocking until cancellation and has no
payer-selected finite lifetime gross bound.

### Cancellation and transaction ordering

Cancellation sets mandate state before emitting its record. Once recorded, settlement reverts even for previously
unlocked arrears.

If cancellation and settlement transactions are both pending, chain ordering determines the result. A settlement
ordered first may complete; a cancellation ordered first causes the later settlement to revert. Token allowance
revocation is the broader emergency brake but has the same transaction-ordering limitation.

## 14. Guarantees and non-guarantees

Under standard ERC-20 transfer semantics, `FixedMandate` guarantees:

1. no opened mandate without payer authority and biller acceptance over identical fixed terms;
2. no settlement for an unopened or cancelled mandate;
3. no recipient, token, gross amount, cadence, count, or caller policy different from the opened terms;
4. only the exact next payment index can settle;
5. no index settles before its time-derived unlock;
6. no finite schedule settles more than its accepted count;
7. an eligible non-biller caller is the destination of the exact accepted nominal fee transfer;
8. direct biller settlement records and pays zero fee;
9. failed token transfers do not advance the settled count or leave a settlement event;
10. opening and cancellation signatures are domain-separated by chain and `FixedMandate` deployment;
11. cancellation signatures are bound to the payer or biller authorizer role; and
12. no owner, proxy, or arbitrary call path can widen mandate authority.

`FixedMandate` does not guarantee:

1. payer balance or allowance;
2. successful payment at an unlock time;
3. automatic retries or onchain scheduling;
4. service delivery, refunds, or chargeback rights;
5. future non-cancellation;
6. cancellation priority over an earlier ordered settlement;
7. privacy on a public chain;
8. token availability when an issuer pauses or blacklists an address;
9. observed balance deltas for fee-on-transfer, rebasing, callback-heavy, dishonest, or otherwise non-standard tokens;
10. net balance outcomes implied by nominal transfer amounts when role addresses overlap;
11. a payer-selected finite lifetime exposure for an open-ended schedule; or
12. biller legitimacy beyond acceptance of the specific mandate.

"Exact" amounts in the contract are nominal `transferFrom` arguments. A token can apply fees, rebase balances, lie
about success, or implement other economics that make actual account deltas differ. The contract cannot repair a
malicious asset's accounting.

## 15. Allowance lifecycle

Mandate authority and ERC-20 allowance are separate controls:

```text
Cancel fixed mandate: stops this payer-biller schedule.
Revoke allowance to FixedMandate: stops all FixedMandate pulls from this payer for this token.
```

Cancellation is precise. Allowance revocation is broad.

A payer may choose either:

| Allowance posture | User meaning | Tradeoff |
|---|---|---|
| Standing `FixedMandate` approval | Approve immutable `FixedMandate` once; bilateral mandates constrain later pulls | Lower friction; larger exposure if `FixedMandate` code is defective |
| Bounded allowance budget | Keep allowance near the aggregate intended runway | Lower allowance exposure; requires updates as runway is consumed |

For a finite mandate, a simple upper estimate of remaining nominal exposure is:

```text
(totalPayments - settledPaymentCount) * payerGrossPerPayment
```

This includes already unlocked arrears. Across several active mandates, a wallet can aggregate the remaining amounts,
while recognizing that all mandates compete for one token allowance.

An open-ended mandate has no payer-selected finite remaining total. A wallet must present that fact and let the payer
choose an allowance runway rather than describe the authorization as lifetime-bounded. Implementation ceilings are not
spend protection.

Cancelling mandates does not lower token allowance. A payer leaving the system should revoke its allowance to
`FixedMandate` as a separate action.

## 16. Security model

### `FixedMandate` risk

`FixedMandate` is a shared spender. Its launch posture requires:

- immutable deployment;
- no owner or upgrade proxy;
- no arbitrary external execution;
- token calls limited to settlement `transferFrom` operations;
- complete EIP-712 domain separation;
- ERC-1271 support for contract accounts;
- effects before token interactions;
- independent validation of every nested settlement;
- explicit treatment of unsupported token economics;
- verified source, focused audits, and broad tests; and
- observable state and events for independent reconciliation.

### Signature risk

Opening signatures bind every commercial term, the payer nonce, a role-specific typed-data wrapper, a deadline, chain
context, and `FixedMandate` deployment. Cancellation signatures additionally bind the authorizer role and their
cancellation nonce.

Contract addresses are validated exclusively through ERC-1271. An ECDSA signature by a contract wallet's owner is not
accepted as a substitute for the wallet's own ERC-1271 policy. EOA validation supports ordinary and compact signatures.

Applications must render chain, `FixedMandate` address, parties, token, amount, cadence, count, recipient, settler, fee,
terms commitment, nonce, and deadline before signing.

### Schedule-anchor risk

Because `startedAt` is generated rather than signed, a relayer holding both opening signatures controls when to seek
inclusion while both remain valid; the block producer supplies the confirmed block timestamp that becomes the anchor.
Short, deliberate deadlines and prompt submission limit relayer discretion. Systems must use the confirmed opening
record as the schedule source of truth.

### Token risk

Token selection is permissionless at the contract layer because token is a bilaterally signed field. That does not make
all tokens economically supported.

Initial product integrations should constrain their asset list offchain to reviewed stablecoins. No-return tokens may
work through safe transfer handling, while false-return and non-contract token addresses revert. Fee-on-transfer,
rebasing, callback-heavy, blacklisting, pausable, or dishonest tokens create risks the contract cannot normalize.

The absence of a reentrancy guard is deliberate and must remain visible in audit and product documentation. Sequential
state prevents same-index replay; it does not prohibit independently valid nested settlement of another unlocked index
under open caller policy.

### Time, ordering, and chain risk

`FixedMandate` uses `block.timestamp`. Small validator-controlled timestamp variance should be considered at unlock
boundaries. Cadence is duration-based, not calendar-aware.

Settlement, cancellation, allowance revocation, and nonce invalidation take effect according to onchain ordering.
Indexers must handle chain reorganizations before treating records as operationally final.

## 17. Observable protocol surface

The reference implementation exposes four lifecycle records:

| Record | Purpose |
|---|---|
| `MandateOpened` | Identifies the complete opened schedule and its generated start |
| `PaymentSettled` | Identifies one consumed zero-based payment index, nominal gross, actual fee, and caller |
| `MandateCancellation` | Identifies the mandate and payer or biller that directly called or signed cancellation |
| `UnorderedNonceInvalidation` | Records a mask ORed into the payer's opening nonce bitmap, including possible no-op bits |

The settlement event is emitted after count consumption but before token calls. It is durable only if the complete
transaction succeeds. This ordering ensures that a successful nested settlement event follows its outer lower index.

An indexer should use at least:

```text
(chain ID, FixedMandate address, mandate ID, payment index)
```

as a settlement identity, and order confirmed logs by block, transaction, and log position. It should verify that
successful payment indices for a mandate are contiguous. It must also handle chain reorganizations and avoid marking a
payment complete from a pending transaction simulation or reverted receipt.

Relevant read surfaces include:

- `mandateStates(mandateId)` for opened, cancelled, start, and settled count;
- `unlockedPaymentCount(mandate)` for a current opened and uncancelled schedule;
- `nonceBitmap(payer, wordPos)` for opening nonce status;
- `cancellationNonceUsed(authorizer, nonce)` for signed cancellation status;
- mandate ID and typed-data hash helpers; and
- the EIP-712 domain separator and ERC-5267 domain information.

`unlockedPaymentCount` reverts after cancellation. Historical products should retain events and read stored mandate state
rather than depending on that convenience view alone.

## 18. Full-stack product boundary

The contract deliberately leaves product behavior offchain. A usable system still needs:

- commercial-term negotiation and a canonical `termsHash` process;
- typed-data construction and human-readable signing screens;
- token approval and allowance runway UX;
- relayed opening and confirmation tracking;
- a scheduler that derives newly unlocked indices from confirmed `startedAt`;
- settlement preflight, submission, replacement, retry, and gas management;
- event indexing with reorg handling;
- reconciliation of gross, fee, recipient proceeds, and settlement caller;
- payer and biller dashboards for arrears and cancellation;
- notifications for failed payments, depleted allowance, low balance, cancellation, and finite completion; and
- access controls around API and operator keys that are independent of onchain mandate authority.

The offchain scheduler must not invent a due amount. It submits the fixed terms and exact next index already enforced by
the contract. A compromised dashboard or settler cannot change those values, but it can delay submission, repeatedly
submit transactions, leak metadata, or misuse any unrelated operational credentials it controls.

The product should retain customer identity, plan names, service descriptions, receipts, tax data, and support notes
offchain. `termsHash` can commit to a canonical representation, but the contract neither retrieves nor interprets it.

## 19. Comparison

| Mechanism | What it gives | What it lacks relative to Fixed Mandate |
|---|---|---|
| Raw ERC-20 approval | Spender authorization | No bilateral schedule, recipient pinning, sequential unlock, or mandate cancellation |
| EIP-2612 permit | Signature-based approval | Creates allowance but no recurring payment state |
| Permit2 | Shared approval and signature-transfer infrastructure | Is not an exact recurring schedule state machine by itself |
| EIP-3009 | Signed one-shot token transfer | Requires new authority for later transfers and stores no bilateral fixed schedule |
| Prepaid vault | Isolated funded budget | Requires custody or explicit top-ups |
| Account-native policy | Wallet-enforced spending rules | Requires account-specific installation and a separate implementation surface |
| Fixed Mandate | Bilateral exact schedules over ordinary ERC-20 allowance | Requires allowance to `FixedMandate` and external settlement automation |

The trust shape is Permit2-like: users approve a shared public spender and later operations are constrained by signed
policy. The purpose is different. `FixedMandate` standardizes a bilaterally accepted, cancellable, exact
recurring schedule and its time accounting.

## 20. Initial implementation scope

The reference implementation includes:

- immutable, no-admin `FixedMandate` deployment logic;
- EIP-712 payer authorization and biller acceptance;
- EOA, EIP-2098, normalized recovery-ID, and ERC-1271 signature handling;
- neutral-relay, direct-payer, and direct-biller opening;
- payer unordered opening nonces and bitmap invalidation;
- contract-generated start and immediate index-zero unlock;
- finite and open-ended fixed schedules;
- sequential catch-up settlement;
- open or named external caller policy with biller fallback;
- exact non-biller fee and biller fee waiver;
- payer and biller direct or signed cancellation;
- authorizer-bound cancellation nonces;
- lifecycle events and read helpers; and
- safe ERC-20 call handling within the documented token boundary.

Not included in `FixedMandate`:

- permit or Permit2 activation adapters;
- arbitrary permit calldata;
- an onchain scheduler or keeper;
- batch settlement;
- application callback hooks;
- token registry administration;
- account-native enforcement;
- vault funding;
- refunds or chargebacks;
- merchant registry;
- privacy infrastructure; or
- support guarantees for non-standard token economics.

## 21. Privacy

Public opening calldata, events, storage, settlement calls, and token transfers expose substantial metadata. Depending on
the route, observers can learn or infer:

- payer, biller, recipient, and settler addresses, plus the `FixedMandate` deployment address;
- token, exact gross, exact fee, cadence, and schedule size;
- payer nonce, terms commitment, generated start, and payment index;
- authorization deadlines and submitted signatures; and
- payment timing, arrears catch-up, cancellation, allowance, and balances.

The launch design should minimize unnecessary metadata:

- keep identity, product names, service details, receipts, and human-readable terms offchain;
- use a deliberately constructed terms commitment;
- avoid placing secrets or personal data in `termsHash` preimages that may later be disclosed; and
- emit and index only data needed for enforcement, wallet display, accounting, and support.

Routing proceeds through a processor or omnibus recipient can obscure the final merchant relationship but adds custody,
ledger, payout, and compliance obligations. Full cryptographic privacy requires a separate settlement architecture.

## 22. Validation requirements

The implementation and full stack should be validated against behavior, not only ABI compatibility.

Required opening properties include:

- every commercial field and the execution domain affect mandate identity;
- no route opens without the required payer and biller authority;
- direct routes replace only the caller's own signature;
- expired, malformed, wrong-role, wrong-domain, and altered-term signatures fail;
- ERC-1271 policy is respected for contract accounts;
- invalid mandate fields fail before state is created;
- successful opening records the actual block timestamp and unlocks only index zero initially;
- a payer nonce cannot open two mandates; and
- bitmap invalidation blocks later use without affecting already opened mandates.

Required settlement properties include:

- unopened and cancelled mandates cannot settle;
- wrong, skipped, stale, future, and not-yet-unlocked indices fail;
- exact boundary timestamps unlock exactly one additional occurrence;
- finite schedules never exceed their count;
- unlocked arrears settle sequentially in one block;
- separate mandates maintain independent counters;
- open and named caller policies are enforced while biller fallback remains available;
- non-biller callers receive the exact nominal fee and biller callers receive none;
- balance, allowance, false-return, or other token-call failure rolls back count and event;
- settlement records are emitted in payment-index order before callback opportunities;
- open-policy callbacks can consume only independently valid unlocked indices; and
- under named settlement, a malicious token callback that is neither the biller nor the named settler consumes no index
  and receives no fee.

Required cancellation properties include:

- only the payer or biller may directly cancel;
- signed cancellation verifies the selected payer or biller authorizer;
- signature deadline, mandate ID, execution domain, and authorizer nonce are bound;
- unrelated signers and mandate-party substitution cannot cancel;
- when payer and biller are distinct addresses, one role's authorization cannot be replayed through the other role;
- failed cancellation does not consume its nonce;
- cancellation stops accrued and future occurrences; and
- settlement-versus-cancellation ordering matches chain transaction order.

Cross-cutting validation should include unit tests, fuzz tests, stateful invariants, callback-capable and non-standard token
mocks, gas snapshots, bytecode-size checks, ABI/event review, and full-stack indexing tests that include reorgs and nested
logs.

## 23. Future work

Variable Mandate is future work. Its requirements and design will be informed by evidence from a full-stack rollout of
`FixedMandate`, including payer, biller, wallet, settler, indexing, support, and operational experience.
This paper does not propose its mechanism.

## 24. Why this is worth building

`FixedMandate` does not remove ERC-20 allowance risk. It gives that risk a precise commercial shape.

The difficult part of an exact recurring stablecoin payment is not moving tokens. It is expressing a standing schedule
that payer, biller, wallet, settler, indexer, and support systems can all interpret the same way. Bilateral creation,
contract-generated start, sequential time unlocks, deterministic fees, and bilateral cancellation provide that shared
object without custody, token-standard changes, or merchant-specific spender contracts.

The primitive is deliberately narrow. That makes it possible to test, audit, deploy, integrate, and learn from the full
stack before expanding the protocol surface.

## References

- ERC-20 Token Standard: https://eips.ethereum.org/EIPS/eip-20
- ERC-1271 Standard Signature Validation Method for Contracts: https://eips.ethereum.org/EIPS/eip-1271
- EIP-2612 Permit Extension for ERC-20 Signed Approvals: https://eips.ethereum.org/EIPS/eip-2612
- EIP-3009 Transfer With Authorization: https://eips.ethereum.org/EIPS/eip-3009
- EIP-712 Typed Structured Data Hashing and Signing: https://eips.ethereum.org/EIPS/eip-712
- EIP-7702 Set EOA Account Code: https://eips.ethereum.org/EIPS/eip-7702
- ERC-4337 Account Abstraction Using Alt Mempool: https://eips.ethereum.org/EIPS/eip-4337
- Uniswap Permit2 overview: https://docs.uniswap.org/contracts/permit2/overview
