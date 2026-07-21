// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {FixedMandate} from "../src/FixedMandate.sol";
import {IFixedMandate} from "../src/interfaces/IFixedMandate.sol";
import {MockERC20} from "./helpers/MandateMocks.sol";

contract FixedMandateHandler is Test {
    FixedMandate public immutable executor;
    MockERC20 public immutable token;

    IFixedMandate.Mandate internal mandate;
    uint256 public immutable initialPayerBalance;
    uint256 public ghostSuccessfulSettlements;
    uint256 public ghostCancelledAtCount = type(uint256).max;
    uint256 public ghostUnexpectedSuccesses;

    constructor(FixedMandate executor_, MockERC20 token_, IFixedMandate.Mandate memory mandate_) {
        executor = executor_;
        token = token_;
        mandate = mandate_;
        initialPayerBalance = token_.balanceOf(mandate_.payer);
    }

    function warpForward(uint32 rawDelta) external {
        uint256 delta = bound(uint256(rawDelta), 0, 180 days);
        vm.warp(block.timestamp + delta);
    }

    function settleCurrent() external {
        _settleCurrent();
    }

    function settleAvailable(uint8 rawAttempts) external {
        uint256 attempts = bound(uint256(rawAttempts), 1, 16);
        for (uint256 i; i < attempts; ++i) {
            if (!_settleCurrent()) break;
        }
    }

    function _settleCurrent() internal returns (bool settled) {
        bytes32 id = executor.mandateId(mandate);
        (,,, uint256 beforeCount) = executor.mandateStates(id);
        try executor.settle(mandate, beforeCount) {
            ghostSuccessfulSettlements += 1;
            (,,, uint256 afterCount) = executor.mandateStates(id);
            require(afterCount == beforeCount + 1, "SUCCESS_NOT_EXACTLY_ONE");
            return true;
        } catch {
            (,,, uint256 afterCount) = executor.mandateStates(id);
            require(afterCount == beforeCount, "FAILED_SETTLEMENT_MUTATED_COUNT");
            return false;
        }
    }

    function settleStale() external {
        bytes32 id = executor.mandateId(mandate);
        (,,, uint256 beforeCount) = executor.mandateStates(id);
        uint256 staleIndex = beforeCount == 0 ? 1 : beforeCount - 1;
        try executor.settle(mandate, staleIndex) {
            ghostUnexpectedSuccesses += 1;
        } catch {
            (,,, uint256 afterCount) = executor.mandateStates(id);
            require(afterCount == beforeCount, "STALE_SETTLEMENT_MUTATED_COUNT");
        }
    }

    function settleFuture(uint8 rawAhead) external {
        bytes32 id = executor.mandateId(mandate);
        (,,, uint256 beforeCount) = executor.mandateStates(id);
        uint256 ahead = bound(uint256(rawAhead), 1, 32);
        try executor.settle(mandate, beforeCount + ahead) {
            ghostUnexpectedSuccesses += 1;
        } catch {
            (,,, uint256 afterCount) = executor.mandateStates(id);
            require(afterCount == beforeCount, "FUTURE_SETTLEMENT_MUTATED_COUNT");
        }
    }

    function settleWithoutAllowance() external {
        bytes32 id = executor.mandateId(mandate);
        (,,, uint256 beforeCount) = executor.mandateStates(id);
        uint256 payerBalanceBefore = token.balanceOf(mandate.payer);
        vm.prank(mandate.payer);
        token.approve(address(executor), 0);

        try executor.settle(mandate, beforeCount) {
            ghostUnexpectedSuccesses += 1;
        } catch {
            (,,, uint256 afterCount) = executor.mandateStates(id);
            require(afterCount == beforeCount, "FAILED_TRANSFER_MUTATED_COUNT");
            require(token.balanceOf(mandate.payer) == payerBalanceBefore, "FAILED_TRANSFER_DEBITED_PAYER");
        }

        vm.prank(mandate.payer);
        token.approve(address(executor), type(uint256).max);
    }

    function cancelAsPayer() external {
        bytes32 id = executor.mandateId(mandate);
        (,,, uint256 beforeCount) = executor.mandateStates(id);
        if (beforeCount < 3) return;
        vm.prank(mandate.payer);
        try executor.cancelMandateAsPayer(mandate) {
            ghostCancelledAtCount = beforeCount;
        } catch {
            (,,, uint256 afterCount) = executor.mandateStates(id);
            require(afterCount == beforeCount, "FAILED_CANCELLATION_MUTATED_COUNT");
        }
    }

    function configuredMandate() external view returns (IFixedMandate.Mandate memory) {
        return mandate;
    }
}

