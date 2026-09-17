// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedMandate} from "../src/FixedMandate.sol";
import {IFixedMandate} from "../src/interfaces/IFixedMandate.sol";
import {IUnorderedNonces} from "../src/interfaces/IUnorderedNonces.sol";
import {SafeFixture, Safe, SafeHandler, Enum} from "./helpers/SafeFixture.sol";
import {MockERC20} from "./helpers/MandateMocks.sol";

interface Safe141Events {
    event ExecutionFailure(bytes32 indexed txHash, uint256 payment);
}

abstract contract FixedMandateSafeTest is SafeFixture {
    event ExecutionFailure(bytes32 txHash, uint256 payment);

    function test_IndependentSafeMessageEncodingMatchesBothWalletDomains() public view {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        bytes32 digest = executor.hashMandateAuthorization(mandate, DEADLINE);
        bytes32 payerMessage = _safeMessageHash(payerSafe, digest);
        bytes32 billerMessage = _safeMessageHash(billerSafe, digest);
        assertEq(payerMessage, SafeHandler(handler).getMessageHashForSafe(payerSafe, abi.encode(digest)));
        assertEq(billerMessage, SafeHandler(handler).getMessageHashForSafe(billerSafe, abi.encode(digest)));
        assertNotEq(payerMessage, billerMessage, "same owners do not share a signing domain");
        assertNotEq(payerMessage, digest, "owners sign the Safe message, not the raw Mandate digest");
    }

    function test_RelayedOpeningUsesThresholdSignaturesAndOnlyMandateNonce() public {
        IFixedMandate.Mandate memory mandate = _mandate(257);
        bytes32 id = executor.mandateId(mandate);
        vm.expectEmit(true, true, true, true, address(executor));
        emit IFixedMandate.MandateOpened(
            id,
            address(payerSafe),
            address(billerSafe),
            address(token),
            recipient,
            AMOUNT,
            PERIOD,
            12,
            START,
            257,
            mandate.termsHash
        );
        assertEq(_open(mandate), id);

        _assertState(mandate, true, false, 0);
        assertEq(executor.nonceBitmap(address(payerSafe), 1), 2, "Safe owns the mandate nonce");
        assertEq(executor.nonceBitmap(address(billerSafe), 1), 0);
        assertEq(executor.nonceBitmap(relayer, 1), 0);
        for (uint256 i; i < ownerKeys.length; ++i) {
            assertEq(executor.nonceBitmap(vm.addr(ownerKeys[i]), 1), 0);
        }
        assertEq(payerSafe.nonce(), 0, "ERC-1271 does not execute a Safe transaction");
        assertEq(billerSafe.nonce(), 0);
        assertEq(token.allowance(address(payerSafe), address(executor)), 0, "opening does not approve tokens");

        bytes memory payerSignature = _safeSign(payerSafe, executor.hashMandateAuthorization(mandate, DEADLINE));
        bytes memory billerSignature = _safeSign(billerSafe, executor.hashMandateAcceptance(mandate, DEADLINE));
        vm.expectRevert(IFixedMandate.MandateAlreadyOpened.selector);
        executor.openMandate(mandate, DEADLINE, DEADLINE, payerSignature, billerSignature);
    }

    function test_SafePayerBatchesApprovalAndOpeningThenKeeperPullsWithoutMoreSignatures() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        assertTrue(_execBatch(payerSafe, _approvalAndOpening(mandate)));
        _assertState(mandate, true, false, 0);
        assertEq(payerSafe.nonce(), 1);
        assertEq(token.allowance(address(payerSafe), address(executor)), 12 * AMOUNT);
        assertEq(executor.nonceBitmap(address(payerSafe), 0), 2);

        vm.expectEmit(true, true, true, true, address(executor));
        emit IFixedMandate.PaymentSettled(
            executor.mandateId(mandate),
            0,
            address(payerSafe),
            address(billerSafe),
            recipient,
            address(token),
            AMOUNT,
            relayer
        );
        vm.prank(relayer);
        executor.settle(mandate, 0);
        vm.expectRevert(IFixedMandate.PaymentNotUnlocked.selector);
        executor.settle(mandate, 1);

        vm.warp(START + 2 * PERIOD);
        vm.startPrank(relayer);
        executor.settle(mandate, 1);
        executor.settle(mandate, 2);
        vm.stopPrank();

        _assertState(mandate, true, false, 3);
        assertEq(payerSafe.nonce(), 1, "recurring pulls need no further Safe transaction");
        assertEq(billerSafe.nonce(), 0);
        assertEq(token.balanceOf(address(payerSafe)), 100_000e6 - 3 * AMOUNT);
        assertEq(token.balanceOf(recipient), 3 * AMOUNT);
        assertEq(token.allowance(address(payerSafe), address(executor)), 9 * AMOUNT);
        assertEq(token.balanceOf(relayer), 0, "keeper cannot redirect funds");
    }

    function test_SafeBillerOpensDirectlyUsingPayerThresholdSignature() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        bytes memory signature = _safeSign(payerSafe, executor.hashMandateAuthorization(mandate, DEADLINE));
        assertTrue(
            _execSafe(
                billerSafe,
                address(executor),
                abi.encodeCall(FixedMandate.openMandateAsBiller, (mandate, DEADLINE, signature)),
                Enum.Operation.Call
            )
        );
        _assertState(mandate, true, false, 0);
        assertEq(billerSafe.nonce(), 1);
        assertEq(payerSafe.nonce(), 0);
    }

    function test_IndividualSafeOwnersCannotUseEitherDirectOpeningRoute() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        bytes memory payerSignature = _safeSign(payerSafe, executor.hashMandateAuthorization(mandate, DEADLINE));
        bytes memory billerSignature = _safeSign(billerSafe, executor.hashMandateAcceptance(mandate, DEADLINE));
        for (uint256 i; i < ownerKeys.length; ++i) {
            address owner = vm.addr(ownerKeys[i]);
            vm.expectRevert(IFixedMandate.InvalidCaller.selector);
            vm.prank(owner);
            executor.openMandateAsPayer(mandate, DEADLINE, billerSignature);
            vm.expectRevert(IFixedMandate.InvalidCaller.selector);
            vm.prank(owner);
            executor.openMandateAsBiller(mandate, DEADLINE, payerSignature);
        }
        _assertState(mandate, false, false, 0);
    }

    function test_OpeningRejectsSingleOwnerSignatureForEitherSafe() public {
        _assertInvalidOpeningSignatures(0);
    }

    function test_OpeningRejectsDuplicateOwnerSignaturesForEitherSafe() public {
        _assertInvalidOpeningSignatures(1);
    }

    function test_OpeningRejectsUnsortedOwnerSignaturesForEitherSafe() public {
        _assertInvalidOpeningSignatures(2);
    }

    function test_OpeningRejectsNonOwnerSignaturesForEitherSafe() public {
        _assertInvalidOpeningSignatures(3);
    }

    function test_OpeningRejectsRawMandateDigestSignaturesForEitherSafe() public {
        _assertInvalidOpeningSignatures(4);
    }

    function test_OpeningRejectsAnotherSafeDomainEvenWithIdenticalOwners() public {
        _assertInvalidOpeningSignatures(5);
    }

    function test_OpeningRejectsAnotherExecutorDomain() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        FixedMandate otherExecutor = new FixedMandate();
        bytes memory payerSignature = _safeSign(payerSafe, otherExecutor.hashMandateAuthorization(mandate, DEADLINE));
        bytes memory billerSignature = _safeSign(billerSafe, otherExecutor.hashMandateAcceptance(mandate, DEADLINE));
        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandate(mandate, DEADLINE, DEADLINE, payerSignature, billerSignature);
        _assertState(mandate, false, false, 0);
        _open(mandate);
        _assertState(mandate, true, false, 0);
    }

    function test_OpeningRejectsSignaturesFromAnotherChain() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        bytes memory payerSignature = _safeSign(payerSafe, executor.hashMandateAuthorization(mandate, DEADLINE));
        bytes memory billerSignature = _safeSign(billerSafe, executor.hashMandateAcceptance(mandate, DEADLINE));
        vm.chainId(block.chainid + 1);
        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandate(mandate, DEADLINE, DEADLINE, payerSignature, billerSignature);
        _assertState(mandate, false, false, 0);
        _open(mandate);
        _assertState(mandate, true, false, 0);
    }

    function test_OwnerRotationInvalidatesOutstandingOpeningSignature() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        bytes32 digest = executor.hashMandateAuthorization(mandate, DEADLINE);
        bytes memory oldSignature = _safeSign(payerSafe, digest);
        bytes memory billerSignature = _safeSign(billerSafe, executor.hashMandateAcceptance(mandate, DEADLINE));
        uint256 newOwnerKey = 0xFEED;
        assertTrue(
            _execSafe(
                payerSafe,
                address(payerSafe),
                abi.encodeCall(Safe.swapOwner, (address(1), vm.addr(ownerKeys[0]), vm.addr(newOwnerKey))),
                Enum.Operation.Call
            )
        );

        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandate(mandate, DEADLINE, DEADLINE, oldSignature, billerSignature);
        _assertState(mandate, false, false, 0);
        assertEq(executor.nonceBitmap(address(payerSafe), 0), 0);

        bytes32 safeDigest = _safeMessageHash(payerSafe, digest);
        bytes memory newOwnerSignature = _sign(newOwnerKey, safeDigest);
        bytes memory remainingOwnerSignature = _sign(ownerKeys[1], safeDigest);
        bytes memory currentSignatures = vm.addr(newOwnerKey) < vm.addr(ownerKeys[1])
            ? bytes.concat(newOwnerSignature, remainingOwnerSignature)
            : bytes.concat(remainingOwnerSignature, newOwnerSignature);
        executor.openMandate(mandate, DEADLINE, DEADLINE, currentSignatures, billerSignature);
        _assertState(mandate, true, false, 0);
        assertEq(payerSafe.nonce(), 1, "only owner rotation executed a Safe transaction");
    }

    function test_MissingHandlerRejectsSignaturesUntilSafeInstallsIt() public {
        payerSafe = _deploySafe(address(0));
        IFixedMandate.Mandate memory mandate = _mandate(1);
        bytes memory payerSignature = _safeSign(payerSafe, executor.hashMandateAuthorization(mandate, DEADLINE));
        bytes memory billerSignature = _safeSign(billerSafe, executor.hashMandateAcceptance(mandate, DEADLINE));
        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandate(mandate, DEADLINE, DEADLINE, payerSignature, billerSignature);
        _assertState(mandate, false, false, 0);
        assertEq(executor.nonceBitmap(address(payerSafe), 0), 0);

        assertTrue(
            _execSafe(
                payerSafe, address(payerSafe), abi.encodeCall(Safe.setFallbackHandler, (handler)), Enum.Operation.Call
            )
        );
        executor.openMandate(mandate, DEADLINE, DEADLINE, payerSignature, billerSignature);
        _assertState(mandate, true, false, 0);
        assertEq(payerSafe.nonce(), 1, "only handler installation needed a Safe transaction");
    }

    function test_DirectSafePayerNeedsNoHandlerWhenBillerIsEOA() public {
        payerSafe = _deploySafe(address(0));
        IFixedMandate.Mandate memory mandate = _mandate(1);
        mandate.biller = vm.addr(0xB111);
        bytes memory signature = _sign(0xB111, executor.hashMandateAcceptance(mandate, DEADLINE));
        assertTrue(
            _execSafe(
                payerSafe,
                address(executor),
                abi.encodeCall(FixedMandate.openMandateAsPayer, (mandate, DEADLINE, signature)),
                Enum.Operation.Call
            )
        );
        _assertState(mandate, true, false, 0);
        assertEq(payerSafe.nonce(), 1);
    }

    function test_EOAPayerCanOpenWithSafeBillerAcceptance() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        mandate.payer = vm.addr(0xA123);
        bytes memory signature = _safeSign(billerSafe, executor.hashMandateAcceptance(mandate, DEADLINE));
        vm.prank(mandate.payer);
        executor.openMandateAsPayer(mandate, DEADLINE, signature);
        _assertState(mandate, true, false, 0);
        assertEq(executor.nonceBitmap(mandate.payer, 0), 2);
        assertEq(billerSafe.nonce(), 0);
    }

    function test_EmptySignatureRequiresThresholdApprovedOnchainMessage() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        bytes32 digest = executor.hashMandateAuthorization(mandate, DEADLINE);
        bytes32 safeDigest = _safeMessageHash(payerSafe, digest);
        bytes memory billerSignature = _safeSign(billerSafe, executor.hashMandateAcceptance(mandate, DEADLINE));
        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandate(mandate, DEADLINE, DEADLINE, "", billerSignature);
        assertEq(payerSafe.signedMessages(safeDigest), 0);

        assertTrue(
            _execSafe(
                payerSafe,
                signMessageLib,
                abi.encodeWithSignature("signMessage(bytes)", abi.encode(digest)),
                Enum.Operation.DelegateCall
            )
        );
        assertEq(payerSafe.signedMessages(safeDigest), 1);
        vm.prank(relayer);
        executor.openMandate(mandate, DEADLINE, DEADLINE, "", billerSignature);
        _assertState(mandate, true, false, 0);
        assertEq(payerSafe.nonce(), 1);
    }

    function test_SelfBilledSafeApprovesMessageTokensAndOpensInOneTransaction() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        mandate.biller = address(payerSafe);
        bytes32 acceptance = executor.hashMandateAcceptance(mandate, DEADLINE);
        bytes memory opening = abi.encodeCall(FixedMandate.openMandateAsPayer, (mandate, DEADLINE, bytes("")));
        bytes memory batch = bytes.concat(
            _batchItem(
                signMessageLib,
                abi.encodeWithSignature("signMessage(bytes)", abi.encode(acceptance)),
                Enum.Operation.DelegateCall
            ),
            _batchItem(
                address(token), abi.encodeCall(MockERC20.approve, (address(executor), 12 * AMOUNT)), Enum.Operation.Call
            ),
            _batchItem(address(executor), opening, Enum.Operation.Call)
        );
        assertTrue(_execBatch(payerSafe, batch));
        _assertState(mandate, true, false, 0);
        assertEq(payerSafe.signedMessages(_safeMessageHash(payerSafe, acceptance)), 1);
        assertEq(payerSafe.nonce(), 1, "one threshold-approved transaction for all three actions");
        vm.prank(relayer);
        executor.settle(mandate, 0);
        assertEq(token.balanceOf(recipient), AMOUNT);
        assertEq(payerSafe.nonce(), 1);
    }

    function test_ExpiredAcceptanceRollsBackApprovalOpeningAndSafeNonce() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        bytes memory data = abi.encodeWithSignature("multiSend(bytes)", _approvalAndOpening(mandate));
        bytes memory signatures = _signOwners(_safeTxHash(payerSafe, multiSend, data, Enum.Operation.DelegateCall, 0));
        vm.warp(DEADLINE + 1);
        vm.expectRevert("GS013");
        payerSafe.execTransaction(
            multiSend, 0, data, Enum.Operation.DelegateCall, 0, 0, 0, address(0), payable(address(0)), signatures
        );
        _assertState(mandate, false, false, 0);
        assertEq(token.allowance(address(payerSafe), address(executor)), 0, "prior approval in batch rolled back");
        assertEq(executor.nonceBitmap(address(payerSafe), 0), 0);
        assertEq(payerSafe.nonce(), 0, "outer revert rolls back Safe nonce");
    }

    function test_SafeCanReportInnerFailureWithoutRevertingOuterTransaction() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        bytes memory data = abi.encodeWithSignature("multiSend(bytes)", _approvalAndOpening(mandate));
        bytes32 txHash = _safeTxHash(payerSafe, multiSend, data, Enum.Operation.DelegateCall, 1_000_000);
        vm.warp(DEADLINE + 1);
        // Safe 1.4.1 indexes txHash; Safe 1.3.0 puts it in the log data.
        if (keccak256(bytes(_safeVersion())) == keccak256("1.3.0")) {
            vm.expectEmit(false, false, false, true, address(payerSafe));
            emit ExecutionFailure(txHash, 0);
        } else {
            vm.expectEmit(true, false, false, true, address(payerSafe));
            emit Safe141Events.ExecutionFailure(txHash, 0);
        }
        bool success = _execSafeWithGas(payerSafe, multiSend, data, Enum.Operation.DelegateCall, 1_000_000);
        assertFalse(success, "successful outer call is not successful mandate opening");
        _assertState(mandate, false, false, 0);
        assertEq(token.allowance(address(payerSafe), address(executor)), 0);
        assertEq(executor.nonceBitmap(address(payerSafe), 0), 0);
        assertEq(payerSafe.nonce(), 1, "failed inner transaction consumes Safe nonce");
    }

    function test_MultiSendRejectsCallInsteadOfDelegateCall() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        bytes memory data = abi.encodeWithSignature("multiSend(bytes)", _approvalAndOpening(mandate));
        bytes memory signatures = _signOwners(_safeTxHash(payerSafe, multiSend, data, Enum.Operation.Call, 0));
        vm.expectRevert("GS013");
        payerSafe.execTransaction(
            multiSend, 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), signatures
        );
        _assertState(mandate, false, false, 0);
        assertEq(token.allowance(address(payerSafe), address(executor)), 0);
        assertEq(payerSafe.nonce(), 0);
    }

    function test_SafeTransactionCannotExecuteWithSingleOrDuplicateOwnerApproval() public {
        bytes memory data = abi.encodeCall(MockERC20.approve, (address(executor), AMOUNT));
        bytes32 digest = _safeTxHash(payerSafe, address(token), data, Enum.Operation.Call, 0);
        bytes memory single = _sign(ownerKeys[0], digest);
        bytes memory duplicate = bytes.concat(single, single);
        vm.expectRevert("GS020");
        payerSafe.execTransaction(
            address(token), 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), single
        );
        vm.expectRevert("GS026");
        payerSafe.execTransaction(
            address(token), 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), duplicate
        );
        assertEq(payerSafe.nonce(), 0);
        assertEq(token.allowance(address(payerSafe), address(executor)), 0);
        assertTrue(_execSafe(payerSafe, address(token), data, Enum.Operation.Call));
        assertEq(payerSafe.nonce(), 1);
        assertEq(token.allowance(address(payerSafe), address(executor)), AMOUNT);
    }

    function test_SafeCanInvalidatePendingMandateNonceWithoutOpeningIt() public {
        IFixedMandate.Mandate memory mandate = _mandate(257);
        bytes memory payerSignature = _safeSign(payerSafe, executor.hashMandateAuthorization(mandate, DEADLINE));
        bytes memory billerSignature = _safeSign(billerSafe, executor.hashMandateAcceptance(mandate, DEADLINE));
        assertTrue(
            _execSafe(
                payerSafe,
                address(executor),
                abi.encodeCall(IUnorderedNonces.invalidateUnorderedNonces, (uint248(1), uint256(2))),
                Enum.Operation.Call
            )
        );
        vm.expectRevert(IUnorderedNonces.InvalidUnorderedNonce.selector);
        executor.openMandate(mandate, DEADLINE, DEADLINE, payerSignature, billerSignature);
        _assertState(mandate, false, false, 0);
        assertEq(executor.nonceBitmap(address(payerSafe), 1), 2);
        assertEq(payerSafe.nonce(), 1);
    }

    function test_RevokingSafeAllowanceStopsAllMandatesWithoutAdvancingPaymentCounts() public {
        IFixedMandate.Mandate memory first = _mandate(1);
        IFixedMandate.Mandate memory second = _mandate(2);
        assertTrue(_execBatch(payerSafe, _approvalAndOpening(first)));
        _open(second);
        executor.settle(first, 0);
        assertTrue(
            _execSafe(
                payerSafe,
                address(token),
                abi.encodeCall(MockERC20.approve, (address(executor), 0)),
                Enum.Operation.Call
            )
        );
        vm.warp(START + PERIOD);
        vm.expectRevert("ALLOWANCE");
        executor.settle(first, 1);
        vm.expectRevert("ALLOWANCE");
        executor.settle(second, 0);
        _assertState(first, true, false, 1);
        _assertState(second, true, false, 0);
        assertEq(payerSafe.nonce(), 2);
        assertEq(token.balanceOf(recipient), AMOUNT);
        assertEq(token.allowance(address(payerSafe), address(executor)), 0);
    }

    function _approvalAndOpening(IFixedMandate.Mandate memory mandate) internal view returns (bytes memory) {
        bytes memory signature = _safeSign(billerSafe, executor.hashMandateAcceptance(mandate, DEADLINE));
        return bytes.concat(
            _batchItem(
                address(token), abi.encodeCall(MockERC20.approve, (address(executor), 12 * AMOUNT)), Enum.Operation.Call
            ),
            _batchItem(
                address(executor),
                abi.encodeCall(FixedMandate.openMandateAsPayer, (mandate, DEADLINE, signature)),
                Enum.Operation.Call
            )
        );
    }

    function _assertInvalidOpeningSignatures(uint256 kind) internal {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        bytes32 payerDigest = executor.hashMandateAuthorization(mandate, DEADLINE);
        bytes32 billerDigest = executor.hashMandateAcceptance(mandate, DEADLINE);
        bytes memory payerSignature = _safeSign(payerSafe, payerDigest);
        bytes memory billerSignature = _safeSign(billerSafe, billerDigest);
        bytes memory badPayer = _badSignature(payerSafe, billerSafe, payerDigest, kind);
        bytes memory badBiller = _badSignature(billerSafe, payerSafe, billerDigest, kind);
        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandate(mandate, DEADLINE, DEADLINE, badPayer, billerSignature);
        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandate(mandate, DEADLINE, DEADLINE, payerSignature, badBiller);
        _assertState(mandate, false, false, 0);
        assertEq(executor.nonceBitmap(address(payerSafe), 0), 0, "invalid signatures do not consume nonce");
        executor.openMandate(mandate, DEADLINE, DEADLINE, payerSignature, billerSignature);
        _assertState(mandate, true, false, 0);
    }

    function _badSignature(Safe wallet, Safe otherWallet, bytes32 digest, uint256 kind)
        internal
        view
        returns (bytes memory)
    {
        bytes32 safeDigest = _safeMessageHash(wallet, digest);
        bytes memory first = _sign(ownerKeys[0], safeDigest);
        if (kind == 0) return first;
        if (kind == 1) return bytes.concat(first, first);
        if (kind == 2) return bytes.concat(_sign(ownerKeys[1], safeDigest), first);
        if (kind == 3) {
            uint256 outsider = 0xBAD;
            bytes memory outsiderSignature = _sign(outsider, safeDigest);
            return vm.addr(outsider) < vm.addr(ownerKeys[0])
                ? bytes.concat(outsiderSignature, first)
                : bytes.concat(first, outsiderSignature);
        }
        if (kind == 4) return _signOwners(digest);
        return _safeSign(otherWallet, digest);
    }
}

contract FixedMandateSafe130Test is FixedMandateSafeTest {
    function _safeVersion() internal pure override returns (string memory) {
        return "1.3.0";
    }
}

contract FixedMandateSafe141Test is FixedMandateSafeTest {
    function _safeVersion() internal pure override returns (string memory) {
        return "1.4.1";
    }
}
