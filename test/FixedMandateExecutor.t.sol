// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {FixedMandate} from "../src/FixedMandate.sol";
import {IFixedMandate} from "../src/interfaces/IFixedMandate.sol";
import {IUnorderedNonces} from "../src/interfaces/IUnorderedNonces.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {
    MockERC20,
    FeeOnTransferMockERC20,
    ExcessiveDebitMockERC20,
    MockERC1271Wallet,
    RevertingERC1271Wallet,
    FalseReturnMockERC20,
    NoReturnMockERC20,
    ReentrantMockERC20
} from "./helpers/MandateMocks.sol";

contract FixedMandateTest is Test {
    FixedMandate internal executor;
    MockERC20 internal token;

    uint256 internal payerPk = 0xA11CE;
    uint256 internal billerPk = 0xB0B;
    uint256 internal otherPk = 0xCAFE;

    address internal payer;
    address internal biller;
    address internal recipient = makeAddr("recipient");
    address internal other;

    uint256 internal constant START = 1_700_000_000;
    uint256 internal constant PERIOD = 30 days;
    uint256 internal constant AMOUNT = 100e6;
    bytes32 internal constant TERMS_HASH = keccak256("fixed mandate terms v1");
    bytes32 internal constant MANDATE_OPENED_TOPIC = 0x66aff64097eca9160e93ee1c78afff9b60272d6852647db29ee9c4a30d45ee12;
    bytes32 internal constant PAYMENT_SETTLED_TOPIC =
        0x1a59d7c424c7fbdd31c69bc31da5998120dbc69c9c4aecb3147453276e44ba5c;
    bytes32 internal constant MANDATE_CANCELLATION_TOPIC =
        0x328bb2c80907ff47c3ec6cf730d8843d943244db438a643c4d9f64c93e1cccb2;
    bytes32 internal constant CANCELLATION_NONCE_CONSUMED_TOPIC =
        keccak256("CancellationNonceConsumed(address,uint256)");
    bytes32 internal constant UNORDERED_NONCE_INVALIDATION_TOPIC =
        0xedd29604ecd2dbbcc47e637acf5f19ac68811dceb17fcbfbc647c253e0751cff;

    function setUp() public {
        payer = vm.addr(payerPk);
        biller = vm.addr(billerPk);
        other = vm.addr(otherPk);
        token = new MockERC20();
        executor = new FixedMandate();
        vm.warp(START);

        token.mint(payer, 100_000e6);
        vm.prank(payer);
        token.approve(address(executor), type(uint256).max);
    }

    // Typed data and contract separation

    function test_DomainSeparatorAndCanonicalTypedData() public view {
        IFixedMandate.Mandate memory mandate = _defaultMandate(43);
        mandate.firstPaymentAt = START + 7 days;
        uint256 deadline = START + 1 hours;
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("FixedMandate")),
                keccak256(bytes("1")),
                block.chainid,
                address(executor)
            )
        );
        bytes32 structHash = _canonicalMandateStructHash(mandate);
        bytes32 id = _eip712Digest(domainSeparator, structHash);

        assertEq(executor.DOMAIN_SEPARATOR(), domainSeparator, "domain separator");
        assertEq(executor.mandateId(mandate), id, "mandate id");
        assertEq(
            executor.hashMandateAuthorization(mandate, deadline),
            _eip712Digest(
                domainSeparator,
                keccak256(
                    abi.encode(
                        keccak256(
                            bytes(
                                "MandateAuthorization(Mandate mandate,uint256 signatureDeadline)Mandate(address payer,address biller,address recipient,address token,uint256 amountPerPayment,uint256 periodLength,uint256 firstPaymentAt,uint256 totalPayments,bytes32 termsHash,uint256 nonce)"
                            )
                        ),
                        structHash,
                        deadline
                    )
                )
            ),
            "payer authorization"
        );
        assertEq(
            executor.hashMandateAcceptance(mandate, deadline),
            _eip712Digest(
                domainSeparator,
                keccak256(
                    abi.encode(
                        keccak256(
                            bytes(
                                "MandateAcceptance(Mandate mandate,uint256 signatureDeadline)Mandate(address payer,address biller,address recipient,address token,uint256 amountPerPayment,uint256 periodLength,uint256 firstPaymentAt,uint256 totalPayments,bytes32 termsHash,uint256 nonce)"
                            )
                        ),
                        structHash,
                        deadline
                    )
                )
            ),
            "biller acceptance"
        );
        assertEq(
            executor.hashCancellation(id, payer, 99, deadline),
            _eip712Digest(
                domainSeparator,
                keccak256(
                    abi.encode(
                        keccak256(
                            "Cancellation(bytes32 mandateId,address authorizer,uint256 nonce,uint256 signatureDeadline)"
                        ),
                        id,
                        payer,
                        99,
                        deadline
                    )
                )
            ),
            "cancellation"
        );

        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            executor.eip712Domain();
        assertEq(uint8(fields), 0x0f, "EIP-5267 fields");
        assertEq(name, "FixedMandate", "name");
        assertEq(version, "1", "version");
        assertEq(chainId, block.chainid, "chain id");
        assertEq(verifyingContract, address(executor), "verifying contract");
    }

    function test_BreakingMandateSchemaUsesCanonicalFunctionSelectors() public pure {
        assertEq(IFixedMandate.openMandate.selector, bytes4(0x9ffad9b5), "openMandate");
        assertEq(IFixedMandate.openMandateAsPayer.selector, bytes4(0x78d94c0a), "openMandateAsPayer");
        assertEq(IFixedMandate.openMandateAsBiller.selector, bytes4(0x82fb1418), "openMandateAsBiller");
        assertEq(IFixedMandate.settle.selector, bytes4(0xa7346c38), "settle");
        assertEq(IFixedMandate.cancelMandateAsPayer.selector, bytes4(0x3824a692), "cancelMandateAsPayer");
        assertEq(IFixedMandate.cancelMandateAsBiller.selector, bytes4(0xa766eead), "cancelMandateAsBiller");
        assertEq(
            IFixedMandate.cancelMandateWithPayerSignature.selector,
            bytes4(0x6beebcd3),
            "cancelMandateWithPayerSignature"
        );
        assertEq(
            IFixedMandate.cancelMandateWithBillerSignature.selector,
            bytes4(0x3e9d0b07),
            "cancelMandateWithBillerSignature"
        );
        assertEq(IFixedMandate.mandateId.selector, bytes4(0x8da752bd), "mandateId");
        assertEq(IFixedMandate.hashMandateAuthorization.selector, bytes4(0x04613c1d), "hashMandateAuthorization");
        assertEq(IFixedMandate.hashMandateAcceptance.selector, bytes4(0x29c9d823), "hashMandateAcceptance");
        assertEq(IFixedMandate.unlockedPaymentCount.selector, bytes4(0x55f8e5d4), "unlockedPaymentCount");
        assertEq(IFixedMandate.hashCancellation.selector, bytes4(0x4fa747bf), "hashCancellation");
    }

    function test_RevertWhen_SignaturesTargetAnotherChainOrFixedExecutor() public {
        FixedMandate otherExecutor = new FixedMandate();
        IFixedMandate.Mandate memory mandate = _defaultMandate(1);
        uint256 deadline = START + 1 hours;
        bytes memory payerSignature = _sign(payerPk, otherExecutor.hashMandateAuthorization(mandate, deadline));
        bytes memory billerSignature = _sign(billerPk, otherExecutor.hashMandateAcceptance(mandate, deadline));

        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandate(mandate, deadline, deadline, payerSignature, billerSignature);

        mandate = _defaultMandate(2);
        payerSignature = _signAuthorization(payerPk, mandate, deadline);
        billerSignature = _signAcceptance(billerPk, mandate, deadline);
        bytes32 sourceMandateId = executor.mandateId(mandate);
        bytes32 sourceDomainSeparator = executor.DOMAIN_SEPARATOR();
        vm.chainId(block.chainid + 1);

        assertNotEq(executor.mandateId(mandate), sourceMandateId, "mandate id is chain-specific");
        assertNotEq(executor.DOMAIN_SEPARATOR(), sourceDomainSeparator, "domain separator is chain-specific");
        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandate(mandate, deadline, deadline, payerSignature, billerSignature);

        payerSignature = _signAuthorization(payerPk, mandate, deadline);
        billerSignature = _signAcceptance(billerPk, mandate, deadline);
        bytes32 returnedId = executor.openMandate(mandate, deadline, deadline, payerSignature, billerSignature);
        assertEq(returnedId, executor.mandateId(mandate), "current-chain signatures open");
    }

    // Opening

    function test_OpenMandateRequiresBothPartiesAndStoresGeneratedStart() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(10);
        bytes32 id = executor.mandateId(mandate);
        uint256 deadline = START + 1 hours;

        vm.expectEmit(true, true, true, true, address(executor));
        emit IFixedMandate.MandateOpened(
            id, payer, biller, address(token), recipient, AMOUNT, PERIOD, 0, 12, START, mandate.nonce, TERMS_HASH
        );
        vm.recordLogs();
        bytes32 returnedId = executor.openMandate(
            mandate,
            deadline,
            deadline,
            _signAuthorization(payerPk, mandate, deadline),
            _signAcceptance(billerPk, mandate, deadline)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(returnedId, id, "returned mandate id");
        _assertSingleExecutorLogTopic(logs, MANDATE_OPENED_TOPIC);
        (bool opened, bool cancelled, uint256 startedAt, uint256 settledCount) = executor.mandateStates(id);
        assertTrue(opened, "opened");
        assertFalse(cancelled, "not cancelled");
        assertEq(startedAt, START, "generated start");
        assertEq(settledCount, 0, "no settled payment");
        assertEq(executor.unlockedPaymentCount(mandate), 1, "first payment unlocked");
        assertEq(executor.nonceBitmap(payer, 0), uint256(1) << mandate.nonce, "payer nonce consumed");
    }

    function test_NeutralOpenerChoosesStartWithinSignatureDeadlines() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(11);
        uint256 deadline = START + 7 days;
        bytes memory payerSignature = _signAuthorization(payerPk, mandate, deadline);
        bytes memory billerSignature = _signAcceptance(billerPk, mandate, deadline);

        vm.warp(deadline);
        vm.prank(other);
        executor.openMandate(mandate, deadline, deadline, payerSignature, billerSignature);
        vm.snapshotGasLastCall("FixedMandate", "openMandate.eoa.relayed");

        (,, uint256 startedAt,) = executor.mandateStates(executor.mandateId(mandate));
        assertEq(startedAt, deadline, "signatures remain valid at the exact deadline");
    }

    function test_DeferredMandateOpensWithBothSignatures() public {
        _assertDeferredOpening(0);
    }

    function test_DeferredMandateOpensAsPayer() public {
        _assertDeferredOpening(1);
    }

    function test_DeferredMandateOpensAsBiller() public {
        _assertDeferredOpening(2);
    }

    function test_ExplicitFirstPaymentAtIsIndependentOfOpeningTime() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(101);
        mandate.firstPaymentAt = START + PERIOD;
        uint256 deadline = START + 2 * PERIOD;
        bytes memory payerSignature = _signAuthorization(payerPk, mandate, deadline);
        bytes memory billerSignature = _signAcceptance(billerPk, mandate, deadline);

        vm.warp(deadline);
        vm.prank(other);
        executor.openMandate(mandate, deadline, deadline, payerSignature, billerSignature);

        (,, uint256 startedAt,) = executor.mandateStates(executor.mandateId(mandate));
        assertEq(startedAt, deadline, "actual opening timestamp stored");
        assertEq(executor.unlockedPaymentCount(mandate), 2, "opening does not shift explicit schedule");
        executor.settle(mandate, 0);
        executor.settle(mandate, 1);
        vm.expectRevert(IFixedMandate.PaymentNotUnlocked.selector);
        executor.settle(mandate, 2);
        assertEq(token.balanceOf(recipient), 2 * AMOUNT, "accrued payments collected in succession");
    }

    function test_ExplicitFirstPaymentAtEqualToOpeningUnlocksImmediately() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(101);
        mandate.firstPaymentAt = START;
        _openMandate(mandate);
        assertEq(executor.unlockedPaymentCount(mandate), 1, "first unlock is inclusive");
        executor.settle(mandate, 0);
        assertEq(token.balanceOf(recipient), AMOUNT);
    }

    function test_DeferredScheduleBoundariesCatchUpAndFiniteCap() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(101);
        mandate.firstPaymentAt = START + 7 days;
        mandate.totalPayments = 3;
        _openMandate(mandate);

        vm.warp(mandate.firstPaymentAt - 1);
        assertEq(executor.unlockedPaymentCount(mandate), 0);
        vm.expectRevert(IFixedMandate.PaymentNotUnlocked.selector);
        executor.settle(mandate, 0);

        vm.warp(mandate.firstPaymentAt);
        assertEq(executor.unlockedPaymentCount(mandate), 1);
        executor.settle(mandate, 0);
        vm.warp(mandate.firstPaymentAt + PERIOD - 1);
        assertEq(executor.unlockedPaymentCount(mandate), 1);
        vm.expectRevert(IFixedMandate.PaymentNotUnlocked.selector);
        executor.settle(mandate, 1);

        vm.warp(mandate.firstPaymentAt + PERIOD);
        assertEq(executor.unlockedPaymentCount(mandate), 2);
        vm.warp(mandate.firstPaymentAt + 10 * PERIOD);
        assertEq(executor.unlockedPaymentCount(mandate), 3, "finite cap survives delayed collection");
        executor.settle(mandate, 1);
        executor.settle(mandate, 2);
        vm.expectRevert(IFixedMandate.PaymentNotUnlocked.selector);
        executor.settle(mandate, 3);

        (,,, uint256 settledCount) = executor.mandateStates(executor.mandateId(mandate));
        assertEq(settledCount, 3);
        assertEq(token.balanceOf(recipient), 3 * AMOUNT);
        assertEq(token.balanceOf(payer), 100_000e6 - 3 * AMOUNT);
    }

    function test_PastFirstPaymentAtAllowsFiniteCatchUpOnOpening() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(101);
        mandate.firstPaymentAt = START - 10 * PERIOD;
        mandate.totalPayments = 3;
        _openMandate(mandate);

        assertEq(executor.unlockedPaymentCount(mandate), 3, "past schedule capped on opening");
        for (uint256 i; i < 3; ++i) {
            executor.settle(mandate, i);
        }
        vm.expectRevert(IFixedMandate.PaymentNotUnlocked.selector);
        executor.settle(mandate, 3);
        assertEq(token.balanceOf(recipient), 3 * AMOUNT);
    }

    function test_FirstPaymentAtSupportsFullUint256Range() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(101);
        mandate.firstPaymentAt = type(uint256).max;
        mandate.periodLength = type(uint256).max;
        _openMandate(mandate);

        assertEq(executor.unlockedPaymentCount(mandate), 0, "timestamp not truncated to stored uint120");
        vm.warp(type(uint256).max - 1);
        vm.expectRevert(IFixedMandate.PaymentNotUnlocked.selector);
        executor.settle(mandate, 0);
        vm.warp(type(uint256).max);
        assertEq(executor.unlockedPaymentCount(mandate), 1);
        executor.settle(mandate, 0);
        vm.expectRevert(IFixedMandate.PaymentNotUnlocked.selector);
        executor.settle(mandate, 1);
        assertEq(token.balanceOf(recipient), AMOUNT);
    }

    function test_RevertWhen_FutureFirstPaymentAtChangedToZeroInSignatures() public {
        _assertFirstPaymentAtSignaturesBound(START + PERIOD, 0);
    }

    function test_RevertWhen_FirstPaymentAtChangedForOpenedMandate() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(101);
        mandate.firstPaymentAt = START + PERIOD;
        _openMandate(mandate);
        bytes32 originalId = executor.mandateId(mandate);

        mandate.firstPaymentAt = 0;
        assertNotEq(executor.mandateId(mandate), originalId);
        vm.expectRevert(IFixedMandate.MandateNotOpen.selector);
        executor.settle(mandate, 0);
        vm.expectRevert(IFixedMandate.MandateNotOpen.selector);
        executor.unlockedPaymentCount(mandate);
        vm.prank(payer);
        vm.expectRevert(IFixedMandate.MandateNotOpen.selector);
        executor.cancelMandateAsPayer(mandate);

        (bool opened, bool cancelled,, uint256 settledCount) = executor.mandateStates(originalId);
        assertTrue(opened);
        assertFalse(cancelled);
        assertEq(settledCount, 0);
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_OpenMandateAsPayerUsesCallerAuthorityAndBillerAcceptance() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(12);
        uint256 deadline = START + 1 hours;
        bytes memory billerSignature = _signAcceptance(billerPk, mandate, deadline);
        vm.prank(payer);
        bytes32 returnedId = executor.openMandateAsPayer(mandate, deadline, billerSignature);
        vm.snapshotGasLastCall("FixedMandate", "openMandateAsPayer.eoa.direct");
        bytes32 id = executor.mandateId(mandate);
        assertEq(returnedId, id, "returned mandate id");
        (bool opened,,,) = executor.mandateStates(id);
        assertTrue(opened, "payer opened");
        assertEq(executor.nonceBitmap(payer, 0), uint256(1) << mandate.nonce, "payer nonce consumed");
    }

    function test_OpenMandateAsBillerUsesCallerAuthorityAndPayerAuthorization() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(13);
        uint256 deadline = START + 1 hours;
        bytes memory payerSignature = _signAuthorization(payerPk, mandate, deadline);
        vm.prank(biller);
        bytes32 returnedId = executor.openMandateAsBiller(mandate, deadline, payerSignature);
        vm.snapshotGasLastCall("FixedMandate", "openMandateAsBiller.eoa.direct");
        bytes32 id = executor.mandateId(mandate);
        assertEq(returnedId, id, "returned mandate id");
        (bool opened,,,) = executor.mandateStates(id);
        assertTrue(opened, "biller opened");
        assertEq(executor.nonceBitmap(payer, 0), uint256(1) << mandate.nonce, "payer nonce consumed");
    }

    function test_RevertWhen_DirectOpeningCallerHasWrongRole() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(14);
        uint256 deadline = START + 1 hours;
        vm.startPrank(other);
        vm.expectRevert(IFixedMandate.InvalidCaller.selector);
        executor.openMandateAsPayer(mandate, deadline, hex"");
        vm.expectRevert(IFixedMandate.InvalidCaller.selector);
        executor.openMandateAsBiller(mandate, deadline, hex"");
        vm.stopPrank();
    }

    function test_RevertWhen_OpeningSignatureExpired() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(15);
        uint256 deadline = START + 1 hours;
        bytes memory payerSignature = _signAuthorization(payerPk, mandate, deadline);
        bytes memory billerSignature = _signAcceptance(billerPk, mandate, deadline);
        vm.warp(deadline + 1);

        vm.expectRevert(IFixedMandate.SignatureExpired.selector);
        executor.openMandate(mandate, deadline, deadline, payerSignature, billerSignature);

        IFixedMandate.Mandate memory payerMandate = _defaultMandate(29);
        bytes memory expiredBillerSignature = _signAcceptance(billerPk, payerMandate, deadline);
        vm.prank(payer);
        vm.expectRevert(IFixedMandate.SignatureExpired.selector);
        executor.openMandateAsPayer(payerMandate, deadline, expiredBillerSignature);

        IFixedMandate.Mandate memory billerMandate = _defaultMandate(30);
        bytes memory expiredPayerSignature = _signAuthorization(payerPk, billerMandate, deadline);
        vm.prank(biller);
        vm.expectRevert(IFixedMandate.SignatureExpired.selector);
        executor.openMandateAsBiller(billerMandate, deadline, expiredPayerSignature);

        assertEq(executor.nonceBitmap(payer, 0) & (uint256(1) << 15), 0, "relayed nonce available");
        assertEq(executor.nonceBitmap(payer, 0) & (uint256(1) << 29), 0, "payer-route nonce available");
        assertEq(executor.nonceBitmap(payer, 0) & (uint256(1) << 30), 0, "biller-route nonce available");
    }

    function test_RevertWhen_OpeningSignaturesAreMalformedAcrossEveryRoute() public {
        uint256 deadline = START + 1 hours;

        IFixedMandate.Mandate memory relayedMandate = _defaultMandate(24);
        bytes memory validBillerSignature = _signAcceptance(billerPk, relayedMandate, deadline);
        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandate(relayedMandate, deadline, deadline, hex"1234", validBillerSignature);

        IFixedMandate.Mandate memory payerMandate = _defaultMandate(25);
        vm.prank(payer);
        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandateAsPayer(payerMandate, deadline, hex"1234");

        IFixedMandate.Mandate memory billerMandate = _defaultMandate(26);
        vm.prank(biller);
        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandateAsBiller(billerMandate, deadline, hex"1234");

        assertEq(executor.nonceBitmap(payer, 0) & (uint256(1) << 24), 0, "relayed nonce available");
        assertEq(executor.nonceBitmap(payer, 0) & (uint256(1) << 25), 0, "payer-route nonce available");
        assertEq(executor.nonceBitmap(payer, 0) & (uint256(1) << 26), 0, "biller-route nonce available");
    }

    function test_RevertWhen_BillerAcceptanceIsInvalidOrExpired() public {
        uint256 payerDeadline = START + 2 hours;
        uint256 billerDeadline = START + 1 hours;
        IFixedMandate.Mandate memory invalidMandate = _defaultMandate(27);
        bytes memory validPayerSignature = _signAuthorization(payerPk, invalidMandate, payerDeadline);

        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandate(invalidMandate, payerDeadline, billerDeadline, validPayerSignature, hex"1234");

        IFixedMandate.Mandate memory expiredMandate = _defaultMandate(28);
        bytes memory payerSignature = _signAuthorization(payerPk, expiredMandate, payerDeadline);
        bytes memory billerSignature = _signAcceptance(billerPk, expiredMandate, billerDeadline);
        vm.warp(billerDeadline + 1);
        vm.expectRevert(IFixedMandate.SignatureExpired.selector);
        executor.openMandate(expiredMandate, payerDeadline, billerDeadline, payerSignature, billerSignature);

        assertEq(executor.nonceBitmap(payer, 0) & (uint256(1) << 27), 0, "invalid acceptance nonce available");
        assertEq(executor.nonceBitmap(payer, 0) & (uint256(1) << 28), 0, "expired acceptance nonce available");
    }

    function test_RevertWhen_SignatureIsForDifferentMandate() public {
        IFixedMandate.Mandate memory signedMandate = _defaultMandate(16);
        IFixedMandate.Mandate memory submittedMandate = _defaultMandate(16);
        submittedMandate.totalPayments = 13;
        uint256 deadline = START + 1 hours;
        bytes memory payerSignature = _signAuthorization(payerPk, signedMandate, deadline);
        bytes memory billerSignature = _signAcceptance(billerPk, signedMandate, deadline);

        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandate(submittedMandate, deadline, deadline, payerSignature, billerSignature);
    }

    function test_InvalidMandateFieldsRevertBeforeSignatureChecks() public {
        IFixedMandate.Mandate memory malformed = _defaultMandate(17);
        malformed.payer = address(0);
        _expectInvalidMandate(malformed);
        malformed = _defaultMandate(17);
        malformed.biller = address(0);
        _expectInvalidMandate(malformed);
        malformed = _defaultMandate(17);
        malformed.recipient = address(0);
        _expectInvalidMandate(malformed);
        malformed = _defaultMandate(17);
        malformed.token = address(0);
        _expectInvalidMandate(malformed);
        malformed = _defaultMandate(17);
        malformed.amountPerPayment = 0;
        _expectInvalidMandate(malformed);
        malformed = _defaultMandate(17);
        malformed.periodLength = 0;
        _expectInvalidMandate(malformed);
        malformed = _defaultMandate(17);
        malformed.termsHash = bytes32(0);
        _expectInvalidMandate(malformed);
    }

    function test_MalformedMandatePrecedesERC1271Callback() public {
        RevertingERC1271Wallet revertingWallet = new RevertingERC1271Wallet();
        IFixedMandate.Mandate memory mandate = _defaultMandate(18);
        mandate.payer = address(revertingWallet);
        mandate.amountPerPayment = 0;

        vm.expectRevert(IFixedMandate.InvalidMandate.selector);
        executor.openMandate(mandate, START + 1 hours, START + 1 hours, hex"", hex"");
    }

    function test_ZeroTotalPaymentsCreatesValidIndefiniteMandate() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(19);
        mandate.totalPayments = 0;
        _openMandate(mandate);
        vm.warp(START + 100 * PERIOD);
        assertEq(executor.unlockedPaymentCount(mandate), 101, "indefinite accrual");
    }

    function test_NonceInvalidationAndOpeningReplayAreEnforced() public {
        IFixedMandate.Mandate memory invalidated = _defaultMandate(20);
        vm.prank(payer);
        executor.invalidateUnorderedNonces(0, uint256(1) << 20);
        vm.snapshotGasLastCall("FixedMandate", "invalidateUnorderedNonces.nonzero.cold");
        uint256 deadline = START + 1 hours;
        bytes memory invalidatedPayerSignature = _signAuthorization(payerPk, invalidated, deadline);
        bytes memory invalidatedBillerSignature = _signAcceptance(billerPk, invalidated, deadline);
        vm.expectRevert(IUnorderedNonces.InvalidUnorderedNonce.selector);
        executor.openMandate(invalidated, deadline, deadline, invalidatedPayerSignature, invalidatedBillerSignature);

        IFixedMandate.Mandate memory opened = _defaultMandate(21);
        bytes memory openedBillerSignature = _signAcceptance(billerPk, opened, deadline);
        vm.prank(payer);
        executor.openMandateAsPayer(opened, deadline, openedBillerSignature);
        bytes memory openedPayerSignature = _signAuthorization(payerPk, opened, deadline);
        vm.prank(biller);
        vm.expectRevert(IFixedMandate.MandateAlreadyOpened.selector);
        executor.openMandateAsBiller(opened, deadline, openedPayerSignature);

        vm.prank(payer);
        executor.invalidateUnorderedNonces(0, uint256(1) << opened.nonce);
        executor.settle(opened, 0);
        (bool isOpen, bool isCancelled,, uint256 settledCount) = executor.mandateStates(executor.mandateId(opened));
        assertTrue(isOpen, "invalidation does not close an opened mandate");
        assertFalse(isCancelled, "invalidation does not cancel an opened mandate");
        assertEq(settledCount, 1, "opened mandate remains settleable");
    }

    function test_ZeroNonceInvalidationEmitsWithoutChangingBitmap() public {
        uint248 wordPos = 123;

        vm.expectEmit(true, true, false, true, address(executor));
        emit IUnorderedNonces.UnorderedNonceInvalidation(payer, wordPos, 0);
        vm.prank(payer);
        executor.invalidateUnorderedNonces(wordPos, 0);

        assertEq(executor.nonceBitmap(payer, wordPos), 0, "zero mask is a state no-op");
    }

    function testFuzz_NonceInvalidationIsMonotonicAndOwnerScoped(uint248 wordPos, uint256 firstMask, uint256 secondMask)
        public
    {
        vm.prank(payer);
        executor.invalidateUnorderedNonces(wordPos, firstMask);
        vm.prank(payer);
        executor.invalidateUnorderedNonces(wordPos, secondMask);
        vm.prank(other);
        executor.invalidateUnorderedNonces(wordPos, secondMask);

        assertEq(executor.nonceBitmap(payer, wordPos), firstMask | secondMask, "payer masks are ORed");
        assertEq(executor.nonceBitmap(other, wordPos), secondMask, "owners have independent bitmap words");
    }

    function testFuzz_NonceInvalidationEventCarriesFullWidthWordAndNonzeroMask(uint248 wordPos, uint256 rawMask)
        public
    {
        uint256 mask = rawMask == 0 ? 1 : rawMask;

        vm.expectEmit(true, true, false, true, address(executor));
        emit IUnorderedNonces.UnorderedNonceInvalidation(payer, wordPos, mask);
        vm.recordLogs();
        vm.prank(payer);
        executor.invalidateUnorderedNonces(wordPos, mask);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertSingleExecutorLogTopic(logs, UNORDERED_NONCE_INVALIDATION_TOPIC);
        assertEq(executor.nonceBitmap(payer, wordPos), mask, "event payload matches stored full-width mask");
    }

    function test_EIP2098CompactSignaturesCanOpenMandate() public {
        IFixedMandate.Mandate memory compactMandate = _defaultMandate(22);
        uint256 deadline = START + 1 hours;
        bytes32 returnedId = executor.openMandate(
            compactMandate,
            deadline,
            deadline,
            _compact(_signAuthorization(payerPk, compactMandate, deadline)),
            _compact(_signAcceptance(billerPk, compactMandate, deadline))
        );
        vm.snapshotGasLastCall("FixedMandate", "openMandate.eoa.compact");
        bytes32 id = executor.mandateId(compactMandate);
        assertEq(returnedId, id, "returned mandate id");
        (bool opened,,,) = executor.mandateStates(id);
        assertTrue(opened, "compact signatures opened mandate");
    }

    function test_ZeroOneVSignaturesCanOpenMandate() public {
        IFixedMandate.Mandate memory zeroOneMandate = _defaultMandate(23);
        uint256 deadline = START + 1 hours;
        bytes32 returnedId = executor.openMandate(
            zeroOneMandate,
            deadline,
            deadline,
            _zeroOneV(_signAuthorization(payerPk, zeroOneMandate, deadline)),
            _zeroOneV(_signAcceptance(billerPk, zeroOneMandate, deadline))
        );
        vm.snapshotGasLastCall("FixedMandate", "openMandate.eoa.zeroOneV");
        bytes32 id = executor.mandateId(zeroOneMandate);
        assertEq(returnedId, id, "returned mandate id");
        (bool opened,,,) = executor.mandateStates(id);
        assertTrue(opened, "zero/one-v signatures opened mandate");
    }

    function test_RevertWhen_CompactSignatureHasWrongSigner() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(47);
        uint256 deadline = START + 1 hours;
        bytes memory wrongPayerSignature = _compact(_signAuthorization(otherPk, mandate, deadline));
        bytes memory billerSignature = _signAcceptance(billerPk, mandate, deadline);

        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandate(mandate, deadline, deadline, wrongPayerSignature, billerSignature);
        assertEq(executor.nonceBitmap(payer, 0) & (uint256(1) << mandate.nonce), 0, "payer nonce available");
    }

    function test_RevertWhen_ECDSASignaturesBypassERC1271Policy() public {
        uint256 delegatedPayerPk = 0xD3E6A7E;
        address delegatedPayer = vm.addr(delegatedPayerPk);
        RevertingERC1271Wallet rejectingWallet = new RevertingERC1271Wallet();
        vm.etch(delegatedPayer, address(rejectingWallet).code);

        IFixedMandate.Mandate memory compactMandate = _defaultMandate(44);
        compactMandate.payer = delegatedPayer;
        uint256 deadline = START + 1 hours;
        bytes memory compactPayerSignature = _compact(_signAuthorization(delegatedPayerPk, compactMandate, deadline));
        bytes memory compactBillerSignature = _signAcceptance(billerPk, compactMandate, deadline);

        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandate(compactMandate, deadline, deadline, compactPayerSignature, compactBillerSignature);

        IFixedMandate.Mandate memory fullMandate = _defaultMandate(45);
        fullMandate.payer = delegatedPayer;
        bytes memory fullPayerSignature = _signAuthorization(delegatedPayerPk, fullMandate, deadline);
        bytes memory fullBillerSignature = _signAcceptance(billerPk, fullMandate, deadline);

        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandate(fullMandate, deadline, deadline, fullPayerSignature, fullBillerSignature);
    }

    function test_ERC1271PayerAndBillerCanOpenMandates() public {
        MockERC1271Wallet payerWallet = new MockERC1271Wallet(payer);
        IFixedMandate.Mandate memory payerMandate = _defaultMandate(24);
        payerMandate.payer = address(payerWallet);
        uint256 deadline = START + 1 hours;
        bytes32 payerReturnedId = executor.openMandate(
            payerMandate,
            deadline,
            deadline,
            _sign(payerPk, executor.hashMandateAuthorization(payerMandate, deadline)),
            _signAcceptance(billerPk, payerMandate, deadline)
        );
        vm.snapshotGasLastCall("FixedMandate", "openMandate.erc1271.payer");
        assertEq(payerReturnedId, executor.mandateId(payerMandate), "payer wallet mandate id");

        MockERC1271Wallet billerWallet = new MockERC1271Wallet(biller);
        IFixedMandate.Mandate memory billerMandate = _defaultMandate(25);
        billerMandate.biller = address(billerWallet);
        bytes32 billerReturnedId = executor.openMandate(
            billerMandate,
            deadline,
            deadline,
            _signAuthorization(payerPk, billerMandate, deadline),
            _sign(billerPk, executor.hashMandateAcceptance(billerMandate, deadline))
        );
        vm.snapshotGasLastCall("FixedMandate", "openMandate.erc1271.biller");
        assertEq(billerReturnedId, executor.mandateId(billerMandate), "biller wallet mandate id");
    }

    function test_ContractWalletPayerCanCallDirectOpen() public {
        MockERC1271Wallet payerWallet = new MockERC1271Wallet(payer);
        IFixedMandate.Mandate memory mandate = _defaultMandate(26);
        mandate.payer = address(payerWallet);
        uint256 deadline = START + 1 hours;
        bytes memory billerSignature = _signAcceptance(billerPk, mandate, deadline);
        bytes memory callData = abi.encodeCall(IFixedMandate.openMandateAsPayer, (mandate, deadline, billerSignature));

        vm.prank(payer);
        vm.startSnapshotGas("FixedMandate", "openMandateAsPayer.wallet.endToEnd");
        payerWallet.execute(address(executor), callData);
        vm.stopSnapshotGas();
        (bool opened,,,) = executor.mandateStates(executor.mandateId(mandate));
        assertTrue(opened, "contract payer opened directly");
    }

    function test_ContractWalletPayerCanApproveAndSettleEndToEnd() public {
        MockERC1271Wallet payerWallet = new MockERC1271Wallet(payer);
        IFixedMandate.Mandate memory mandate = _defaultMandate(48);
        mandate.payer = address(payerWallet);
        uint256 deadline = START + 1 hours;
        token.mint(address(payerWallet), AMOUNT);

        vm.prank(payer);
        payerWallet.approveToken(address(token), address(executor), AMOUNT);
        executor.openMandate(
            mandate,
            deadline,
            deadline,
            _sign(payerPk, executor.hashMandateAuthorization(mandate, deadline)),
            _signAcceptance(billerPk, mandate, deadline)
        );

        vm.prank(other);
        executor.settle(mandate, 0);

        assertEq(token.balanceOf(address(payerWallet)), 0, "contract payer debited");
        assertEq(token.balanceOf(recipient), AMOUNT, "recipient credited");
        assertEq(token.allowance(address(payerWallet), address(executor)), 0, "finite allowance consumed");
        (,,, uint256 settledCount) = executor.mandateStates(executor.mandateId(mandate));
        assertEq(settledCount, 1, "one payment settled");
    }

    function test_ContractWalletBillerCanOpenSettleAndCancelDirectly() public {
        MockERC1271Wallet billerWallet = new MockERC1271Wallet(biller);
        IFixedMandate.Mandate memory mandate = _defaultMandate(27);
        mandate.biller = address(billerWallet);
        uint256 deadline = START + 1 hours;
        bytes memory payerSignature = _signAuthorization(payerPk, mandate, deadline);
        bytes memory openCallData =
            abi.encodeCall(IFixedMandate.openMandateAsBiller, (mandate, deadline, payerSignature));
        bytes memory settleCallData = abi.encodeCall(IFixedMandate.settle, (mandate, 0));
        bytes memory cancelCallData = abi.encodeCall(IFixedMandate.cancelMandateAsBiller, (mandate));

        vm.prank(biller);
        vm.startSnapshotGas("FixedMandate", "openMandateAsBiller.wallet.endToEnd");
        billerWallet.execute(address(executor), openCallData);
        vm.stopSnapshotGas();
        vm.prank(biller);
        vm.startSnapshotGas("FixedMandate", "settle.wallet.first");
        billerWallet.execute(address(executor), settleCallData);
        vm.stopSnapshotGas();
        assertEq(token.balanceOf(recipient), AMOUNT, "recipient receives full amount");
        assertEq(token.balanceOf(address(billerWallet)), 0, "submitter receives no protocol funds");

        vm.prank(biller);
        vm.startSnapshotGas("FixedMandate", "cancelMandateAsBiller.wallet.endToEnd");
        billerWallet.execute(address(executor), cancelCallData);
        vm.stopSnapshotGas();
        (, bool cancelled,,) = executor.mandateStates(executor.mandateId(mandate));
        assertTrue(cancelled, "contract biller cancelled directly");
    }

    // Accrual and permissionless settlement

    function test_AnyCallerCanSettleAndRecipientReceivesFullAmount() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(30);
        mandate = _openMandate(mandate);
        bytes32 id = executor.mandateId(mandate);

        vm.prank(other);
        executor.settle(mandate, 0);
        vm.snapshotGasLastCall("FixedMandate", "settle.permissionless.first");

        assertEq(token.balanceOf(recipient), AMOUNT, "recipient full amount");
        assertEq(token.balanceOf(other), 0, "submitter receives no protocol funds");
        assertEq(token.balanceOf(payer), 100_000e6 - AMOUNT, "payer debit");
        (,,, uint256 settledCount) = executor.mandateStates(id);
        assertEq(settledCount, 1, "one payment settled");
    }

    function test_PaymentSettledEmitsSubmitterAndNoFee() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(46);
        mandate = _openMandate(mandate);
        bytes32 id = executor.mandateId(mandate);

        vm.expectEmit(true, true, true, true, address(executor));
        emit IFixedMandate.PaymentSettled(id, 0, payer, biller, recipient, address(token), AMOUNT, other);
        vm.prank(other);
        executor.settle(mandate, 0);

        assertEq(token.balanceOf(recipient), AMOUNT, "event amount equals recipient credit");
        assertEq(token.balanceOf(other), 0, "event submitter receives no funds");
    }

    function test_PayerRecipientSelfTransferConsumesAllowanceWithoutChangingNetBalance() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(49);
        mandate.recipient = payer;
        mandate = _openMandate(mandate);
        vm.prank(payer);
        token.approve(address(executor), AMOUNT);
        uint256 payerBalanceBefore = token.balanceOf(payer);

        vm.prank(other);
        executor.settle(mandate, 0);

        assertEq(token.balanceOf(payer), payerBalanceBefore, "self-transfer has no net balance movement");
        assertEq(token.allowance(payer, address(executor)), 0, "self-transfer still consumes allowance");
        assertEq(token.balanceOf(other), 0, "submitter receives no protocol reward");
        (,,, uint256 settledCount) = executor.mandateStates(executor.mandateId(mandate));
        assertEq(settledCount, 1, "self-transfer consumes the payment index");
    }

    function test_SupportedRoleOverlapsPreservePinnedSettlementAndCancellation() public {
        IFixedMandate.Mandate memory billerRecipient = _defaultMandate(93);
        billerRecipient.recipient = biller;
        billerRecipient = _openMandate(billerRecipient);

        vm.prank(other);
        executor.settle(billerRecipient, 0);
        assertEq(token.balanceOf(biller), AMOUNT, "biller-recipient receives the pinned payment");
        assertEq(token.balanceOf(other), 0, "unrelated submitter receives no funds");
        vm.prank(biller);
        executor.cancelMandateAsBiller(billerRecipient);
        (bool opened, bool cancelled,, uint256 settledCount) =
            executor.mandateStates(executor.mandateId(billerRecipient));
        assertTrue(opened, "biller-recipient mandate opened");
        assertTrue(cancelled, "biller-recipient can cancel as biller");
        assertEq(settledCount, 1, "biller-recipient mandate settled once");

        IFixedMandate.Mandate memory allRoles = _defaultMandate(94);
        allRoles.biller = payer;
        allRoles.recipient = payer;
        uint256 deadline = START + 1 hours;
        executor.openMandate(
            allRoles,
            deadline,
            deadline,
            _signAuthorization(payerPk, allRoles, deadline),
            _signAcceptance(payerPk, allRoles, deadline)
        );
        vm.prank(payer);
        token.approve(address(executor), AMOUNT);
        uint256 payerBalanceBefore = token.balanceOf(payer);

        vm.prank(other);
        executor.settle(allRoles, 0);
        assertEq(token.balanceOf(payer), payerBalanceBefore, "all-role self-payment has no net balance movement");
        assertEq(token.allowance(payer, address(executor)), 0, "all-role self-payment consumes allowance");
        vm.prank(payer);
        executor.cancelMandateAsBiller(allRoles);
        (opened, cancelled,, settledCount) = executor.mandateStates(executor.mandateId(allRoles));
        assertTrue(opened, "all-role mandate opened");
        assertTrue(cancelled, "all-role address can cancel as biller");
        assertEq(settledCount, 1, "all-role mandate settled once");
    }

    function test_PaymentUnlocksExactlyAtEachBoundary() public {
        IFixedMandate.Mandate memory mandate = _openMandate(_defaultMandate(31));
        executor.settle(mandate, 0);

        vm.warp(START + PERIOD - 1);
        assertEq(executor.unlockedPaymentCount(mandate), 1, "not unlocked early");
        vm.expectRevert(IFixedMandate.PaymentNotUnlocked.selector);
        executor.settle(mandate, 1);

        vm.warp(START + PERIOD);
        assertEq(executor.unlockedPaymentCount(mandate), 2, "unlocked at boundary");
        executor.settle(mandate, 1);
    }

    function test_DifferentCallersRaceOnlyOnPaymentIndex() public {
        IFixedMandate.Mandate memory mandate = _openMandate(_defaultMandate(35));
        vm.warp(START + PERIOD);

        vm.prank(biller);
        executor.settle(mandate, 0);
        vm.prank(other);
        vm.expectRevert(IFixedMandate.UnexpectedPaymentIndex.selector);
        executor.settle(mandate, 0);

        vm.prank(other);
        executor.settle(mandate, 1);
        vm.snapshotGasLastCall("FixedMandate", "settle.permissionless.subsequent");
        (,,, uint256 settledCount) = executor.mandateStates(executor.mandateId(mandate));
        assertEq(settledCount, 2, "two distinct indices");
        assertEq(token.balanceOf(recipient), 2 * AMOUNT, "both occurrences pay full amount");
        assertEq(token.balanceOf(biller), 0, "biller submitter receives no funds");
        assertEq(token.balanceOf(other), 0, "other submitter receives no funds");
    }

    function test_SettlementUsesExactlyOneTransferFrom() public {
        ReentrantMockERC20 countingToken = new ReentrantMockERC20();
        IFixedMandate.Mandate memory mandate = _defaultMandate(38);
        mandate.token = address(countingToken);
        mandate = _openMandate(mandate);
        countingToken.mint(payer, AMOUNT);
        vm.prank(payer);
        countingToken.approve(address(executor), AMOUNT);

        vm.prank(other);
        executor.settle(mandate, 0);

        assertEq(countingToken.transferFromCount(), 1, "single transfer");
        assertEq(countingToken.balanceOf(recipient), AMOUNT, "recipient full amount");
        assertEq(countingToken.balanceOf(other), 0, "submitter receives no funds");
    }

    function test_SeparateMandatesMaintainIndependentCounters() public {
        IFixedMandate.Mandate memory first = _openMandate(_defaultMandate(41));
        IFixedMandate.Mandate memory second = _openMandate(_defaultMandate(42));
        executor.settle(first, 0);
        executor.settle(second, 0);
        (,,, uint256 firstCount) = executor.mandateStates(executor.mandateId(first));
        (,,, uint256 secondCount) = executor.mandateStates(executor.mandateId(second));
        assertEq(firstCount, 1);
        assertEq(secondCount, 1);
    }

    function test_RevertWhen_UnlockedCountQueriedBeforeOpening() public {
        vm.expectRevert(IFixedMandate.MandateNotOpen.selector);
        executor.unlockedPaymentCount(_defaultMandate(43));
    }

    function test_RevertWhen_UnopenedOrAlteredMandateSettles() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(44);
        uint256 payerBalanceBefore = token.balanceOf(payer);

        vm.prank(other);
        vm.expectRevert(IFixedMandate.MandateNotOpen.selector);
        executor.settle(mandate, 0);

        mandate = _openMandate(mandate);
        IFixedMandate.Mandate memory alteredMandate = _defaultMandate(44);
        alteredMandate.recipient = other;
        vm.prank(other);
        vm.expectRevert(IFixedMandate.MandateNotOpen.selector);
        executor.settle(alteredMandate, 0);

        (bool alteredOpened,,, uint256 alteredCount) = executor.mandateStates(executor.mandateId(alteredMandate));
        (,,, uint256 openedCount) = executor.mandateStates(executor.mandateId(mandate));
        assertFalse(alteredOpened, "altered mandate remains unopened");
        assertEq(alteredCount, 0, "altered state unchanged");
        assertEq(openedCount, 0, "opened mandate state unchanged");
        assertEq(token.balanceOf(payer), payerBalanceBefore, "payer not debited");
        assertEq(token.balanceOf(recipient), 0, "recipient not credited");
        assertEq(token.balanceOf(other), 0, "attacker not credited");
    }

    // Cancellation

    function test_DirectPayerAndBillerCancellationBlockSettlement() public {
        IFixedMandate.Mandate memory payerCancelled = _openMandate(_defaultMandate(50));
        bytes32 payerId = executor.mandateId(payerCancelled);
        vm.expectEmit(true, true, true, true, address(executor));
        emit IFixedMandate.MandateCancellation(payerId, payer, payer);
        vm.recordLogs();
        vm.prank(payer);
        executor.cancelMandateAsPayer(payerCancelled);
        vm.snapshotGasLastCall("FixedMandate", "cancelMandate.payer.direct");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertSingleExecutorLogTopic(logs, MANDATE_CANCELLATION_TOPIC);
        vm.expectRevert(IFixedMandate.MandateCancelled.selector);
        executor.settle(payerCancelled, 0);
        assertFalse(
            executor.cancellationNonceUsed(payer, payerCancelled.nonce), "direct cancellation consumes no signed nonce"
        );

        IFixedMandate.Mandate memory billerCancelled = _openMandate(_defaultMandate(51));
        bytes32 billerId = executor.mandateId(billerCancelled);
        vm.expectEmit(true, true, true, true, address(executor));
        emit IFixedMandate.MandateCancellation(billerId, payer, biller);
        vm.recordLogs();
        vm.prank(biller);
        executor.cancelMandateAsBiller(billerCancelled);
        vm.snapshotGasLastCall("FixedMandate", "cancelMandateAsBiller.biller.direct");
        _assertSingleExecutorLogTopic(vm.getRecordedLogs(), MANDATE_CANCELLATION_TOPIC);
        vm.expectRevert(IFixedMandate.MandateCancelled.selector);
        executor.settle(billerCancelled, 0);
        assertFalse(
            executor.cancellationNonceUsed(biller, billerCancelled.nonce),
            "direct cancellation consumes no signed nonce"
        );
    }

    function test_RevertWhen_DirectCancellationCallerIsUnauthorized() public {
        IFixedMandate.Mandate memory mandate = _openMandate(_defaultMandate(52));
        vm.startPrank(other);
        vm.expectRevert(IFixedMandate.InvalidCaller.selector);
        executor.cancelMandateAsPayer(mandate);
        vm.expectRevert(IFixedMandate.InvalidCaller.selector);
        executor.cancelMandateAsBiller(mandate);
        vm.stopPrank();
    }

    function test_PayerAndBillerSignatureCancellationAreAuthorizerBound() public {
        IFixedMandate.Mandate memory payerMandate = _openMandate(_defaultMandate(53));
        bytes32 payerId = executor.mandateId(payerMandate);
        uint256 deadline = START + 1 hours;
        uint256 cancelNonce = 7;
        bytes memory payerSignature = _signCancel(payerPk, payerId, payer, cancelNonce, deadline);
        vm.expectEmit(true, true, true, true, address(executor));
        emit IFixedMandate.MandateCancellation(payerId, payer, payer);
        vm.recordLogs();
        vm.prank(other);
        executor.cancelMandateWithPayerSignature(payerMandate, cancelNonce, deadline, payerSignature);
        vm.snapshotGasLastCall("FixedMandate", "cancelMandate.payer.signature.eoa");
        _assertSignedCancellationLogs(vm.getRecordedLogs(), payerId, payer, payer, cancelNonce);
        assertTrue(executor.cancellationNonceUsed(payer, cancelNonce), "payer cancellation nonce used");
        assertFalse(executor.cancellationNonceUsed(biller, cancelNonce), "biller nonce separate");
        bytes memory replayedPayerSignature = _signCancel(payerPk, payerId, payer, cancelNonce, deadline);
        vm.recordLogs();
        vm.expectRevert(IFixedMandate.InvalidCancellationNonce.selector);
        executor.cancelMandateWithPayerSignature(payerMandate, cancelNonce, deadline, replayedPayerSignature);
        assertEq(vm.getRecordedLogs().length, 0, "payer replay emits no events");
        assertTrue(executor.cancellationNonceUsed(payer, cancelNonce), "payer replay preserves consumed nonce");

        IFixedMandate.Mandate memory billerMandate = _openMandate(_defaultMandate(54));
        bytes32 billerId = executor.mandateId(billerMandate);
        bytes memory billerSignature = _signCancel(billerPk, billerId, biller, cancelNonce, deadline);
        vm.expectEmit(true, true, true, true, address(executor));
        emit IFixedMandate.MandateCancellation(billerId, payer, biller);
        vm.recordLogs();
        vm.prank(other);
        executor.cancelMandateWithBillerSignature(billerMandate, cancelNonce, deadline, billerSignature);
        vm.snapshotGasLastCall("FixedMandate", "cancelMandate.biller.signature.eoa");
        _assertSignedCancellationLogs(vm.getRecordedLogs(), billerId, payer, biller, cancelNonce);
        assertTrue(executor.cancellationNonceUsed(biller, cancelNonce), "biller cancellation nonce used");
        vm.recordLogs();
        vm.expectRevert(IFixedMandate.InvalidCancellationNonce.selector);
        executor.cancelMandateWithBillerSignature(billerMandate, cancelNonce, deadline, billerSignature);
        assertEq(vm.getRecordedLogs().length, 0, "biller replay emits no events");
        assertTrue(executor.cancellationNonceUsed(biller, cancelNonce), "biller replay preserves consumed nonce");
    }

    function test_AttackerCannotCancelBySubstitutingThemselfAsMandateParty() public {
        IFixedMandate.Mandate memory openedMandate = _openMandate(_defaultMandate(64));
        IFixedMandate.Mandate memory forgedMandate = _defaultMandate(64);
        forgedMandate.biller = other;

        vm.prank(other);
        vm.expectRevert(IFixedMandate.MandateNotOpen.selector);
        executor.cancelMandateAsBiller(forgedMandate);

        (bool opened, bool cancelled,,) = executor.mandateStates(executor.mandateId(openedMandate));
        assertTrue(opened, "real mandate open");
        assertFalse(cancelled, "real mandate unaffected");
    }

    function test_SameAddressPayerAndBillerShareCancellationNonceNamespace() public {
        IFixedMandate.Mandate memory payerRoute = _defaultMandate(65);
        payerRoute.biller = payer;
        uint256 deadline = START + 1 hours;
        executor.openMandate(
            payerRoute,
            deadline,
            deadline,
            _signAuthorization(payerPk, payerRoute, deadline),
            _signAcceptance(payerPk, payerRoute, deadline)
        );
        bytes32 payerRouteId = executor.mandateId(payerRoute);
        bytes memory payerSignature = _signCancel(payerPk, payerRouteId, payer, 10, deadline);
        vm.recordLogs();
        executor.cancelMandateWithPayerSignature(payerRoute, 10, deadline, payerSignature);
        _assertSignedCancellationLogs(vm.getRecordedLogs(), payerRouteId, payer, payer, 10);

        IFixedMandate.Mandate memory billerRoute = _defaultMandate(66);
        billerRoute.biller = payer;
        executor.openMandate(
            billerRoute,
            deadline,
            deadline,
            _signAuthorization(payerPk, billerRoute, deadline),
            _signAcceptance(payerPk, billerRoute, deadline)
        );
        bytes32 billerRouteId = executor.mandateId(billerRoute);
        bytes memory billerSignature = _signCancel(payerPk, billerRouteId, payer, 10, deadline);
        vm.recordLogs();
        vm.expectRevert(IFixedMandate.InvalidCancellationNonce.selector);
        executor.cancelMandateWithBillerSignature(billerRoute, 10, deadline, billerSignature);
        assertEq(vm.getRecordedLogs().length, 0, "shared nonce replay emits nothing");
    }

    function test_RevertWhen_CancellationSignatureUsesWrongOrUnrelatedParty() public {
        IFixedMandate.Mandate memory mandate = _openMandate(_defaultMandate(55));
        bytes32 id = executor.mandateId(mandate);
        uint256 deadline = START + 1 hours;
        bytes memory wrongRoleSignature = _signCancel(billerPk, id, biller, 1, deadline);
        bytes memory unrelatedSignature = _signCancel(otherPk, id, biller, 2, deadline);

        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.cancelMandateWithPayerSignature(mandate, 1, deadline, wrongRoleSignature);
        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.cancelMandateWithBillerSignature(mandate, 2, deadline, unrelatedSignature);
        assertFalse(executor.cancellationNonceUsed(payer, 1), "payer nonce available");
        assertFalse(executor.cancellationNonceUsed(biller, 2), "biller nonce available");
    }

    function test_RevertWhen_CancellationSignatureTargetsDifferentMandate() public {
        IFixedMandate.Mandate memory signedMandate = _openMandate(_defaultMandate(56));
        IFixedMandate.Mandate memory submittedMandate = _defaultMandate(56);
        submittedMandate.totalPayments = 99;
        uint256 deadline = START + 1 hours;
        bytes memory signature = _signCancel(billerPk, executor.mandateId(signedMandate), biller, 3, deadline);

        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.cancelMandateWithBillerSignature(submittedMandate, 3, deadline, signature);
        assertFalse(executor.cancellationNonceUsed(biller, 3), "nonce rolled back");
    }

    function test_ExpiredMalformedAndFailedCancellationDoNotConsumeNonce() public {
        IFixedMandate.Mandate memory mandate = _openMandate(_defaultMandate(57));
        uint256 deadline = START + 1 hours;
        vm.warp(deadline + 1);
        vm.expectRevert(IFixedMandate.SignatureExpired.selector);
        executor.cancelMandateWithPayerSignature(mandate, 4, deadline, hex"1234");
        assertFalse(executor.cancellationNonceUsed(payer, 4));

        vm.warp(deadline);
        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.cancelMandateWithBillerSignature(mandate, 5, deadline, hex"1234");
        assertFalse(executor.cancellationNonceUsed(biller, 5));

        IFixedMandate.Mandate memory unopened = _defaultMandate(58);
        bytes32 unopenedId = executor.mandateId(unopened);
        bytes memory unopenedSignature = _signCancel(billerPk, unopenedId, biller, 6, deadline);
        vm.expectRevert(IFixedMandate.MandateNotOpen.selector);
        executor.cancelMandateWithBillerSignature(unopened, 6, deadline, unopenedSignature);
        assertFalse(executor.cancellationNonceUsed(biller, 6));
    }

    function test_CancelledMandateRejectsFreshSignedCancellationWithoutConsumingNonce() public {
        IFixedMandate.Mandate memory cancelledMandate = _openMandate(_defaultMandate(67));
        vm.prank(payer);
        executor.cancelMandateAsPayer(cancelledMandate);

        uint256 cancelNonce = type(uint256).max;
        uint256 deadline = START + 1 hours;
        bytes memory failedSignature =
            _signCancel(billerPk, executor.mandateId(cancelledMandate), biller, cancelNonce, deadline);
        vm.expectRevert(IFixedMandate.MandateCancelled.selector);
        executor.cancelMandateWithBillerSignature(cancelledMandate, cancelNonce, deadline, failedSignature);
        assertFalse(executor.cancellationNonceUsed(biller, cancelNonce), "failed cancellation rolls nonce back");

        IFixedMandate.Mandate memory openMandate = _openMandate(_defaultMandate(68));
        bytes memory retrySignature =
            _signCancel(billerPk, executor.mandateId(openMandate), biller, cancelNonce, deadline);
        executor.cancelMandateWithBillerSignature(openMandate, cancelNonce, deadline, retrySignature);
        assertTrue(executor.cancellationNonceUsed(biller, cancelNonce), "rolled-back nonce remains usable");
    }

    function test_CancellationBlocksAccruedAndFuturePayments() public {
        IFixedMandate.Mandate memory mandate = _openMandate(_defaultMandate(59));
        vm.warp(START + 5 * PERIOD);
        vm.prank(biller);
        executor.cancelMandateAsBiller(mandate);
        vm.expectRevert(IFixedMandate.MandateCancelled.selector);
        executor.settle(mandate, 0);
        vm.expectRevert(IFixedMandate.MandateCancelled.selector);
        executor.unlockedPaymentCount(mandate);
        vm.warp(START + 10 * PERIOD);
        vm.expectRevert(IFixedMandate.MandateCancelled.selector);
        executor.settle(mandate, 0);
    }

    function test_SettlementAndCancellationRespectTransactionOrdering() public {
        IFixedMandate.Mandate memory settleFirst = _openMandate(_defaultMandate(60));
        executor.settle(settleFirst, 0);
        vm.prank(payer);
        executor.cancelMandateAsPayer(settleFirst);
        (,,, uint256 settledCount) = executor.mandateStates(executor.mandateId(settleFirst));
        assertEq(settledCount, 1, "ordered settlement retained");

        IFixedMandate.Mandate memory cancelFirst = _openMandate(_defaultMandate(61));
        vm.prank(payer);
        executor.cancelMandateAsPayer(cancelFirst);
        vm.expectRevert(IFixedMandate.MandateCancelled.selector);
        executor.settle(cancelFirst, 0);
    }

    function test_CompactCancellationSignatureWorksAtDeadline() public {
        IFixedMandate.Mandate memory mandate = _openMandate(_defaultMandate(62));
        bytes32 id = executor.mandateId(mandate);
        uint256 deadline = START + 1 hours;
        vm.warp(deadline);
        bytes memory signature = _compact(_signCancel(billerPk, id, biller, 8, deadline));
        vm.recordLogs();
        vm.prank(other);
        executor.cancelMandateWithBillerSignature(mandate, 8, deadline, signature);
        vm.snapshotGasLastCall("FixedMandate", "cancelMandate.biller.signature.compact");
        _assertSignedCancellationLogs(vm.getRecordedLogs(), id, payer, biller, 8);
        (, bool cancelled,,) = executor.mandateStates(id);
        assertTrue(cancelled);
    }

    function test_SharedOwnerERC1271CancellationCannotReplayAcrossRoles() public {
        address sharedOwner = makeAddr("sharedOwner");
        uint256 sharedOwnerPk = 0x5151;
        sharedOwner = vm.addr(sharedOwnerPk);
        MockERC1271Wallet payerWallet = new MockERC1271Wallet(sharedOwner);
        MockERC1271Wallet billerWallet = new MockERC1271Wallet(sharedOwner);
        IFixedMandate.Mandate memory mandate = _defaultMandate(63);
        mandate.payer = address(payerWallet);
        mandate.biller = address(billerWallet);
        uint256 deadline = START + 1 hours;
        executor.openMandate(
            mandate,
            deadline,
            deadline,
            _sign(sharedOwnerPk, executor.hashMandateAuthorization(mandate, deadline)),
            _sign(sharedOwnerPk, executor.hashMandateAcceptance(mandate, deadline))
        );

        bytes32 id = executor.mandateId(mandate);
        bytes memory payerSignature =
            _sign(sharedOwnerPk, executor.hashCancellation(id, address(payerWallet), 9, deadline));
        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.cancelMandateWithBillerSignature(mandate, 9, deadline, payerSignature);
        assertFalse(executor.cancellationNonceUsed(address(billerWallet), 9));

        bytes memory billerSignature =
            _sign(sharedOwnerPk, executor.hashCancellation(id, address(billerWallet), 9, deadline));
        executor.cancelMandateWithBillerSignature(mandate, 9, deadline, billerSignature);
        vm.snapshotGasLastCall("FixedMandate", "cancelMandate.biller.signature.erc1271");
        (, bool cancelled,,) = executor.mandateStates(id);
        assertTrue(cancelled, "ERC-1271 biller cancelled mandate");
        assertTrue(executor.cancellationNonceUsed(address(billerWallet), 9), "ERC-1271 cancellation nonce used");
    }

    function test_CancellationNonceEventsIncludeZeroAndUintMaxForBothRoles() public {
        _assertCancellationNonceEvent(false, 100, 0, 0);
        _assertCancellationNonceEvent(false, 101, type(uint256).max, 0);
        _assertCancellationNonceEvent(true, 102, 0, 0);
        _assertCancellationNonceEvent(true, 103, type(uint256).max, 0);
    }

    function test_CancellationNonceEventsRemainIndependentOfOpeningNonces() public {
        _assertCancellationNonceEvent(false, 104, 104, 0);
        _assertCancellationNonceEvent(true, 105, 105, 0);
    }

    function test_ERC1271CancellationNonceEventsIdentifyWalletNotOwnerOrRelayer() public {
        uint256 ownerPk = 0x5151;
        address owner = vm.addr(ownerPk);
        address payerWallet = address(new MockERC1271Wallet(owner));
        address billerWallet = address(new MockERC1271Wallet(owner));
        uint256 deadline = START + 1 hours;
        uint256 cancelNonce = 7;

        for (uint256 i; i < 2; ++i) {
            IFixedMandate.Mandate memory mandate = _defaultMandate(100 + i);
            mandate.payer = payerWallet;
            mandate.biller = billerWallet;
            executor.openMandate(
                mandate,
                deadline,
                deadline,
                _signAuthorization(ownerPk, mandate, deadline),
                _signAcceptance(ownerPk, mandate, deadline)
            );
            bytes32 id = executor.mandateId(mandate);
            bool asBiller = i == 1;
            address authorizer = asBiller ? billerWallet : payerWallet;
            bytes memory signature = _signCancel(ownerPk, id, authorizer, cancelNonce, deadline);

            vm.recordLogs();
            vm.prank(other);
            _cancelWithSignature(mandate, asBiller, cancelNonce, deadline, signature);
            _assertSignedCancellationLogs(vm.getRecordedLogs(), id, payerWallet, authorizer, cancelNonce);
            assertTrue(executor.cancellationNonceUsed(authorizer, cancelNonce), "wallet nonce consumed");
            assertFalse(executor.cancellationNonceUsed(owner, cancelNonce), "owner nonce untouched");
            assertFalse(executor.cancellationNonceUsed(other, cancelNonce), "relayer nonce untouched");
        }
    }

    function test_FailedPayerSignatureCancellationsDoNotConsumeNonce() public {
        _assertFailedSignedCancellations(false);
    }

    function test_FailedBillerSignatureCancellationsDoNotConsumeNonce() public {
        _assertFailedSignedCancellations(true);
    }

    // Transfer failures and reentrancy

    function test_InsufficientBalanceAndAllowanceRollBackPaymentCount() public {
        MockERC20 freshToken = new MockERC20();
        IFixedMandate.Mandate memory mandate = _defaultMandate(70);
        mandate.token = address(freshToken);
        mandate = _openMandate(mandate);

        vm.expectRevert(bytes("ALLOWANCE"));
        executor.settle(mandate, 0);
        (,,, uint256 countAfterAllowanceFailure) = executor.mandateStates(executor.mandateId(mandate));
        assertEq(countAfterAllowanceFailure, 0);

        vm.prank(payer);
        freshToken.approve(address(executor), AMOUNT);
        vm.expectRevert(bytes("BALANCE"));
        executor.settle(mandate, 0);
        (,,, uint256 countAfterBalanceFailure) = executor.mandateStates(executor.mandateId(mandate));
        assertEq(countAfterBalanceFailure, 0);

        freshToken.mint(payer, AMOUNT);
        executor.settle(mandate, 0);
        assertEq(freshToken.balanceOf(recipient), AMOUNT, "retry succeeds");
    }

    function test_FalseReturnAndNoCodeTokensRevertWithoutConsumingPayment() public {
        FalseReturnMockERC20 falseToken = new FalseReturnMockERC20();
        IFixedMandate.Mandate memory falseMandate = _defaultMandate(71);
        falseMandate.token = address(falseToken);
        falseMandate = _openMandate(falseMandate);
        falseToken.mint(payer, AMOUNT);
        vm.prank(payer);
        falseToken.approve(address(executor), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(falseToken)));
        executor.settle(falseMandate, 0);
        (,,, uint256 falseCount) = executor.mandateStates(executor.mandateId(falseMandate));
        assertEq(falseCount, 0);

        IFixedMandate.Mandate memory noCodeMandate = _defaultMandate(72);
        noCodeMandate.token = makeAddr("no-code-token");
        noCodeMandate = _openMandate(noCodeMandate);
        vm.expectRevert(abi.encodeWithSelector(Address.AddressEmptyCode.selector, noCodeMandate.token));
        executor.settle(noCodeMandate, 0);
        (,,, uint256 noCodeCount) = executor.mandateStates(executor.mandateId(noCodeMandate));
        assertEq(noCodeCount, 0);
    }

    function test_NoReturnTokenIsSupported() public {
        NoReturnMockERC20 noReturnToken = new NoReturnMockERC20();
        IFixedMandate.Mandate memory mandate = _defaultMandate(73);
        mandate.token = address(noReturnToken);
        mandate = _openMandate(mandate);
        noReturnToken.mint(payer, AMOUNT);
        vm.prank(payer);
        noReturnToken.approve(address(executor), AMOUNT);
        executor.settle(mandate, 0);
        assertEq(noReturnToken.balanceOf(recipient), AMOUNT);
    }

    function test_UnsupportedTokenEconomicsRemainExplicit() public {
        FeeOnTransferMockERC20 feeToken = new FeeOnTransferMockERC20();
        IFixedMandate.Mandate memory feeMandate = _defaultMandate(74);
        feeMandate.token = address(feeToken);
        feeMandate = _openMandate(feeMandate);
        feeToken.mint(payer, AMOUNT);
        vm.prank(payer);
        feeToken.approve(address(executor), AMOUNT);
        executor.settle(feeMandate, 0);
        uint256 transferFee = AMOUNT / 100;
        assertEq(feeToken.balanceOf(payer), 0, "fee token debits the nominal amount");
        assertEq(feeToken.balanceOf(recipient), AMOUNT - transferFee, "fee token credits below nominal");

        ExcessiveDebitMockERC20 debitToken = new ExcessiveDebitMockERC20(1e6);
        IFixedMandate.Mandate memory debitMandate = _defaultMandate(75);
        debitMandate.token = address(debitToken);
        debitMandate = _openMandate(debitMandate);
        debitToken.mint(payer, AMOUNT + 1e6);
        vm.prank(payer);
        debitToken.approve(address(executor), AMOUNT);
        executor.settle(debitMandate, 0);
        assertEq(debitToken.balanceOf(payer), 0, "payer can be debited above nominal");
        assertEq(debitToken.balanceOf(recipient), AMOUNT, "recipient still receives the nominal amount");
    }

    function test_CallbackSubmitterCanSettleNextUnlockedOccurrence() public {
        ReentrantMockERC20 reentrantToken = new ReentrantMockERC20();
        IFixedMandate.Mandate memory mandate = _defaultMandate(91);
        mandate.token = address(reentrantToken);
        mandate.totalPayments = 2;
        mandate = _openMandate(mandate);
        reentrantToken.mint(payer, 2 * AMOUNT);
        vm.prank(payer);
        reentrantToken.approve(address(executor), 2 * AMOUNT);
        vm.warp(START + PERIOD);

        bytes memory callbackData = abi.encodeCall(IFixedMandate.settle, (mandate, 1));
        reentrantToken.configureCallback(address(executor), callbackData, 1, false);

        uint256 payerBefore = reentrantToken.balanceOf(payer);
        vm.recordLogs();
        vm.prank(other);
        executor.settle(mandate, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (,,, uint256 settledPaymentCount) = executor.mandateStates(executor.mandateId(mandate));
        assertEq(settledPaymentCount, 2, "outer and nested unlocked payments consumed");
        assertTrue(reentrantToken.callbackAttempted(), "callback attempted");
        assertTrue(reentrantToken.callbackSucceeded(), "next unlocked payment settled");
        assertEq(reentrantToken.transferFromCount(), 2, "one transfer per occurrence");
        assertEq(payerBefore - reentrantToken.balanceOf(payer), 2 * AMOUNT, "payer debited two payment amounts");
        assertEq(reentrantToken.balanceOf(recipient), 2 * AMOUNT, "recipient receives both payment amounts");
        assertEq(reentrantToken.balanceOf(other), 0, "outer submitter receives no funds");
        assertEq(reentrantToken.balanceOf(address(reentrantToken)), 0, "callback submitter receives no funds");
        _assertSettlementLogOrder(logs, executor.mandateId(mandate));

        vm.expectRevert(IFixedMandate.PaymentNotUnlocked.selector);
        executor.settle(mandate, 2);
    }

    function test_CallbackCannotReplayCurrentPaymentIndex() public {
        ReentrantMockERC20 reentrantToken = new ReentrantMockERC20();
        IFixedMandate.Mandate memory mandate = _defaultMandate(92);
        mandate.token = address(reentrantToken);
        mandate.totalPayments = 2;
        mandate = _openMandate(mandate);
        reentrantToken.mint(payer, 2 * AMOUNT);
        vm.prank(payer);
        reentrantToken.approve(address(executor), 2 * AMOUNT);
        vm.warp(START + PERIOD);

        bytes memory callbackData = abi.encodeCall(IFixedMandate.settle, (mandate, 0));
        reentrantToken.configureCallback(address(executor), callbackData, 1, false);
        vm.prank(other);
        executor.settle(mandate, 0);

        (,,, uint256 settledPaymentCount) = executor.mandateStates(executor.mandateId(mandate));
        assertEq(settledPaymentCount, 1, "replayed current index consumes nothing");
        assertTrue(reentrantToken.callbackAttempted(), "callback attempted");
        assertFalse(reentrantToken.callbackSucceeded(), "stale callback rejected");
        assertEq(
            bytes4(reentrantToken.callbackReturnData()),
            IFixedMandate.UnexpectedPaymentIndex.selector,
            "current index is stale during callback"
        );
        assertEq(reentrantToken.balanceOf(recipient), AMOUNT, "only outer occurrence paid");

        executor.settle(mandate, 1);
        (,,, settledPaymentCount) = executor.mandateStates(executor.mandateId(mandate));
        assertEq(settledPaymentCount, 2, "next index remains available");
    }

    function test_CallbackCannotRedirectPayment() public {
        ReentrantMockERC20 reentrantToken = new ReentrantMockERC20();
        IFixedMandate.Mandate memory mandate = _defaultMandate(93);
        mandate.token = address(reentrantToken);
        mandate.totalPayments = 2;
        mandate = _openMandate(mandate);
        reentrantToken.mint(payer, 2 * AMOUNT);
        vm.prank(payer);
        reentrantToken.approve(address(executor), 2 * AMOUNT);
        vm.warp(START + PERIOD);

        IFixedMandate.Mandate memory redirected = _defaultMandate(93);
        redirected.token = address(reentrantToken);
        redirected.totalPayments = 2;
        redirected.recipient = other;
        bytes memory callbackData = abi.encodeCall(IFixedMandate.settle, (redirected, 1));
        reentrantToken.configureCallback(address(executor), callbackData, 1, false);
        vm.prank(other);
        executor.settle(mandate, 0);

        (,,, uint256 settledPaymentCount) = executor.mandateStates(executor.mandateId(mandate));
        (bool redirectedOpened,,, uint256 redirectedCount) = executor.mandateStates(executor.mandateId(redirected));
        assertEq(settledPaymentCount, 1, "only original occurrence consumed");
        assertFalse(redirectedOpened, "redirected mandate is not open");
        assertEq(redirectedCount, 0, "redirected mandate state unchanged");
        assertFalse(reentrantToken.callbackSucceeded(), "redirected callback rejected");
        assertEq(bytes4(reentrantToken.callbackReturnData()), IFixedMandate.MandateNotOpen.selector);
        assertEq(reentrantToken.balanceOf(recipient), AMOUNT, "pinned recipient paid");
        assertEq(reentrantToken.balanceOf(other), 0, "replacement recipient and submitter receive nothing");
    }

    function test_OuterTransferFailureRollsBackNestedStateAndEvents() public {
        ReentrantMockERC20 reentrantToken = new ReentrantMockERC20();
        IFixedMandate.Mandate memory mandate = _defaultMandate(94);
        mandate.token = address(reentrantToken);
        mandate.totalPayments = 2;
        mandate = _openMandate(mandate);
        reentrantToken.mint(payer, 2 * AMOUNT);
        vm.prank(payer);
        reentrantToken.approve(address(executor), 2 * AMOUNT);
        vm.warp(START + PERIOD);

        bytes memory callbackData = abi.encodeCall(IFixedMandate.settle, (mandate, 1));
        reentrantToken.configureCallback(address(executor), callbackData, 1, true);
        uint256 allowanceBefore = reentrantToken.allowance(payer, address(executor));
        bytes32 id = executor.mandateId(mandate);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(reentrantToken)));
        executor.settle(mandate, 0);

        // The exact SafeERC20 failure is returned only after the nested settlement succeeds. The enclosing
        // revert atomically discards both PaymentSettled logs together with the state and token effects below.
        (,,, uint256 settledPaymentCount) = executor.mandateStates(id);
        assertEq(settledPaymentCount, 0, "outer failure rolls back both counts");
        assertEq(reentrantToken.balanceOf(payer), 2 * AMOUNT, "payer debit rolled back");
        assertEq(reentrantToken.balanceOf(recipient), 0, "recipient credits rolled back");
        assertEq(reentrantToken.balanceOf(other), 0, "outer submitter receives nothing");
        assertEq(reentrantToken.balanceOf(address(reentrantToken)), 0, "callback submitter receives nothing");
        assertEq(reentrantToken.allowance(payer, address(executor)), allowanceBefore, "allowance rolled back");
        assertEq(reentrantToken.transferFromCount(), 0, "token transfer state rolled back");
    }

    // Fuzz coverage

    function testFuzz_FirstPaymentAtIsBoundByBothParties(uint256 signedTimestamp, uint256 submittedTimestamp) public {
        vm.assume(signedTimestamp != submittedTimestamp);
        _assertFirstPaymentAtSignaturesBound(signedTimestamp, submittedTimestamp);
    }

    function testFuzz_UnlockedCountMatchesExplicitSchedule(
        uint256 rawFirstPaymentAt,
        uint256 rawTimestamp,
        uint256 rawPeriod,
        uint256 total
    ) public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(101);
        mandate.firstPaymentAt = bound(rawFirstPaymentAt, 1, type(uint256).max);
        mandate.periodLength = bound(rawPeriod, 1, type(uint256).max);
        mandate.totalPayments = total;
        _openMandate(mandate);
        uint256 timestamp = bound(rawTimestamp, START, type(uint256).max);
        vm.warp(timestamp);

        uint256 expected;
        if (timestamp >= mandate.firstPaymentAt) {
            // A nonzero explicit anchor leaves room for the inclusive first occurrence.
            expected = (timestamp - mandate.firstPaymentAt) / mandate.periodLength + 1;
            if (total != 0 && expected > total) expected = total;
        }
        assertEq(executor.unlockedPaymentCount(mandate), expected);
    }

    function testFuzz_PayerCancellationEmitsConsumedNonce(uint256 cancelNonce, uint8 signatureFormat) public {
        _assertCancellationNonceEvent(false, 100, cancelNonce, signatureFormat % 3);
    }

    function testFuzz_BillerCancellationEmitsConsumedNonce(uint256 cancelNonce, uint8 signatureFormat) public {
        _assertCancellationNonceEvent(true, 100, cancelNonce, signatureFormat % 3);
    }

    function testFuzz_OpeningStoresSupportedChainTimestamp(uint64 rawTimestamp) public {
        uint256 timestamp = uint256(rawTimestamp);
        vm.warp(timestamp);
        IFixedMandate.Mandate memory mandate = _defaultMandate(84);
        bytes32 id = executor.mandateId(mandate);

        bytes32 returnedId = executor.openMandate(
            mandate,
            timestamp,
            timestamp,
            _signAuthorization(payerPk, mandate, timestamp),
            _signAcceptance(billerPk, mandate, timestamp)
        );

        assertEq(returnedId, id, "returned mandate id");
        (bool opened, bool cancelled, uint256 startedAt, uint256 settledCount) = executor.mandateStates(id);
        assertTrue(opened, "mandate opened");
        assertFalse(cancelled, "mandate not cancelled");
        assertEq(startedAt, timestamp, "supported chain timestamp stored exactly");
        assertEq(settledCount, 0, "no payment settled");
        assertEq(executor.unlockedPaymentCount(mandate), 1, "first payment immediately unlocked");
    }

    function testFuzz_UnlockedCountMatchesSchedule(uint256 rawPeriod, uint64 rawElapsed, uint256 total) public {
        uint256 period = bound(rawPeriod, 1, type(uint256).max);
        uint256 elapsed = uint256(rawElapsed);
        IFixedMandate.Mandate memory mandate = _defaultMandate(80);
        mandate.periodLength = period;
        mandate.totalPayments = total;
        mandate = _openMandate(mandate);
        vm.warp(START + elapsed);

        uint256 expected = elapsed / period + 1;
        if (total != 0 && expected > total) expected = total;
        assertEq(executor.unlockedPaymentCount(mandate), expected);
    }

    function testFuzz_SettlementTransitionsMatchScheduleModel(
        uint64 rawPeriod,
        uint8 rawElapsedPeriods,
        uint8 rawTotalPayments,
        uint8 rawPrefix,
        uint64 rawRemainder
    ) public {
        uint256 period = bound(uint256(rawPeriod), 1, 365 days);
        uint256 elapsedPeriods = bound(uint256(rawElapsedPeriods), 0, 20);
        uint256 remainder = bound(uint256(rawRemainder), 0, period - 1);
        uint256 totalPayments = uint256(rawTotalPayments);
        IFixedMandate.Mandate memory mandate = _defaultMandate(83);
        mandate.periodLength = period;
        mandate.totalPayments = totalPayments;
        mandate = _openMandate(mandate);
        vm.warp(START + elapsedPeriods * period + remainder);

        uint256 unlocked = elapsedPeriods + 1;
        if (totalPayments != 0 && unlocked > totalPayments) unlocked = totalPayments;
        uint256 prefix = bound(uint256(rawPrefix), 0, unlocked);

        for (uint256 i; i < prefix; ++i) {
            vm.prank(other);
            executor.settle(mandate, i);
        }

        if (prefix != 0) {
            uint256 payerBalanceBefore = token.balanceOf(payer);
            uint256 recipientBalanceBefore = token.balanceOf(recipient);
            vm.expectRevert(IFixedMandate.UnexpectedPaymentIndex.selector);
            executor.settle(mandate, prefix - 1);
            assertEq(token.balanceOf(payer), payerBalanceBefore, "stale call leaves payer balance unchanged");
            assertEq(
                token.balanceOf(recipient), recipientBalanceBefore, "stale call leaves recipient balance unchanged"
            );
        }

        vm.expectRevert(IFixedMandate.UnexpectedPaymentIndex.selector);
        executor.settle(mandate, prefix + 1);

        for (uint256 i = prefix; i < unlocked; ++i) {
            vm.prank(other);
            executor.settle(mandate, i);
        }

        (,,, uint256 settledCount) = executor.mandateStates(executor.mandateId(mandate));
        assertEq(settledCount, unlocked, "all and only unlocked payments settle");
        assertEq(token.balanceOf(recipient), unlocked * AMOUNT, "one recipient credit per successful payment");
        assertEq(token.balanceOf(payer), 100_000e6 - unlocked * AMOUNT, "one payer debit per successful payment");

        uint256 payerBalanceBeforeLockedCall = token.balanceOf(payer);
        uint256 recipientBalanceBeforeLockedCall = token.balanceOf(recipient);
        vm.expectRevert(IFixedMandate.PaymentNotUnlocked.selector);
        executor.settle(mandate, unlocked);
        (,,, settledCount) = executor.mandateStates(executor.mandateId(mandate));
        assertEq(settledCount, unlocked, "locked call leaves count unchanged");
        assertEq(token.balanceOf(payer), payerBalanceBeforeLockedCall, "locked call leaves payer balance unchanged");
        assertEq(
            token.balanceOf(recipient),
            recipientBalanceBeforeLockedCall,
            "locked call leaves recipient balance unchanged"
        );
    }

    function test_UnlockedCountSaturatesAtUintMax() public {
        vm.warp(0);
        FixedMandate edgeExecutor = new FixedMandate();
        IFixedMandate.Mandate memory mandate = _defaultMandate(82);
        mandate.periodLength = 1;
        mandate.totalPayments = 0;
        edgeExecutor.openMandate(
            mandate,
            0,
            0,
            _sign(payerPk, edgeExecutor.hashMandateAuthorization(mandate, 0)),
            _sign(billerPk, edgeExecutor.hashMandateAcceptance(mandate, 0))
        );

        vm.warp(type(uint256).max);
        assertEq(edgeExecutor.unlockedPaymentCount(mandate), type(uint256).max);
    }

    function testFuzz_PermissionlessSettlementTransfersFullAmount(uint256 rawAmount) public {
        uint256 initialPayerBalance = token.balanceOf(payer);
        uint256 amount = bound(rawAmount, 1, type(uint256).max - initialPayerBalance);
        IFixedMandate.Mandate memory mandate = _defaultMandate(81);
        mandate.amountPerPayment = amount;
        mandate = _openMandate(mandate);
        token.mint(payer, amount);

        uint256 payerBefore = token.balanceOf(payer);
        uint256 submitterBefore = token.balanceOf(other);
        vm.prank(other);
        executor.settle(mandate, 0);
        assertEq(payerBefore - token.balanceOf(payer), amount, "payer debit");
        assertEq(token.balanceOf(recipient), amount, "recipient credit");
        assertEq(token.balanceOf(other), submitterBefore, "submitter receives no funds");
    }

    function testFuzz_SameNonceCannotOpenDifferentFixedMandates(uint256 nonce, bytes32 alternateTermsHash) public {
        vm.assume(alternateTermsHash != bytes32(0) && alternateTermsHash != TERMS_HASH);
        IFixedMandate.Mandate memory first = _defaultMandate(nonce);
        IFixedMandate.Mandate memory second = _defaultMandate(nonce);
        second.termsHash = alternateTermsHash;
        _openMandate(first);
        // Safe: shifting right by 8 leaves at most 248 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint248 wordPos = uint248(nonce >> 8);
        // Intentional: the low 8 bits select the bit inside the nonce bitmap word.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 bit = uint256(1) << uint8(nonce);
        assertEq(executor.nonceBitmap(payer, wordPos), bit, "exact full-width nonce bit consumed");

        uint256 deadline = START + 1 hours;
        bytes memory payerSignature = _signAuthorization(payerPk, second, deadline);
        bytes memory billerSignature = _signAcceptance(billerPk, second, deadline);
        vm.expectRevert(IUnorderedNonces.InvalidUnorderedNonce.selector);
        executor.openMandate(second, deadline, deadline, payerSignature, billerSignature);
        assertEq(executor.nonceBitmap(payer, wordPos), bit, "failed replay preserves the nonce bitmap");
    }

    // Helpers

    function _assertDeferredOpening(uint8 route) internal {
        IFixedMandate.Mandate memory mandate = _defaultMandate(101);
        mandate.firstPaymentAt = START + PERIOD;
        uint256 deadline = START + 1 hours;
        bytes memory payerSignature = _signAuthorization(payerPk, mandate, deadline);
        bytes memory billerSignature = _signAcceptance(billerPk, mandate, deadline);
        bytes32 id = executor.mandateId(mandate);

        vm.expectEmit(true, true, true, true, address(executor));
        emit IFixedMandate.MandateOpened(
            id,
            payer,
            biller,
            address(token),
            recipient,
            AMOUNT,
            PERIOD,
            mandate.firstPaymentAt,
            12,
            START,
            mandate.nonce,
            TERMS_HASH
        );
        bytes32 returnedId;
        if (route == 0) {
            vm.prank(other);
            returnedId = executor.openMandate(mandate, deadline, deadline, payerSignature, billerSignature);
        } else if (route == 1) {
            vm.prank(payer);
            returnedId = executor.openMandateAsPayer(mandate, deadline, billerSignature);
        } else {
            vm.prank(biller);
            returnedId = executor.openMandateAsBiller(mandate, deadline, payerSignature);
        }

        assertEq(returnedId, id);
        (bool opened, bool cancelled, uint256 startedAt, uint256 settledCount) = executor.mandateStates(id);
        assertTrue(opened);
        assertFalse(cancelled);
        assertEq(startedAt, START, "opening time differs from first payment time");
        assertEq(settledCount, 0);
        assertEq(executor.nonceBitmap(payer, 0), uint256(1) << mandate.nonce);
        assertEq(executor.unlockedPaymentCount(mandate), 0);
        vm.expectRevert(IFixedMandate.PaymentNotUnlocked.selector);
        executor.settle(mandate, 0);
        (,,, settledCount) = executor.mandateStates(id);
        assertEq(settledCount, 0, "early settlement does not consume a payment");
        assertEq(token.balanceOf(payer), 100_000e6);
        assertEq(token.balanceOf(recipient), 0);
    }

    function _assertFirstPaymentAtSignaturesBound(uint256 signedTimestamp, uint256 submittedTimestamp) internal {
        IFixedMandate.Mandate memory mandate = _defaultMandate(101);
        mandate.firstPaymentAt = signedTimestamp;
        uint256 deadline = START + 1 hours;
        bytes32 originalId = executor.mandateId(mandate);
        bytes memory payerSignature = _signAuthorization(payerPk, mandate, deadline);
        bytes memory billerSignature = _signAcceptance(billerPk, mandate, deadline);
        mandate.firstPaymentAt = submittedTimestamp;
        assertNotEq(executor.mandateId(mandate), originalId, "timestamp binds mandate identity");
        bytes memory freshPayerSignature = _signAuthorization(payerPk, mandate, deadline);
        bytes memory freshBillerSignature = _signAcceptance(billerPk, mandate, deadline);

        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandate(mandate, deadline, deadline, payerSignature, freshBillerSignature);
        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandate(mandate, deadline, deadline, freshPayerSignature, billerSignature);
        vm.prank(biller);
        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandateAsBiller(mandate, deadline, payerSignature);
        vm.prank(payer);
        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandateAsPayer(mandate, deadline, billerSignature);

        (bool opened,,,) = executor.mandateStates(executor.mandateId(mandate));
        assertFalse(opened);
        assertEq(executor.nonceBitmap(payer, 0), 0, "rejected signatures leave nonce available");
    }

    function _defaultMandate(uint256 nonce) internal view returns (IFixedMandate.Mandate memory mandate) {
        mandate = IFixedMandate.Mandate({
            payer: payer,
            biller: biller,
            recipient: recipient,
            token: address(token),
            amountPerPayment: AMOUNT,
            periodLength: PERIOD,
            firstPaymentAt: 0,
            totalPayments: 12,
            termsHash: TERMS_HASH,
            nonce: nonce
        });
    }

    function _openMandate(IFixedMandate.Mandate memory mandate) internal returns (IFixedMandate.Mandate memory) {
        uint256 deadline = block.timestamp + 1 hours;
        executor.openMandate(
            mandate,
            deadline,
            deadline,
            _signAuthorization(payerPk, mandate, deadline),
            _signAcceptance(billerPk, mandate, deadline)
        );
        return mandate;
    }

    function _expectInvalidMandate(IFixedMandate.Mandate memory mandate) internal {
        vm.expectRevert(IFixedMandate.InvalidMandate.selector);
        executor.openMandate(mandate, START + 1 hours, START + 1 hours, hex"", hex"");
    }

    function _assertSettlementLogOrder(Vm.Log[] memory logs, bytes32 expectedMandateId) internal view {
        uint256 settlementLogCount;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(executor) || logs[i].topics.length == 0
                    || logs[i].topics[0] != PAYMENT_SETTLED_TOPIC
            ) continue;

            assertEq(logs[i].topics[1], expectedMandateId, "settlement log mandate id");
            assertEq(uint256(logs[i].topics[2]), settlementLogCount, "settlement logs follow payment index order");
            ++settlementLogCount;
        }
        assertEq(settlementLogCount, 2, "outer and nested settlement logs emitted");
    }

    function _assertSingleExecutorLogTopic(Vm.Log[] memory logs, bytes32 expectedTopic) internal view {
        uint256 matchingLogs;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(executor)) continue;
            assertGt(logs[i].topics.length, 0, "executor log has a topic");
            assertEq(logs[i].topics[0], expectedTopic, "canonical executor event topic");
            ++matchingLogs;
        }
        assertEq(matchingLogs, 1, "exactly one executor event");
    }

    function _assertSignedCancellationLogs(
        Vm.Log[] memory logs,
        bytes32 id,
        address expectedPayer,
        address authorizer,
        uint256 cancelNonce
    ) internal view {
        assertEq(logs.length, 2, "exactly one nonce event and one cancellation event");
        assertEq(logs[0].emitter, address(executor), "nonce event emitter");
        assertEq(logs[0].topics.length, 3, "indexed authorizer and cancellation nonce");
        assertEq(logs[0].topics[0], CANCELLATION_NONCE_CONSUMED_TOPIC, "nonce event precedes cancellation");
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(authorizer))), "nonce event authorizer");
        assertEq(logs[0].topics[2], bytes32(cancelNonce), "nonce event cancellation nonce");
        assertEq(logs[0].data.length, 0, "nonce event has no unindexed fields");

        assertEq(logs[1].emitter, address(executor), "cancellation event emitter");
        assertEq(logs[1].topics.length, 4, "existing cancellation event indexing unchanged");
        assertEq(logs[1].topics[0], MANDATE_CANCELLATION_TOPIC, "existing cancellation event topic unchanged");
        assertEq(logs[1].topics[1], id, "cancellation event mandate id");
        assertEq(logs[1].topics[2], bytes32(uint256(uint160(expectedPayer))), "cancellation event payer");
        assertEq(logs[1].topics[3], bytes32(uint256(uint160(authorizer))), "cancellation event authorizer");
        assertEq(logs[1].data.length, 0, "existing cancellation event data unchanged");
    }

    function _assertCancellationNonceEvent(bool asBiller, uint256 openingNonce, uint256 cancelNonce, uint8 format)
        internal
    {
        IFixedMandate.Mandate memory mandate = _openMandate(_defaultMandate(openingNonce));
        bytes32 id = executor.mandateId(mandate);
        address authorizer = asBiller ? biller : payer;
        uint256 deadline = START + 1 hours;
        bytes memory signature = _signCancel(asBiller ? billerPk : payerPk, id, authorizer, cancelNonce, deadline);
        if (format == 1) signature = _compact(signature);
        if (format == 2) signature = _zeroOneV(signature);

        vm.recordLogs();
        vm.prank(other);
        _cancelWithSignature(mandate, asBiller, cancelNonce, deadline, signature);
        _assertSignedCancellationLogs(vm.getRecordedLogs(), id, payer, authorizer, cancelNonce);
        assertTrue(executor.cancellationNonceUsed(authorizer, cancelNonce), "emitted nonce consumed");
        assertFalse(executor.cancellationNonceUsed(other, cancelNonce), "relayer nonce untouched");
        (, bool cancelled,,) = executor.mandateStates(id);
        assertTrue(cancelled, "mandate cancelled");
    }

    function _assertFailedSignedCancellations(bool asBiller) internal {
        IFixedMandate.Mandate memory mandate = _defaultMandate(100);
        bytes32 id = executor.mandateId(mandate);
        address authorizer = asBiller ? biller : payer;
        uint256 deadline = START + 1 hours;
        uint256 cancelNonce = 7;

        vm.warp(deadline + 1);
        vm.recordLogs();
        vm.expectRevert(IFixedMandate.SignatureExpired.selector);
        _cancelWithSignature(mandate, asBiller, cancelNonce, deadline, hex"");
        assertEq(vm.getRecordedLogs().length, 0, "expired signature emits nothing");
        assertFalse(executor.cancellationNonceUsed(authorizer, cancelNonce), "expired signature preserves nonce");

        vm.warp(deadline);
        {
            bytes memory wrongSignature = _signCancel(otherPk, id, authorizer, cancelNonce, deadline);
            vm.recordLogs();
            vm.expectRevert(IFixedMandate.InvalidSignature.selector);
            _cancelWithSignature(mandate, asBiller, cancelNonce, deadline, wrongSignature);
            assertEq(vm.getRecordedLogs().length, 0, "unauthorized signature emits nothing");
            assertFalse(
                executor.cancellationNonceUsed(authorizer, cancelNonce), "unauthorized signature preserves nonce"
            );
        }

        vm.recordLogs();
        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        _cancelWithSignature(mandate, asBiller, cancelNonce, deadline, hex"1234");
        assertEq(vm.getRecordedLogs().length, 0, "malformed signature emits nothing");
        assertFalse(executor.cancellationNonceUsed(authorizer, cancelNonce), "malformed signature preserves nonce");

        // These failures occur after the nonce write and emit. The enclosing revert discards both.
        bytes memory signature = _signCancel(asBiller ? billerPk : payerPk, id, authorizer, cancelNonce, deadline);
        vm.expectRevert(IFixedMandate.MandateNotOpen.selector);
        _cancelWithSignature(mandate, asBiller, cancelNonce, deadline, signature);
        assertFalse(executor.cancellationNonceUsed(authorizer, cancelNonce), "unopened mandate rolls nonce back");
        (bool opened, bool cancelled,,) = executor.mandateStates(id);
        assertFalse(opened, "failed cancellation does not open mandate");
        assertFalse(cancelled, "failed cancellation does not cancel mandate");

        _openMandate(mandate);
        vm.prank(payer);
        executor.cancelMandateAsPayer(mandate);
        vm.expectRevert(IFixedMandate.MandateCancelled.selector);
        _cancelWithSignature(mandate, asBiller, cancelNonce, deadline, signature);
        assertFalse(executor.cancellationNonceUsed(authorizer, cancelNonce), "cancelled mandate rolls nonce back");

        // The rolled-back nonce remains usable and observable on another mandate.
        _assertCancellationNonceEvent(asBiller, 101, cancelNonce, 0);
    }

    function _cancelWithSignature(
        IFixedMandate.Mandate memory mandate,
        bool asBiller,
        uint256 cancelNonce,
        uint256 deadline,
        bytes memory signature
    ) internal {
        if (asBiller) {
            executor.cancelMandateWithBillerSignature(mandate, cancelNonce, deadline, signature);
        } else {
            executor.cancelMandateWithPayerSignature(mandate, cancelNonce, deadline, signature);
        }
    }

    function _signAuthorization(uint256 privateKey, IFixedMandate.Mandate memory mandate, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(privateKey, executor.hashMandateAuthorization(mandate, deadline));
    }

    function _signAcceptance(uint256 privateKey, IFixedMandate.Mandate memory mandate, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(privateKey, executor.hashMandateAcceptance(mandate, deadline));
    }

    function _signCancel(uint256 privateKey, bytes32 id, address authorizer, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(privateKey, executor.hashCancellation(id, authorizer, nonce, deadline));
    }

    function _sign(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory signature) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _compact(bytes memory signature) internal pure returns (bytes memory compactSignature) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        bytes32 vs = bytes32(uint256(s) | (uint256(v - 27) << 255));
        return abi.encodePacked(r, vs);
    }

    function _zeroOneV(bytes memory signature) internal pure returns (bytes memory normalized) {
        normalized = signature;
        normalized[64] = bytes1(uint8(normalized[64]) - 27);
    }

    function _canonicalMandateStructHash(IFixedMandate.Mandate memory mandate) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "Mandate(address payer,address biller,address recipient,address token,uint256 amountPerPayment,uint256 periodLength,uint256 firstPaymentAt,uint256 totalPayments,bytes32 termsHash,uint256 nonce)"
                ),
                mandate.payer,
                mandate.biller,
                mandate.recipient,
                mandate.token,
                mandate.amountPerPayment,
                mandate.periodLength,
                mandate.firstPaymentAt,
                mandate.totalPayments,
                mandate.termsHash,
                mandate.nonce
            )
        );
    }

    function _eip712Digest(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
