// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {IUnorderedNonces} from "./IUnorderedNonces.sol";

/// @title Fixed Mandate Executor interface
/// @notice Immutable ERC-20 pull-payment executor for bilateral fixed-amount mandates.
/// @dev The executor is an independent shared ERC-20 spender. Opening sets the schedule start to the
/// current block timestamp. Cancellation stops mandate settlement but does not revoke token allowance.
interface IFixedMandate is IERC5267, IUnorderedNonces {
    /// @notice Fixed payment schedule authorized by a payer and accepted by a biller.
    /// @dev The EIP-712 digest of this struct under the executor domain is the mandate id. The schedule
    /// start is deliberately absent because the contract records it when the mandate opens.
    struct Mandate {
        /// @notice Token holder whose ERC-20 allowance is spent by the executor.
        address payer;
        /// @notice Party accepting the mandate and retaining direct settlement authority.
        address biller;
        /// @notice Pinned recipient for settlement proceeds.
        address recipient;
        /// @notice Named external settlement caller. `address(0)` permits any external caller.
        address settler;
        /// @notice ERC-20 token pulled from `payer`.
        address token;
        /// @notice Exact nominal payer gross for every payment, in raw token units.
        uint256 payerGrossPerPayment;
        /// @notice Exact reward deducted from payer gross for a non-biller settlement caller.
        /// @dev Zero disables the reward. Biller settlement always waives this reward.
        uint256 settlerFeePerPayment;
        /// @notice Fixed interval in seconds between payment unlocks.
        uint256 periodLength;
        /// @notice Total number of payments. Zero represents an open-ended schedule.
        /// @dev The current implementation stores `settledPaymentCount` as `uint120`, so it can settle at most
        /// `type(uint120).max` occurrences. Positive values above that bound cannot complete.
        uint256 totalPayments;
        /// @notice Offchain terms or metadata commitment.
        bytes32 termsHash;
        /// @notice Payer unordered nonce consumed when the mandate opens.
        uint256 nonce;
    }

    /// @notice Stored lifecycle and settlement state for an opened fixed mandate.
    struct MandateState {
        /// @notice True once the mandate has been opened.
        bool opened;
        /// @notice True once the payer or biller has cancelled the mandate.
        bool cancelled;
        /// @notice Contract-generated schedule anchor recorded when the mandate opened.
        uint120 startedAt;
        /// @notice Number of payments successfully settled, also the next payment index.
        uint120 settledPaymentCount;
    }

    /// @notice Fixed mandate terms are malformed.
    error InvalidMandate();
    /// @notice Caller lacks direct authority for the requested action.
    error InvalidCaller();
    /// @notice EIP-712 or ERC-1271 signature validation failed.
    error InvalidSignature();
    /// @notice A typed-data authorization deadline has passed.
    error SignatureExpired();
    /// @notice A cancellation nonce has already been used or invalidated.
    error InvalidCancellationNonce();
    /// @notice The supplied mandate id is already open.
    error MandateAlreadyOpened();
    /// @notice The supplied mandate has not been opened.
    error MandateNotOpen();
    /// @notice The supplied mandate has already been cancelled.
    error MandateCancelled();
    /// @notice The supplied payment index is not the next unsettled index.
    error UnexpectedPaymentIndex();
    /// @notice The next payment has not unlocked yet or a finite schedule is complete.
    error PaymentNotUnlocked();
    /// @notice Caller is neither the biller nor an eligible external settler.
    error InvalidSettler();

    /// @notice Emitted when payer authorization and biller acceptance open a fixed mandate.
    /// @param mandateId EIP-712 fixed mandate digest used as the state key.
    /// @param payer Token holder whose allowance may be spent.
    /// @param biller Party that accepted the fixed mandate.
    /// @param token ERC-20 token pulled from the payer.
    /// @param recipient Pinned recipient for settlement proceeds.
    /// @param settler Named external caller, or zero for open settlement.
    /// @param payerGrossPerPayment Exact nominal payer gross for each occurrence.
    /// @param settlerFeePerPayment Exact fee for an eligible non-biller caller.
    /// @param periodLength Seconds between occurrence unlocks.
    /// @param totalPayments Finite count, or zero for an open-ended schedule. The current implementation's
    /// `uint120` settlement counter limits successful occurrences to `type(uint120).max`.
    /// @param startedAt Contract-generated schedule anchor.
    /// @param nonce Payer unordered nonce consumed by this mandate.
    /// @param termsHash Offchain terms or metadata commitment.
    event MandateOpened(
        bytes32 indexed mandateId,
        address indexed payer,
        address indexed biller,
        address token,
        address recipient,
        address settler,
        uint256 payerGrossPerPayment,
        uint256 settlerFeePerPayment,
        uint256 periodLength,
        uint256 totalPayments,
        uint256 startedAt,
        uint256 nonce,
        bytes32 termsHash
    );

