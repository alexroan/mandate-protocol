// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IFixedMandate} from "./interfaces/IFixedMandate.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Signatures} from "./Signatures.sol";
import {UnorderedNonces} from "./UnorderedNonces.sol";

/// @notice Minimal immutable executor for recurring fixed-amount ERC-20 pull payments.
/// @dev No owner, upgrade path, arbitrary calldata execution, or shared mutable protocol state.
/// Token calls are limited to ERC-20 `transferFrom` using terms accepted by the payer and biller.
contract FixedMandate is IFixedMandate, EIP712, UnorderedNonces, Signatures {
    using SafeERC20 for IERC20;

    // "Mandate(address payer,address biller,address recipient,address token,uint256 payerGrossPerPayment,uint256 periodLength,uint256 totalPayments,bytes32 termsHash,uint256 nonce)"
    bytes32 private constant _MANDATE_TYPEHASH = 0x18add0b5f00bbaad860472e7219507efb46c1084f6a8ab757ceda221580760bf;
    // "MandateAuthorization(Mandate mandate,uint256 signatureDeadline)Mandate(address payer,address biller,address recipient,address token,uint256 payerGrossPerPayment,uint256 periodLength,uint256 totalPayments,bytes32 termsHash,uint256 nonce)"
    bytes32 private constant _MANDATE_AUTHORIZATION_TYPEHASH =
        0x1a438fc38a73c4c8b9376257eefd742fc92ac50d5c909c81a143645d1809cb1a;
    // "MandateAcceptance(Mandate mandate,uint256 signatureDeadline)Mandate(address payer,address biller,address recipient,address token,uint256 payerGrossPerPayment,uint256 periodLength,uint256 totalPayments,bytes32 termsHash,uint256 nonce)"
    bytes32 private constant _MANDATE_ACCEPTANCE_TYPEHASH =
        0x11d52a36ac858fa40741f69247304faa44104222685420bfed13702c9d1ebf29;
    // "Cancellation(bytes32 mandateId,address authorizer,uint256 nonce,uint256 signatureDeadline)"
    bytes32 private constant _CANCELLATION_TYPEHASH =
        0x11c57bb6a54f0e3ab0eada428058c7254168138845c71115231bfba8bbf010c8;

    /// @inheritdoc IFixedMandate
    mapping(bytes32 mandateId => MandateState state) public mandateStates;
    /// @inheritdoc IFixedMandate
    mapping(address authorizer => mapping(uint256 cancelNonce => bool used)) public cancellationNonceUsed;

    constructor() EIP712("FixedMandate", "1") {}

    // Open mandate

    /// @inheritdoc IFixedMandate
    function openMandate(
        Mandate calldata mandate,
        uint256 payerSignatureDeadline,
        uint256 billerSignatureDeadline,
        bytes calldata payerSignature,
        bytes calldata billerSignature
    ) external returns (bytes32 id) {
        _validateMandate(mandate);
        _verifyMandateAuthorization(mandate, payerSignatureDeadline, payerSignature);
        _verifyMandateAcceptance(mandate, billerSignatureDeadline, billerSignature);
        id = _openMandate(mandate);
    }

    /// @inheritdoc IFixedMandate
    function openMandateAsPayer(
        Mandate calldata mandate,
        uint256 billerSignatureDeadline,
        bytes calldata billerSignature
    ) external returns (bytes32 id) {
        if (mandate.payer != msg.sender) revert InvalidCaller();
        _validateMandate(mandate);
        _verifyMandateAcceptance(mandate, billerSignatureDeadline, billerSignature);
        id = _openMandate(mandate);
    }

    /// @inheritdoc IFixedMandate
    function openMandateAsBiller(
        Mandate calldata mandate,
        uint256 payerSignatureDeadline,
        bytes calldata payerSignature
    ) external returns (bytes32 id) {
        if (mandate.biller != msg.sender) revert InvalidCaller();
        _validateMandate(mandate);
        _verifyMandateAuthorization(mandate, payerSignatureDeadline, payerSignature);
        id = _openMandate(mandate);
    }

    function _validateMandate(Mandate calldata mandate) internal pure {
        if (
            mandate.payer == address(0) || mandate.biller == address(0) || mandate.recipient == address(0)
                || mandate.token == address(0) || mandate.payerGrossPerPayment == 0 || mandate.periodLength == 0
                || mandate.termsHash == bytes32(0)
        ) revert InvalidMandate();
    }

    function _openMandate(Mandate calldata mandate) internal returns (bytes32 id) {
        id = mandateId(mandate);
        uint120 startedAt = uint120(block.timestamp);

        // state modification block - reduces stack depth
        {
            MandateState storage state = mandateStates[id];
            if (state.opened) revert MandateAlreadyOpened();
            _useUnorderedNonce(mandate.payer, mandate.nonce);

            state.opened = true;
            state.startedAt = startedAt;
        }

        emit MandateOpened(
            id,
            mandate.payer,
            mandate.biller,
            mandate.token,
            mandate.recipient,
            mandate.payerGrossPerPayment,
            mandate.periodLength,
            mandate.totalPayments,
            startedAt,
            mandate.nonce,
            mandate.termsHash
        );
    }

    // Settle fixed payment

    /// @inheritdoc IFixedMandate
    function settle(Mandate calldata mandate, uint256 nextPaymentIndex) external {
        bytes32 id = mandateId(mandate);
        MandateState storage state = mandateStates[id];
        if (!state.opened) revert MandateNotOpen();
        if (state.cancelled) revert MandateCancelled();

        uint120 settledPaymentCount = state.settledPaymentCount;
        if (nextPaymentIndex != settledPaymentCount) revert UnexpectedPaymentIndex();
        if (nextPaymentIndex >= _unlockedPaymentCount(mandate, state.startedAt)) revert PaymentNotUnlocked();

        state.settledPaymentCount = settledPaymentCount + 1;

        emit PaymentSettled(
            id,
            nextPaymentIndex,
            mandate.payer,
            mandate.biller,
            mandate.recipient,
            mandate.token,
            mandate.payerGrossPerPayment,
            msg.sender
        );

        IERC20(mandate.token).safeTransferFrom(mandate.payer, mandate.recipient, mandate.payerGrossPerPayment);
    }

    /// @inheritdoc IFixedMandate
    function unlockedPaymentCount(Mandate calldata mandate) external view returns (uint256 count) {
        MandateState storage state = mandateStates[mandateId(mandate)];
        if (!state.opened) revert MandateNotOpen();
        if (state.cancelled) revert MandateCancelled();
        return _unlockedPaymentCount(mandate, state.startedAt);
    }

    function _unlockedPaymentCount(Mandate calldata mandate, uint256 startedAt) internal view returns (uint256) {
        uint256 elapsedPeriods = (block.timestamp - startedAt) / mandate.periodLength;
        uint256 totalPayments = mandate.totalPayments;
        if (totalPayments != 0 && elapsedPeriods >= totalPayments) return totalPayments;
        if (elapsedPeriods >= type(uint256).max) return type(uint256).max;
        return elapsedPeriods + 1;
    }

    // Cancel mandate

    /// @inheritdoc IFixedMandate
    function cancelMandateAsPayer(Mandate calldata mandate) external {
        if (msg.sender != mandate.payer) revert InvalidCaller();
        _cancel(mandateId(mandate), mandate.payer, mandate.payer);
    }

    /// @inheritdoc IFixedMandate
    function cancelMandateAsBiller(Mandate calldata mandate) external {
        if (msg.sender != mandate.biller) revert InvalidCaller();
        _cancel(mandateId(mandate), mandate.payer, mandate.biller);
    }

    /// @inheritdoc IFixedMandate
    function cancelMandateWithPayerSignature(
        Mandate calldata mandate,
        uint256 cancelNonce,
        uint256 signatureDeadline,
        bytes calldata payerSignature
    ) external {
        _cancelMandateWithSignature(mandate, mandate.payer, cancelNonce, signatureDeadline, payerSignature);
    }

    /// @inheritdoc IFixedMandate
    function cancelMandateWithBillerSignature(
        Mandate calldata mandate,
        uint256 cancelNonce,
        uint256 signatureDeadline,
        bytes calldata billerSignature
    ) external {
        _cancelMandateWithSignature(mandate, mandate.biller, cancelNonce, signatureDeadline, billerSignature);
    }

    function _cancel(bytes32 id, address payer, address cancelledBy) internal {
        MandateState storage state = mandateStates[id];
        if (!state.opened) revert MandateNotOpen();
        if (state.cancelled) revert MandateCancelled();
        state.cancelled = true;
        emit MandateCancellation(id, payer, cancelledBy);
    }

    function _cancelMandateWithSignature(
        Mandate calldata mandate,
        address authorizer,
        uint256 cancelNonce,
        uint256 signatureDeadline,
        bytes calldata signature
    ) internal {
        if (block.timestamp > signatureDeadline) revert SignatureExpired();
        if (cancellationNonceUsed[authorizer][cancelNonce]) revert InvalidCancellationNonce();
        bytes32 id = mandateId(mandate);
        bytes32 digest = hashCancellation(id, authorizer, cancelNonce, signatureDeadline);
        if (!_isValidSignatureNow(authorizer, digest, signature)) revert InvalidSignature();
        cancellationNonceUsed[authorizer][cancelNonce] = true;
        _cancel(id, mandate.payer, authorizer);
    }

    // Typed-data and signature helpers

    function _verifyMandateAuthorization(
        Mandate calldata mandate,
        uint256 signatureDeadline,
        bytes calldata payerSignature
    ) internal view {
        if (block.timestamp > signatureDeadline) revert SignatureExpired();
        if (!_isValidSignatureNow(mandate.payer, hashMandateAuthorization(mandate, signatureDeadline), payerSignature))
        {
            revert InvalidSignature();
        }
    }

    function _verifyMandateAcceptance(
        Mandate calldata mandate,
        uint256 signatureDeadline,
        bytes calldata billerSignature
    ) internal view {
        if (block.timestamp > signatureDeadline) revert SignatureExpired();
        if (!_isValidSignatureNow(mandate.biller, hashMandateAcceptance(mandate, signatureDeadline), billerSignature)) {
            revert InvalidSignature();
        }
    }

    /// @inheritdoc IFixedMandate
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @inheritdoc IFixedMandate
    function mandateId(Mandate calldata mandate) public view returns (bytes32 id) {
        Mandate memory mandateMem = mandate;
        return _hashTypedDataV4(_hashMandate(mandateMem));
    }

    /// @inheritdoc IFixedMandate
    function hashMandateAuthorization(Mandate memory mandate, uint256 signatureDeadline)
        public
        view
        returns (bytes32 digest)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(_MANDATE_AUTHORIZATION_TYPEHASH, _hashMandate(mandate), signatureDeadline))
        );
    }

    /// @inheritdoc IFixedMandate
    function hashMandateAcceptance(Mandate memory mandate, uint256 signatureDeadline)
        public
        view
        returns (bytes32 digest)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(_MANDATE_ACCEPTANCE_TYPEHASH, _hashMandate(mandate), signatureDeadline))
        );
    }

    /// @inheritdoc IFixedMandate
    function hashCancellation(bytes32 id, address authorizer, uint256 nonce, uint256 signatureDeadline)
        public
        view
        returns (bytes32 digest)
    {
        return _hashTypedDataV4(keccak256(abi.encode(_CANCELLATION_TYPEHASH, id, authorizer, nonce, signatureDeadline)));
    }

    function _hashMandate(Mandate memory mandate) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _MANDATE_TYPEHASH,
                mandate.payer,
                mandate.biller,
                mandate.recipient,
                mandate.token,
                mandate.payerGrossPerPayment,
                mandate.periodLength,
                mandate.totalPayments,
                mandate.termsHash,
                mandate.nonce
            )
        );
    }
}
