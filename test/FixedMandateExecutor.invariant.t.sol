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
    uint256 public ghostUnexpectedFailures;

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
        (bool opened, bool cancelled, uint256 startedAt, uint256 beforeCount) = executor.mandateStates(id);
        uint256 unlocked = (block.timestamp - startedAt) / mandate.periodLength + 1;
        if (mandate.totalPayments != 0 && unlocked > mandate.totalPayments) unlocked = mandate.totalPayments;
        bool shouldSucceed = opened && !cancelled && beforeCount < unlocked
            && token.allowance(mandate.payer, address(executor)) >= mandate.amountPerPayment
            && token.balanceOf(mandate.payer) >= mandate.amountPerPayment;

        try executor.settle(mandate, beforeCount) {
            if (!shouldSucceed) ghostUnexpectedSuccesses += 1;
            ghostSuccessfulSettlements += 1;
            (,,, uint256 afterCount) = executor.mandateStates(id);
            if (afterCount != beforeCount + 1) ghostUnexpectedSuccesses += 1;
            return true;
        } catch {
            if (shouldSucceed) ghostUnexpectedFailures += 1;
            (,,, uint256 afterCount) = executor.mandateStates(id);
            if (afterCount != beforeCount) ghostUnexpectedFailures += 1;
            return false;
        }
    }

    function settleStale() external {
        bytes32 id = executor.mandateId(mandate);
        (,,, uint256 beforeCount) = executor.mandateStates(id);
        if (beforeCount == 0) return;
        try executor.settle(mandate, beforeCount - 1) {
            ghostUnexpectedSuccesses += 1;
        } catch {
            (,,, uint256 afterCount) = executor.mandateStates(id);
            if (afterCount != beforeCount) ghostUnexpectedFailures += 1;
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
            if (afterCount != beforeCount) ghostUnexpectedFailures += 1;
        }
    }

    function settleWithoutAllowance() external {
        bytes32 id = executor.mandateId(mandate);
        (bool opened, bool cancelled, uint256 startedAt, uint256 beforeCount) = executor.mandateStates(id);
        uint256 unlocked = (block.timestamp - startedAt) / mandate.periodLength + 1;
        if (mandate.totalPayments != 0 && unlocked > mandate.totalPayments) unlocked = mandate.totalPayments;
        if (!opened || cancelled || beforeCount >= unlocked) return;

        uint256 payerBalanceBefore = token.balanceOf(mandate.payer);
        vm.prank(mandate.payer);
        token.approve(address(executor), 0);

        try executor.settle(mandate, beforeCount) {
            ghostUnexpectedSuccesses += 1;
        } catch {
            (,,, uint256 afterCount) = executor.mandateStates(id);
            if (afterCount != beforeCount || token.balanceOf(mandate.payer) != payerBalanceBefore) {
                ghostUnexpectedFailures += 1;
            }
        }

        vm.prank(mandate.payer);
        token.approve(address(executor), type(uint256).max);
    }

    function cancelAsPayer() external {
        bytes32 id = executor.mandateId(mandate);
        (, bool cancelledBefore,, uint256 beforeCount) = executor.mandateStates(id);
        vm.prank(mandate.payer);
        try executor.cancelMandateAsPayer(mandate) {
            if (cancelledBefore) ghostUnexpectedSuccesses += 1;
            ghostCancelledAtCount = beforeCount;
            (, bool cancelledAfter,, uint256 afterCount) = executor.mandateStates(id);
            if (!cancelledAfter || afterCount != beforeCount) ghostUnexpectedSuccesses += 1;
        } catch {
            if (!cancelledBefore) ghostUnexpectedFailures += 1;
            (,,, uint256 afterCount) = executor.mandateStates(id);
            if (afterCount != beforeCount) ghostUnexpectedFailures += 1;
        }
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
    uint256 internal constant AMOUNT = 100e6;
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
            token: address(token),
            amountPerPayment: AMOUNT,
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
        (bool opened, bool cancelled, uint256 startedAt, uint256 settledCount) = executor.mandateStates(id);
        assertTrue(opened, "opened flag cleared");
        assertEq(startedAt, START, "schedule anchor changed");
        assertEq(cancelled, handler.ghostCancelledAtCount() != type(uint256).max, "cancellation model");
        assertEq(settledCount, handler.ghostSuccessfulSettlements(), "ghost count");

        uint256 elapsedPeriods = (block.timestamp - startedAt) / mandate.periodLength;
        uint256 unlocked = elapsedPeriods + 1;
        if (mandate.totalPayments != 0 && unlocked > mandate.totalPayments) unlocked = mandate.totalPayments;
        assertLe(settledCount, unlocked, "unlocked bound");
    }

    function invariant_StandardTokenTransfersFullAmountAndPaysNoSubmitterReward() public view {
        uint256 settledCount = handler.ghostSuccessfulSettlements();
        uint256 payerDebit = handler.initialPayerBalance() - token.balanceOf(payer);
        assertEq(payerDebit, settledCount * AMOUNT, "payer debit");
        assertEq(token.balanceOf(recipient), settledCount * AMOUNT, "recipient credits");
        assertEq(token.balanceOf(address(handler)), 0, "handler protocol reward");
    }

    function invariant_ActionsMatchModelledOutcomes() public view {
        assertEq(handler.ghostUnexpectedSuccesses(), 0, "expected failure succeeded");
        assertEq(handler.ghostUnexpectedFailures(), 0, "expected success failed");
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

    function invariant_CancellationFreezesSettlementCount() public view {
        uint256 cancelledAt = handler.ghostCancelledAtCount();
        if (cancelledAt == type(uint256).max) return;
        (,,, uint256 settledCount) = executor.mandateStates(executor.mandateId(mandate));
        assertEq(settledCount, cancelledAt, "cancelled count changed");
    }
}

