// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedMandate} from "../src/FixedMandate.sol";
import {IFixedMandate} from "../src/interfaces/IFixedMandate.sol";
import {SafeFixture, Safe, Enum} from "./helpers/SafeFixture.sol";
import {MockERC20} from "./helpers/MandateMocks.sol";

abstract contract FixedMandateSafeCancellationTest is SafeFixture {
    function test_FutureMandatesCanBeCancelledBeforeFirstPaymentThroughEverySafeRoute() public {
        assertTrue(
            _execSafe(
                payerSafe,
                address(token),
                abi.encodeCall(MockERC20.approve, (address(executor), 12 * AMOUNT)),
                Enum.Operation.Call
            )
        );
        for (uint256 route; route < 4; ++route) {
            IFixedMandate.Mandate memory mandate = _mandate(route + 1);
            mandate.firstPaymentAt = START + PERIOD;
            _open(mandate);
            assertEq(executor.unlockedPaymentCount(mandate), 0);

            if (route < 2) {
                Safe authorizer = route == 0 ? payerSafe : billerSafe;
                bytes memory data = route == 0
                    ? abi.encodeCall(FixedMandate.cancelMandateAsPayer, (mandate))
                    : abi.encodeCall(FixedMandate.cancelMandateAsBiller, (mandate));
                assertTrue(_execSafe(authorizer, address(executor), data, Enum.Operation.Call));
            } else {
                Safe authorizer = route == 2 ? payerSafe : billerSafe;
                bytes memory signature = _cancellationSignature(mandate, authorizer, 35);
                vm.prank(relayer);
                if (route == 2) {
                    executor.cancelMandateWithPayerSignature(mandate, 35, DEADLINE, signature);
                } else {
                    executor.cancelMandateWithBillerSignature(mandate, 35, DEADLINE, signature);
                }
                _assertNonceUsedBySafeOnly(authorizer, 35);
            }
            _assertState(mandate, true, true, 0);
        }

        vm.warp(START + PERIOD);
        for (uint256 route; route < 4; ++route) {
            IFixedMandate.Mandate memory mandate = _mandate(route + 1);
            mandate.firstPaymentAt = START + PERIOD;
            vm.expectRevert(IFixedMandate.MandateCancelled.selector);
            executor.settle(mandate, 0);
            _assertState(mandate, true, true, 0);
        }
        assertEq(token.balanceOf(address(payerSafe)), 100_000e6);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.allowance(address(payerSafe), address(executor)), 12 * AMOUNT);
        assertEq(payerSafe.nonce(), 2, "token approval and direct payer cancellation");
        assertEq(billerSafe.nonce(), 1, "direct biller cancellation");
    }

    function test_SafePayerCancelsThroughThresholdApprovedTransaction() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        bytes32 id = _open(mandate);
        _execSafe(
            payerSafe,
            address(token),
            abi.encodeCall(MockERC20.approve, (address(executor), 12 * AMOUNT)),
            Enum.Operation.Call
        );
        vm.prank(relayer);
        executor.settle(mandate, 0);
        uint256 safeNonce = payerSafe.nonce();
        bytes memory callData = abi.encodeCall(FixedMandate.cancelMandateAsPayer, (mandate));

        vm.expectEmit(true, true, true, true, address(executor));
        emit IFixedMandate.MandateCancellation(id, address(payerSafe), address(payerSafe));
        assertTrue(_execSafe(payerSafe, address(executor), callData, Enum.Operation.Call));

        _assertState(mandate, true, true, 1);
        assertEq(payerSafe.nonce(), safeNonce + 1, "Safe transaction nonce");
        assertFalse(executor.cancellationNonceUsed(address(payerSafe), 0), "no signed cancellation nonce");
        assertEq(token.allowance(address(payerSafe), address(executor)), 11 * AMOUNT, "allowance retained");
        assertEq(token.balanceOf(recipient), AMOUNT, "settled payment retained");
        vm.warp(START + PERIOD);
        vm.expectRevert(IFixedMandate.MandateCancelled.selector);
        executor.settle(mandate, 1);
    }

    function test_SafeBillerCancelsThroughThresholdApprovedTransaction() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        bytes32 id = _open(mandate);
        uint256 safeNonce = billerSafe.nonce();
        bytes memory callData = abi.encodeCall(FixedMandate.cancelMandateAsBiller, (mandate));

        vm.expectEmit(true, true, true, true, address(executor));
        emit IFixedMandate.MandateCancellation(id, address(payerSafe), address(billerSafe));
        assertTrue(_execSafe(billerSafe, address(executor), callData, Enum.Operation.Call));

        _assertState(mandate, true, true, 0);
        assertEq(billerSafe.nonce(), safeNonce + 1, "Safe transaction nonce");
        assertFalse(executor.cancellationNonceUsed(address(billerSafe), 0), "no signed cancellation nonce");
        vm.expectRevert(IFixedMandate.MandateCancelled.selector);
        executor.settle(mandate, 0);
    }

    function test_RelayerCancelsWithSafePayerThresholdSignatureAndCannotReplay() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        bytes32 id = _open(mandate);
        uint256 cancelNonce = 27;
        bytes memory signature = _cancellationSignature(mandate, payerSafe, cancelNonce);
        uint256 safeNonce = payerSafe.nonce();

        vm.expectEmit(true, true, false, true, address(executor));
        emit IFixedMandate.CancellationNonceConsumed(address(payerSafe), cancelNonce);
        vm.expectEmit(true, true, true, true, address(executor));
        emit IFixedMandate.MandateCancellation(id, address(payerSafe), address(payerSafe));
        vm.prank(relayer);
        executor.cancelMandateWithPayerSignature(mandate, cancelNonce, DEADLINE, signature);

        _assertState(mandate, true, true, 0);
        _assertNonceUsedBySafeOnly(payerSafe, cancelNonce);
        assertFalse(executor.cancellationNonceUsed(address(billerSafe), cancelNonce), "biller nonce untouched");
        assertEq(payerSafe.nonce(), safeNonce, "message validation does not execute a Safe transaction");
        vm.expectRevert(IFixedMandate.InvalidCancellationNonce.selector);
        vm.prank(relayer);
        executor.cancelMandateWithPayerSignature(mandate, cancelNonce, DEADLINE, signature);
    }

    function test_RelayerCancelsWithSafeBillerThresholdSignatureAndCannotReplay() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        bytes32 id = _open(mandate);
        uint256 cancelNonce = 27;
        bytes memory signature = _cancellationSignature(mandate, billerSafe, cancelNonce);
        uint256 safeNonce = billerSafe.nonce();

        vm.expectEmit(true, true, false, true, address(executor));
        emit IFixedMandate.CancellationNonceConsumed(address(billerSafe), cancelNonce);
        vm.expectEmit(true, true, true, true, address(executor));
        emit IFixedMandate.MandateCancellation(id, address(payerSafe), address(billerSafe));
        vm.prank(relayer);
        executor.cancelMandateWithBillerSignature(mandate, cancelNonce, DEADLINE, signature);

        _assertState(mandate, true, true, 0);
        _assertNonceUsedBySafeOnly(billerSafe, cancelNonce);
        assertFalse(executor.cancellationNonceUsed(address(payerSafe), cancelNonce), "payer nonce untouched");
        assertEq(billerSafe.nonce(), safeNonce, "message validation does not execute a Safe transaction");
        vm.expectRevert(IFixedMandate.InvalidCancellationNonce.selector);
        vm.prank(relayer);
        executor.cancelMandateWithBillerSignature(mandate, cancelNonce, DEADLINE, signature);
    }

    function test_InsufficientPayerThresholdLeavesCancellationRetryable() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        bytes32 id = _open(mandate);
        uint256 cancelNonce = 28;
        bytes32 digest = executor.hashCancellation(id, address(payerSafe), cancelNonce, DEADLINE);
        bytes memory oneSignature = _sign(ownerKeys[0], _safeMessageHash(payerSafe, digest));
        bytes memory thresholdSignature = _safeSign(payerSafe, digest);

        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        vm.prank(relayer);
        executor.cancelMandateWithPayerSignature(mandate, cancelNonce, DEADLINE, oneSignature);

        _assertState(mandate, true, false, 0);
        assertFalse(executor.cancellationNonceUsed(address(payerSafe), cancelNonce));
        vm.prank(relayer);
        executor.cancelMandateWithPayerSignature(mandate, cancelNonce, DEADLINE, thresholdSignature);
        _assertState(mandate, true, true, 0);
        _assertNonceUsedBySafeOnly(payerSafe, cancelNonce);
    }

    function test_InsufficientBillerThresholdLeavesCancellationRetryable() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        bytes32 id = _open(mandate);
        uint256 cancelNonce = 28;
        bytes32 digest = executor.hashCancellation(id, address(billerSafe), cancelNonce, DEADLINE);
        bytes memory oneSignature = _sign(ownerKeys[0], _safeMessageHash(billerSafe, digest));
        bytes memory thresholdSignature = _safeSign(billerSafe, digest);

        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        vm.prank(relayer);
        executor.cancelMandateWithBillerSignature(mandate, cancelNonce, DEADLINE, oneSignature);

        _assertState(mandate, true, false, 0);
        assertFalse(executor.cancellationNonceUsed(address(billerSafe), cancelNonce));
        vm.prank(relayer);
        executor.cancelMandateWithBillerSignature(mandate, cancelNonce, DEADLINE, thresholdSignature);
        _assertState(mandate, true, true, 0);
        _assertNonceUsedBySafeOnly(billerSafe, cancelNonce);
    }

    function test_PayerSignatureCannotCancelAsBillerEvenWithIdenticalSafeOwners() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        _open(mandate);
        uint256 cancelNonce = 29;
        bytes memory signature = _cancellationSignature(mandate, payerSafe, cancelNonce);

        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        vm.prank(relayer);
        executor.cancelMandateWithBillerSignature(mandate, cancelNonce, DEADLINE, signature);

        _assertState(mandate, true, false, 0);
        assertFalse(executor.cancellationNonceUsed(address(payerSafe), cancelNonce));
        assertFalse(executor.cancellationNonceUsed(address(billerSafe), cancelNonce));
        vm.prank(relayer);
        executor.cancelMandateWithPayerSignature(mandate, cancelNonce, DEADLINE, signature);
        _assertState(mandate, true, true, 0);
    }

    function test_BillerSignatureCannotCancelAsPayerEvenWithIdenticalSafeOwners() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        _open(mandate);
        uint256 cancelNonce = 29;
        bytes memory signature = _cancellationSignature(mandate, billerSafe, cancelNonce);

        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        vm.prank(relayer);
        executor.cancelMandateWithPayerSignature(mandate, cancelNonce, DEADLINE, signature);

        _assertState(mandate, true, false, 0);
        assertFalse(executor.cancellationNonceUsed(address(payerSafe), cancelNonce));
        assertFalse(executor.cancellationNonceUsed(address(billerSafe), cancelNonce));
        vm.prank(relayer);
        executor.cancelMandateWithBillerSignature(mandate, cancelNonce, DEADLINE, signature);
        _assertState(mandate, true, true, 0);
    }

    function test_IndividualSafeOwnersCannotDirectlyCancelEitherRole() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        _open(mandate);

        for (uint256 i; i < ownerKeys.length; ++i) {
            address owner = vm.addr(ownerKeys[i]);
            vm.expectRevert(IFixedMandate.InvalidCaller.selector);
            vm.prank(owner);
            executor.cancelMandateAsPayer(mandate);
            vm.expectRevert(IFixedMandate.InvalidCaller.selector);
            vm.prank(owner);
            executor.cancelMandateAsBiller(mandate);
        }

        _assertState(mandate, true, false, 0);
    }

    function test_ThresholdIncreaseInvalidatesOutstandingCancellationUntilThirdOwnerSigns() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        bytes32 id = _open(mandate);
        uint256 cancelNonce = 30;
        bytes32 digest = executor.hashCancellation(id, address(payerSafe), cancelNonce, DEADLINE);
        bytes memory oldSignature = _safeSign(payerSafe, digest);
        bytes32 safeDigest = _safeMessageHash(payerSafe, digest);
        bytes memory newSignature = bytes.concat(
            _sign(ownerKeys[0], safeDigest), _sign(ownerKeys[1], safeDigest), _sign(ownerKeys[2], safeDigest)
        );
        _execSafe(payerSafe, address(payerSafe), abi.encodeCall(Safe.changeThreshold, (3)), Enum.Operation.Call);
        assertEq(payerSafe.getThreshold(), 3);

        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        vm.prank(relayer);
        executor.cancelMandateWithPayerSignature(mandate, cancelNonce, DEADLINE, oldSignature);

        _assertState(mandate, true, false, 0);
        assertFalse(executor.cancellationNonceUsed(address(payerSafe), cancelNonce));
        vm.prank(relayer);
        executor.cancelMandateWithPayerSignature(mandate, cancelNonce, DEADLINE, newSignature);
        _assertState(mandate, true, true, 0);
        _assertNonceUsedBySafeOnly(payerSafe, cancelNonce);
    }

    function test_ExpiredSafeSignaturesCannotCancelOrConsumeEitherRoleNonce() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        _open(mandate);
        uint256 cancelNonce = 31;
        bytes memory payerSignature = _cancellationSignature(mandate, payerSafe, cancelNonce);
        bytes memory billerSignature = _cancellationSignature(mandate, billerSafe, cancelNonce);
        vm.warp(DEADLINE + 1);

        vm.expectRevert(IFixedMandate.SignatureExpired.selector);
        vm.prank(relayer);
        executor.cancelMandateWithPayerSignature(mandate, cancelNonce, DEADLINE, payerSignature);
        vm.expectRevert(IFixedMandate.SignatureExpired.selector);
        vm.prank(relayer);
        executor.cancelMandateWithBillerSignature(mandate, cancelNonce, DEADLINE, billerSignature);

        _assertState(mandate, true, false, 0);
        assertFalse(executor.cancellationNonceUsed(address(payerSafe), cancelNonce));
        assertFalse(executor.cancellationNonceUsed(address(billerSafe), cancelNonce));
    }

    function test_UnopenedMandateRollsBackValidSafeCancellationNonceAndAllowsRetry() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        uint256 cancelNonce = 32;
        bytes memory payerSignature = _cancellationSignature(mandate, payerSafe, cancelNonce);
        bytes memory billerSignature = _cancellationSignature(mandate, billerSafe, cancelNonce);

        vm.expectRevert(IFixedMandate.MandateNotOpen.selector);
        vm.prank(relayer);
        executor.cancelMandateWithPayerSignature(mandate, cancelNonce, DEADLINE, payerSignature);
        vm.expectRevert(IFixedMandate.MandateNotOpen.selector);
        vm.prank(relayer);
        executor.cancelMandateWithBillerSignature(mandate, cancelNonce, DEADLINE, billerSignature);

        _assertState(mandate, false, false, 0);
        assertFalse(executor.cancellationNonceUsed(address(payerSafe), cancelNonce));
        assertFalse(executor.cancellationNonceUsed(address(billerSafe), cancelNonce));
        _open(mandate);
        vm.prank(relayer);
        executor.cancelMandateWithPayerSignature(mandate, cancelNonce, DEADLINE, payerSignature);
        _assertState(mandate, true, true, 0);
        _assertNonceUsedBySafeOnly(payerSafe, cancelNonce);
    }

    function test_SafesWithSharedOwnersHaveIndependentCancellationNonceNamespaces() public {
        IFixedMandate.Mandate memory first = _mandate(1);
        IFixedMandate.Mandate memory second = _mandate(2);
        _open(first);
        _open(second);
        uint256 cancelNonce = 33;
        bytes memory payerSignature = _cancellationSignature(first, payerSafe, cancelNonce);
        bytes memory billerSignature = _cancellationSignature(second, billerSafe, cancelNonce);

        vm.prank(relayer);
        executor.cancelMandateWithPayerSignature(first, cancelNonce, DEADLINE, payerSignature);
        assertFalse(executor.cancellationNonceUsed(address(billerSafe), cancelNonce));
        vm.prank(relayer);
        executor.cancelMandateWithBillerSignature(second, cancelNonce, DEADLINE, billerSignature);

        _assertState(first, true, true, 0);
        _assertState(second, true, true, 0);
        _assertNonceUsedBySafeOnly(payerSafe, cancelNonce);
        _assertNonceUsedBySafeOnly(billerSafe, cancelNonce);
    }

    function test_RawMandateDigestSignaturesCannotBypassSafeMessageEncoding() public {
        IFixedMandate.Mandate memory mandate = _mandate(1);
        bytes32 id = _open(mandate);
        uint256 cancelNonce = 34;
        bytes32 payerDigest = executor.hashCancellation(id, address(payerSafe), cancelNonce, DEADLINE);
        bytes32 billerDigest = executor.hashCancellation(id, address(billerSafe), cancelNonce, DEADLINE);
        bytes memory payerSignature = bytes.concat(_sign(ownerKeys[0], payerDigest), _sign(ownerKeys[1], payerDigest));
        bytes memory billerSignature =
            bytes.concat(_sign(ownerKeys[0], billerDigest), _sign(ownerKeys[1], billerDigest));

        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        vm.prank(relayer);
        executor.cancelMandateWithPayerSignature(mandate, cancelNonce, DEADLINE, payerSignature);
        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        vm.prank(relayer);
        executor.cancelMandateWithBillerSignature(mandate, cancelNonce, DEADLINE, billerSignature);

        _assertState(mandate, true, false, 0);
        assertFalse(executor.cancellationNonceUsed(address(payerSafe), cancelNonce));
        assertFalse(executor.cancellationNonceUsed(address(billerSafe), cancelNonce));
    }

    function _cancellationSignature(IFixedMandate.Mandate memory mandate, Safe authorizer, uint256 cancelNonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest =
            executor.hashCancellation(executor.mandateId(mandate), address(authorizer), cancelNonce, DEADLINE);
        return _safeSign(authorizer, digest);
    }

    function _assertNonceUsedBySafeOnly(Safe wallet, uint256 cancelNonce) internal view {
        assertTrue(executor.cancellationNonceUsed(address(wallet), cancelNonce), "Safe nonce consumed");
        for (uint256 i; i < ownerKeys.length; ++i) {
            assertFalse(executor.cancellationNonceUsed(vm.addr(ownerKeys[i]), cancelNonce), "owner nonce untouched");
        }
        assertFalse(executor.cancellationNonceUsed(relayer, cancelNonce), "relayer nonce untouched");
    }
}

contract FixedMandateSafe130CancellationTest is FixedMandateSafeCancellationTest {
    function _safeVersion() internal pure override returns (string memory) {
        return "1.3.0";
    }
}

contract FixedMandateSafe141CancellationTest is FixedMandateSafeCancellationTest {
    function _safeVersion() internal pure override returns (string memory) {
        return "1.4.1";
    }
}