    /// @notice Emitted after an occurrence is consumed and before its token transfers.
    /// @dev The event and state update both roll back if a subsequent token transfer fails.
    /// @param mandateId Fixed mandate under which the occurrence settled.
    /// @param paymentIndex Zero-based occurrence index consumed by this settlement.
    /// @param payer Token holder whose allowance was spent.
    /// @param biller Party that accepted the fixed mandate.
    /// @param recipient Proceeds recipient pinned by the mandate.
    /// @param token ERC-20 token transferred.
    /// @param payerGross Exact nominal payer gross for this occurrence.
    /// @param fee Actual reward paid to `settlementCaller`; zero when the biller settles.
    /// @param settlementCaller Caller that submitted settlement.
    event PaymentSettled(
        bytes32 indexed mandateId,
        uint256 indexed paymentIndex,
        address indexed payer,
        address biller,
        address recipient,
        address token,
        uint256 payerGross,
        uint256 fee,
        address settlementCaller
    );

    /// @notice Emitted when a payer or biller cancels an opened fixed mandate.
    /// @param mandateId Cancelled fixed mandate id.
    /// @param payer Payer whose mandate was cancelled.
    /// @param cancelledBy Party that directly called or signed the cancellation.
    event MandateCancellation(bytes32 indexed mandateId, address indexed payer, address indexed cancelledBy);

    /// @notice Opens a fixed mandate using payer authorization and biller acceptance.
    /// @dev Any caller may submit. Successful opening records `block.timestamp` as the schedule start.
    /// @param mandate Full fixed terms authorized by payer and accepted by biller.
    /// @param payerSignatureDeadline Expiry for the payer authorization.
    /// @param billerSignatureDeadline Expiry for the biller acceptance.
    /// @param payerSignature EIP-712 or ERC-1271 signature from `mandate.payer`.
    /// @param billerSignature EIP-712 or ERC-1271 signature from `mandate.biller`.
    /// @return id Fixed mandate id opened by this call.
    function openMandate(
        Mandate calldata mandate,
        uint256 payerSignatureDeadline,
        uint256 billerSignatureDeadline,
        bytes calldata payerSignature,
        bytes calldata billerSignature
    ) external returns (bytes32 id);

    /// @notice Opens a fixed mandate using direct payer authority and biller acceptance.
    /// @dev Only `mandate.payer` may call. Successful opening records the current block timestamp.
    /// @param mandate Full fixed terms authorized by payer and accepted by biller.
    /// @param billerSignatureDeadline Expiry for the biller acceptance.
    /// @param billerSignature EIP-712 or ERC-1271 signature from `mandate.biller`.
    /// @return id Fixed mandate id opened by this call.
    function openMandateAsPayer(
        Mandate calldata mandate,
        uint256 billerSignatureDeadline,
        bytes calldata billerSignature
    ) external returns (bytes32 id);

    /// @notice Opens a fixed mandate using direct biller authority and payer authorization.
    /// @dev Only `mandate.biller` may call. Successful opening records the current block timestamp.
    /// @param mandate Full fixed terms authorized by payer and accepted by biller.
    /// @param payerSignatureDeadline Expiry for the payer authorization.
    /// @param payerSignature EIP-712 or ERC-1271 signature from `mandate.payer`.
    /// @return id Fixed mandate id opened by this call.
    function openMandateAsBiller(
        Mandate calldata mandate,
        uint256 payerSignatureDeadline,
        bytes calldata payerSignature
    ) external returns (bytes32 id);

    /// @notice Settles exactly one unlocked fixed payment.
    /// @dev The biller may always call. Otherwise the named settler must call, or any caller may act
    /// when the mandate settler is zero. `nextPaymentIndex` prevents stale calls from consuming a
    /// later occurrence. A biller call waives the configured fee and sends full payer gross to recipient.
    /// @param mandate Opened fixed mandate terms.
    /// @param nextPaymentIndex Exact next unsettled occurrence expected by the caller.
    function settle(Mandate calldata mandate, uint256 nextPaymentIndex) external;

    /// @notice Cancels an opened fixed mandate by direct payer transaction authority.
    /// @param mandate Fixed mandate terms whose digest identifies the mandate to cancel.
    function cancelMandateAsPayer(Mandate calldata mandate) external;