contract FixedMandateMultiHandler is Test {
    uint256 internal constant MANDATE_COUNT = 3;

    FixedMandate public immutable executor;
    MockERC20 public immutable token;
    IFixedMandate.Mandate[MANDATE_COUNT] internal mandates;
    uint256[MANDATE_COUNT] public ghostSettled;
    bool[MANDATE_COUNT] public ghostCancelled;
    uint256 public unexpectedOutcomes;

    constructor(FixedMandate executor_, MockERC20 token_, IFixedMandate.Mandate[MANDATE_COUNT] memory mandates_) {
        executor = executor_;
        token = token_;
        for (uint256 i; i < MANDATE_COUNT; ++i) {
            mandates[i] = mandates_[i];
        }
    }

    function warpForward(uint32 rawDelta) external {
        vm.warp(block.timestamp + bound(uint256(rawDelta), 0, 180 days));
    }

    function settle(uint8 rawMandateIndex) external {
        uint256 index = bound(uint256(rawMandateIndex), 0, MANDATE_COUNT - 1);
        IFixedMandate.Mandate memory mandate = mandates[index];
        bytes32 id = executor.mandateId(mandate);
        (bool opened, bool cancelled, uint256 startedAt, uint256 beforeCount) = executor.mandateStates(id);
        uint256 unlocked = (block.timestamp - startedAt) / mandate.periodLength + 1;
        if (mandate.totalPayments != 0 && unlocked > mandate.totalPayments) unlocked = mandate.totalPayments;
        bool shouldSucceed = opened && !cancelled && beforeCount < unlocked
            && token.balanceOf(mandate.payer) >= mandate.amountPerPayment;

        try executor.settle(mandate, beforeCount) {
            if (!shouldSucceed) unexpectedOutcomes += 1;
            ghostSettled[index] += 1;
            (,,, uint256 afterCount) = executor.mandateStates(id);
            if (afterCount != beforeCount + 1) unexpectedOutcomes += 1;
        } catch {
            if (shouldSucceed) unexpectedOutcomes += 1;
        }
    }

    function cancel(uint8 rawMandateIndex) external {
        uint256 index = bound(uint256(rawMandateIndex), 0, MANDATE_COUNT - 1);
        IFixedMandate.Mandate memory mandate = mandates[index];
        bytes32 id = executor.mandateId(mandate);
        (, bool cancelledBefore,, uint256 countBefore) = executor.mandateStates(id);

        vm.prank(mandate.payer);
        try executor.cancelMandateAsPayer(mandate) {
            if (cancelledBefore) unexpectedOutcomes += 1;
            ghostCancelled[index] = true;
            (, bool cancelledAfter,, uint256 countAfter) = executor.mandateStates(id);
            if (!cancelledAfter || countAfter != countBefore) unexpectedOutcomes += 1;
        } catch {
            if (!cancelledBefore) unexpectedOutcomes += 1;
        }
    }
}