abstract contract FixedMandateInvariantBase is StdInvariant, Test {
    FixedMandate internal executor;
    MockERC20 internal token;
    FixedMandateHandler internal handler;
    IFixedMandate.Mandate internal mandate;

    uint256 internal payerPk = 0xA11CE;
    uint256 internal billerPk = 0xB0B;
    address internal payer;
    address internal biller;
    address internal recipient = makeAddr("invariant-recipient");

    uint256 internal constant START = 1_700_000_000;
    uint256 internal constant PERIOD = 30 days;
    uint256 internal constant GROSS = 100e6;
    uint256 internal constant FEE = 5e6;
    uint256 internal constant INITIAL_BALANCE = 1_000_000e6;

    function _setUpInvariant(uint256 totalPayments, bool includeCancellation) internal {
        payer = vm.addr(payerPk);
        biller = vm.addr(billerPk);
        executor = new FixedMandate();
        token = new MockERC20();
        vm.warp(START);

        mandate = IFixedMandate.Mandate({
            payer: payer,
            biller: biller,
            recipient: recipient,
            settler: address(0),
            token: address(token),
            payerGrossPerPayment: GROSS,
            settlerFeePerPayment: FEE,
            periodLength: PERIOD,
            totalPayments: totalPayments,
            termsHash: keccak256("fixed invariant terms"),
            nonce: totalPayments
        });

        uint256 deadline = START + 1 hours;
        executor.openMandate(
            mandate,
            deadline,
            deadline,
            _sign(payerPk, executor.hashMandateAuthorization(mandate, deadline)),
            _sign(billerPk, executor.hashMandateAcceptance(mandate, deadline))
        );

        token.mint(payer, INITIAL_BALANCE);
        vm.prank(payer);
        token.approve(address(executor), type(uint256).max);

        handler = new FixedMandateHandler(executor, token, mandate);
        bytes4[] memory selectors = new bytes4[](includeCancellation ? 7 : 6);
        selectors[0] = FixedMandateHandler.warpForward.selector;
        selectors[1] = FixedMandateHandler.settleCurrent.selector;
        selectors[2] = FixedMandateHandler.settleAvailable.selector;
        selectors[3] = FixedMandateHandler.settleStale.selector;
        selectors[4] = FixedMandateHandler.settleFuture.selector;
        selectors[5] = FixedMandateHandler.settleWithoutAllowance.selector;
        if (includeCancellation) selectors[6] = FixedMandateHandler.cancelAsPayer.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_SettledCountMatchesSuccessfulCallsAndNeverExceedsUnlocks() public view {
        bytes32 id = executor.mandateId(mandate);
        (,, uint256 startedAt, uint256 settledCount) = executor.mandateStates(id);
        assertEq(settledCount, handler.ghostSuccessfulSettlements(), "ghost count");

        uint256 elapsedPeriods = (block.timestamp - startedAt) / mandate.periodLength;
        uint256 unlocked = elapsedPeriods + 1;
        if (mandate.totalPayments != 0 && unlocked > mandate.totalPayments) unlocked = mandate.totalPayments;
        assertLe(settledCount, unlocked, "unlocked bound");
        if (mandate.totalPayments != 0) assertLe(settledCount, mandate.totalPayments, "finite bound");
    }

    function invariant_StandardTokenGrossIsConserved() public view {
        uint256 settledCount = handler.ghostSuccessfulSettlements();
        uint256 payerDebit = handler.initialPayerBalance() - token.balanceOf(payer);
        assertEq(payerDebit, settledCount * GROSS, "payer debit");
        assertEq(token.balanceOf(recipient), settledCount * (GROSS - FEE), "recipient credits");
        assertEq(token.balanceOf(address(handler)), settledCount * FEE, "caller fees");
        assertEq(token.balanceOf(recipient) + token.balanceOf(address(handler)), payerDebit, "gross conservation");
    }

    function invariant_CancellationFreezesSettlementCount() public view {
        uint256 cancelledAt = handler.ghostCancelledAtCount();
        if (cancelledAt == type(uint256).max) return;
        (,,, uint256 settledCount) = executor.mandateStates(executor.mandateId(mandate));
        assertEq(settledCount, cancelledAt, "cancelled count changed");
    }

    function invariant_ExpectedFailureActionsNeverSucceed() public view {
        assertEq(handler.ghostUnexpectedSuccesses(), 0, "expected failure succeeded");
    }

    function _sign(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory signature) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}

contract FixedMandateFiniteInvariantTest is FixedMandateInvariantBase {
    function setUp() public {
        _setUpInvariant(12, false);
    }
}

contract FixedMandateIndefiniteInvariantTest is FixedMandateInvariantBase {
    function setUp() public {
        _setUpInvariant(0, false);
    }
}

contract FixedMandateCancellationInvariantTest is FixedMandateInvariantBase {
    function setUp() public {
        _setUpInvariant(0, true);
    }
}