    /// @notice Cancels an opened fixed mandate by direct biller transaction authority.
    /// @param mandate Fixed mandate terms whose digest identifies the mandate to cancel.
    function cancelMandateAsBiller(Mandate calldata mandate) external;

    /// @notice Cancels an opened fixed mandate using payer typed authorization.
    /// @param mandate Fixed mandate terms whose digest identifies the mandate to cancel.
    /// @param cancelNonce Payer cancellation replay-protection nonce.
    /// @param signatureDeadline Expiry for the cancellation authorization.
    /// @param payerSignature EIP-712 or ERC-1271 signature from `mandate.payer`.
    function cancelMandateWithPayerSignature(
        Mandate calldata mandate,
        uint256 cancelNonce,
        uint256 signatureDeadline,
        bytes calldata payerSignature
    ) external;

    /// @notice Cancels an opened fixed mandate using biller typed authorization.
    /// @param mandate Fixed mandate terms whose digest identifies the mandate to cancel.
    /// @param cancelNonce Biller cancellation replay-protection nonce.
    /// @param signatureDeadline Expiry for the cancellation authorization.
    /// @param billerSignature EIP-712 or ERC-1271 signature from `mandate.biller`.
    function cancelMandateWithBillerSignature(
        Mandate calldata mandate,
        uint256 cancelNonce,
        uint256 signatureDeadline,
        bytes calldata billerSignature
    ) external;

    /// @notice Returns the EIP-712 domain separator for this executor.
    /// @return Domain separator used for fixed-mandate typed-data digests.
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice Computes the mandate id for the supplied fixed terms.
    /// @param mandate Fixed mandate terms to hash under this executor's domain.
    /// @return id EIP-712 digest used as the fixed mandate state key.
    function mandateId(Mandate calldata mandate) external view returns (bytes32 id);

    /// @notice Computes the payer fixed-mandate authorization digest.
    /// @param mandate Fixed mandate terms wrapped in `MandateAuthorization`.
    /// @param signatureDeadline Authorization deadline included in the digest.
    /// @return digest EIP-712 digest signed by the payer.
    function hashMandateAuthorization(Mandate memory mandate, uint256 signatureDeadline)
        external
        view
        returns (bytes32 digest);

    /// @notice Computes the biller fixed-mandate acceptance digest.
    /// @param mandate Fixed mandate terms wrapped in `MandateAcceptance`.
    /// @param signatureDeadline Acceptance deadline included in the digest.
    /// @return digest EIP-712 digest signed by the biller.
    function hashMandateAcceptance(Mandate memory mandate, uint256 signatureDeadline)
        external
        view
        returns (bytes32 digest);

    /// @notice Computes an authorizer-bound cancellation digest.
    /// @param id Fixed mandate id to cancel.
    /// @param authorizer Payer or biller whose signature authorizes cancellation.
    /// @param nonce Cancellation nonce included in the digest.
    /// @param signatureDeadline Cancellation authorization deadline.
    /// @return digest EIP-712 digest signed by the authorizer.
    function hashCancellation(bytes32 id, address authorizer, uint256 nonce, uint256 signatureDeadline)
        external
        view
        returns (bytes32 digest);

    /// @notice Returns the number of payment occurrences unlocked for an opened mandate.
    /// @dev Reverts for an unopened or cancelled mandate.
    /// @param mandate Opened, uncancelled fixed mandate terms.
    /// @return count Number of occurrences unlocked since the generated start, capped for finite schedules.
    function unlockedPaymentCount(Mandate calldata mandate) external view returns (uint256 count);

    /// @notice Returns stored lifecycle and settlement state for a mandate id.
    /// @param id Fixed mandate id to query.
    /// @return opened True once the mandate has been opened.
    /// @return cancelled True once payer or biller has cancelled the mandate.
    /// @return startedAt Contract-generated schedule anchor.
    /// @return settledPaymentCount Number of successfully settled occurrences.
    function mandateStates(bytes32 id)
        external
        view
        returns (bool opened, bool cancelled, uint120 startedAt, uint120 settledPaymentCount);

    /// @notice Returns whether an authorizer cancellation nonce has been consumed.
    /// @param authorizer Payer or biller cancellation authorizer.
    /// @param cancelNonce Cancellation nonce to query.
    /// @return used True when the authorizer has consumed this nonce.
    function cancellationNonceUsed(address authorizer, uint256 cancelNonce) external view returns (bool used);
}