contract FixedMandateMultiInvariantTest is StdInvariant, Test {
    uint256 internal constant MANDATE_COUNT = 3;
    uint256 internal constant START = 1_700_000_000;
    uint256 internal constant PERIOD = 30 days;
    uint256 internal constant AMOUNT = 100e6;
    uint256 internal constant INITIAL_BALANCE = 1_000_000e6;

    FixedMandate internal executor;
    MockERC20 internal token;
    FixedMandateMultiHandler internal handler;
    IFixedMandate.Mandate[MANDATE_COUNT] internal mandates;
    address internal payer;
    address internal biller;

    function setUp() public {
        uint256 payerPk = 0xA11CE;
        uint256 billerPk = 0xB0B;
        payer = vm.addr(payerPk);
        biller = vm.addr(billerPk);
        executor = new FixedMandate();
        token = new MockERC20();
        vm.warp(START);

        for (uint256 i; i < MANDATE_COUNT; ++i) {
            mandates[i] = IFixedMandate.Mandate({
                payer: payer,
                biller: biller,
                recipient: makeAddr(string.concat("multi-recipient-", vm.toString(i))),
                token: address(token),
                amountPerPayment: AMOUNT * (i + 1),
                periodLength: PERIOD * (i + 1),
                totalPayments: i == 1 ? 0 : 3 + i,
                termsHash: keccak256(abi.encode("multi invariant terms", i)),
                nonce: 100 + i
            });
            uint256 deadline = START + 1 hours;
            executor.openMandate(
                mandates[i],
                deadline,
                deadline,
                _sign(payerPk, executor.hashMandateAuthorization(mandates[i], deadline)),
                _sign(billerPk, executor.hashMandateAcceptance(mandates[i], deadline))
            );
        }

        token.mint(payer, INITIAL_BALANCE);
        vm.prank(payer);
        token.approve(address(executor), type(uint256).max);

        handler = new FixedMandateMultiHandler(executor, token, mandates);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = FixedMandateMultiHandler.warpForward.selector;
        selectors[1] = FixedMandateMultiHandler.settle.selector;
        selectors[2] = FixedMandateMultiHandler.cancel.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_IndependentMandatesMatchLifecycleAndAccountingModel() public view {
        uint256 expectedPayerDebit;
        for (uint256 i; i < MANDATE_COUNT; ++i) {
            IFixedMandate.Mandate memory mandate = mandates[i];
            (bool opened, bool cancelled, uint256 startedAt, uint256 settledCount) =
                executor.mandateStates(executor.mandateId(mandate));
            uint256 modelSettled = handler.ghostSettled(i);

            assertTrue(opened, "opened flag cleared");
            assertEq(cancelled, handler.ghostCancelled(i), "mandate cancellation leaked");
            assertEq(startedAt, START, "schedule anchor changed");
            assertEq(settledCount, modelSettled, "per-mandate settlement count");
            assertEq(token.balanceOf(mandate.recipient), modelSettled * mandate.amountPerPayment, "recipient credit");
            expectedPayerDebit += modelSettled * mandate.amountPerPayment;

            uint256 unlocked = (block.timestamp - startedAt) / mandate.periodLength + 1;
            if (mandate.totalPayments != 0 && unlocked > mandate.totalPayments) unlocked = mandate.totalPayments;
            assertLe(settledCount, unlocked, "per-mandate unlock bound");
        }

        assertEq(INITIAL_BALANCE - token.balanceOf(payer), expectedPayerDebit, "aggregate payer debit");
        assertEq(token.allowance(payer, address(executor)), type(uint256).max, "cancellation changed allowance");
        assertEq(handler.unexpectedOutcomes(), 0, "handler outcome diverged from model");
    }

    function _sign(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory signature) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
