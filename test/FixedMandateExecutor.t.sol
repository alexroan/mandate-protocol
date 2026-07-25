// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {FixedMandate} from "../src/FixedMandate.sol";
import {IFixedMandate} from "../src/interfaces/IFixedMandate.sol";
import {IUnorderedNonces} from "../src/interfaces/IUnorderedNonces.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
    uint256 internal constant GROSS = 100e6;
    bytes32 internal constant TERMS_HASH = keccak256("fixed mandate terms v1");
    bytes32 internal constant MANDATE_OPENED_TOPIC = 0xad55e3a0d6b405d919cd1a8df033438d18034f6c46362cd15ff991b4a3a7bd36;
    bytes32 internal constant PAYMENT_SETTLED_TOPIC =
        0x1a59d7c424c7fbdd31c69bc31da5998120dbc69c9c4aecb3147453276e44ba5c;
    bytes32 internal constant MANDATE_CANCELLATION_TOPIC =
        0x328bb2c80907ff47c3ec6cf730d8843d943244db438a643c4d9f64c93e1cccb2;

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
                                "MandateAuthorization(Mandate mandate,uint256 signatureDeadline)Mandate(address payer,address biller,address recipient,address token,uint256 payerGrossPerPayment,uint256 periodLength,uint256 totalPayments,bytes32 termsHash,uint256 nonce)"
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
                                "MandateAcceptance(Mandate mandate,uint256 signatureDeadline)Mandate(address payer,address biller,address recipient,address token,uint256 payerGrossPerPayment,uint256 periodLength,uint256 totalPayments,bytes32 termsHash,uint256 nonce)"
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
        assertEq(IFixedMandate.openMandate.selector, bytes4(0xb16358f8), "openMandate");
        assertEq(IFixedMandate.openMandateAsPayer.selector, bytes4(0x9d4c6e63), "openMandateAsPayer");
        assertEq(IFixedMandate.openMandateAsBiller.selector, bytes4(0xe6b6a2d9), "openMandateAsBiller");
        assertEq(IFixedMandate.settle.selector, bytes4(0x6ebdc6c5), "settle");
        assertEq(IFixedMandate.cancelMandateAsPayer.selector, bytes4(0x98b2c5e1), "cancelMandateAsPayer");
        assertEq(IFixedMandate.cancelMandateAsBiller.selector, bytes4(0x1b450796), "cancelMandateAsBiller");
        assertEq(
            IFixedMandate.cancelMandateWithPayerSignature.selector,
            bytes4(0x74187f97),
            "cancelMandateWithPayerSignature"
        );
        assertEq(
            IFixedMandate.cancelMandateWithBillerSignature.selector,
            bytes4(0xf0929b08),
            "cancelMandateWithBillerSignature"
        );
        assertEq(IFixedMandate.mandateId.selector, bytes4(0xa316420a), "mandateId");
        assertEq(IFixedMandate.hashMandateAuthorization.selector, bytes4(0x0575347b), "hashMandateAuthorization");
        assertEq(IFixedMandate.hashMandateAcceptance.selector, bytes4(0x138e4cf3), "hashMandateAcceptance");
        assertEq(IFixedMandate.unlockedPaymentCount.selector, bytes4(0xec3fd153), "unlockedPaymentCount");
        assertEq(IFixedMandate.hashCancellation.selector, bytes4(0x4fa747bf), "hashCancellation");
    }

    function test_EventTopicsMatchCanonicalSignatures() public pure {
        assertEq(
            MANDATE_OPENED_TOPIC,
            keccak256(
                "MandateOpened(bytes32,address,address,address,address,uint256,uint256,uint256,uint256,uint256,bytes32)"
            ),
            "MandateOpened"
        );
        assertEq(
            PAYMENT_SETTLED_TOPIC,
            keccak256("PaymentSettled(bytes32,uint256,address,address,address,address,uint256,address)"),
            "PaymentSettled"
        );
        assertEq(
            MANDATE_CANCELLATION_TOPIC, keccak256("MandateCancellation(bytes32,address,address)"), "MandateCancellation"
        );
    }

    function test_RevertWhen_SignaturesTargetAnotherFixedExecutor() public {
        FixedMandate otherExecutor = new FixedMandate();
        IFixedMandate.Mandate memory mandate = _defaultMandate(1);
        uint256 deadline = START + 1 hours;
        bytes memory payerSignature = _sign(payerPk, otherExecutor.hashMandateAuthorization(mandate, deadline));
        bytes memory billerSignature = _sign(billerPk, otherExecutor.hashMandateAcceptance(mandate, deadline));

        vm.expectRevert(IFixedMandate.InvalidSignature.selector);
        executor.openMandate(mandate, deadline, deadline, payerSignature, billerSignature);
    }

    function test_EveryCommercialFieldChangesMandateId() public view {
        IFixedMandate.Mandate memory base = _defaultMandate(3);
        bytes32 baseId = executor.mandateId(base);

        IFixedMandate.Mandate memory changed = _defaultMandate(3);
        changed.payer = other;
        assertNotEq(executor.mandateId(changed), baseId, "payer");
        changed = _defaultMandate(3);
        changed.biller = other;
        assertNotEq(executor.mandateId(changed), baseId, "biller");
        changed = _defaultMandate(3);
        changed.recipient = other;
        assertNotEq(executor.mandateId(changed), baseId, "recipient");
        changed = _defaultMandate(3);
        changed.token = other;
        assertNotEq(executor.mandateId(changed), baseId, "token");
        changed = _defaultMandate(3);
        changed.payerGrossPerPayment += 1;
        assertNotEq(executor.mandateId(changed), baseId, "gross");
        changed = _defaultMandate(3);
        changed.periodLength += 1;
        assertNotEq(executor.mandateId(changed), baseId, "period");
        changed = _defaultMandate(3);
        changed.totalPayments += 1;
        assertNotEq(executor.mandateId(changed), baseId, "total");
        changed = _defaultMandate(3);
        changed.termsHash = keccak256("changed terms");
        assertNotEq(executor.mandateId(changed), baseId, "terms");
        changed = _defaultMandate(4);
        assertNotEq(executor.mandateId(changed), baseId, "nonce");
    }

    function test_FixedExecutorRequiresAllowanceForItsOwnAddress() public {
        MockERC20 freshToken = new MockERC20();
        IFixedMandate.Mandate memory mandate = _defaultMandate(2);
        mandate.token = address(freshToken);
        mandate = _openMandate(mandate);
        freshToken.mint(payer, GROSS);

        vm.prank(payer);
        freshToken.approve(other, GROSS);
        vm.expectRevert(bytes("ALLOWANCE"));
        executor.settle(mandate, 0);

        vm.prank(payer);
        freshToken.approve(address(executor), GROSS);
        executor.settle(mandate, 0);
        assertEq(freshToken.balanceOf(recipient), GROSS, "fixed approval used");
    }

    // Opening

    function test_OpenMandateRequiresBothPartiesAndStoresGeneratedStart() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(10);
        bytes32 id = executor.mandateId(mandate);

        vm.expectEmit(true, true, true, true, address(executor));
        emit IFixedMandate.MandateOpened(
            id, payer, biller, address(token), recipient, GROSS, PERIOD, 12, START, mandate.nonce, TERMS_HASH
        );
        _openMandate(mandate);

        (bool opened, bool cancelled, uint256 startedAt, uint256 settledCount) = executor.mandateStates(id);
        assertTrue(opened, "opened");
        assertFalse(cancelled, "not cancelled");
        assertEq(startedAt, START, "generated start");
        assertEq(settledCount, 0, "no settled payment");
        assertEq(executor.unlockedPaymentCount(mandate), 1, "first payment unlocked");
    }

    function test_NeutralOpenerChoosesStartWithinSignatureDeadlines() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(11);
        uint256 deadline = START + 7 days;
        bytes memory payerSignature = _signAuthorization(payerPk, mandate, deadline);
        bytes memory billerSignature = _signAcceptance(billerPk, mandate, deadline);

        vm.warp(START + 3 days);
        vm.prank(other);
        executor.openMandate(mandate, deadline, deadline, payerSignature, billerSignature);
        vm.snapshotGasLastCall("FixedMandate", "openMandate.eoa.relayed");

        (,, uint256 startedAt,) = executor.mandateStates(executor.mandateId(mandate));
        assertEq(startedAt, START + 3 days, "submission anchors schedule");
    }

    function test_OpenMandateAsPayerUsesCallerAuthorityAndBillerAcceptance() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(12);
        uint256 deadline = START + 1 hours;
        bytes memory billerSignature = _signAcceptance(billerPk, mandate, deadline);
        vm.prank(payer);
        executor.openMandateAsPayer(mandate, deadline, billerSignature);
        vm.snapshotGasLastCall("FixedMandate", "openMandateAsPayer.eoa.direct");
        (bool opened,,,) = executor.mandateStates(executor.mandateId(mandate));
        assertTrue(opened, "payer opened");
    }

    function test_OpenMandateAsBillerUsesCallerAuthorityAndPayerAuthorization() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(13);
        uint256 deadline = START + 1 hours;
        bytes memory payerSignature = _signAuthorization(payerPk, mandate, deadline);
        vm.prank(biller);
        executor.openMandateAsBiller(mandate, deadline, payerSignature);
        vm.snapshotGasLastCall("FixedMandate", "openMandateAsBiller.eoa.direct");
        (bool opened,,,) = executor.mandateStates(executor.mandateId(mandate));
        assertTrue(opened, "biller opened");
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
        malformed.payerGrossPerPayment = 0;
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
        mandate.payerGrossPerPayment = 0;

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

        IFixedMandate.Mandate memory opened = _openMandate(_defaultMandate(21));
        deadline = START + 1 hours;
        bytes memory openedPayerSignature = _signAuthorization(payerPk, opened, deadline);
        bytes memory openedBillerSignature = _signAcceptance(billerPk, opened, deadline);
        vm.expectRevert(IFixedMandate.MandateAlreadyOpened.selector);
        executor.openMandate(opened, deadline, deadline, openedPayerSignature, openedBillerSignature);
    }

    function test_EIP2098CompactSignaturesCanOpenMandate() public {
        IFixedMandate.Mandate memory compactMandate = _defaultMandate(22);
        uint256 deadline = START + 1 hours;
        executor.openMandate(
            compactMandate,
            deadline,
            deadline,
            _compact(_signAuthorization(payerPk, compactMandate, deadline)),
            _compact(_signAcceptance(billerPk, compactMandate, deadline))
        );
        vm.snapshotGasLastCall("FixedMandate", "openMandate.eoa.compact");
    }

    function test_ZeroOneVSignaturesCanOpenMandate() public {
        IFixedMandate.Mandate memory zeroOneMandate = _defaultMandate(23);
        uint256 deadline = START + 1 hours;
        executor.openMandate(
            zeroOneMandate,
            deadline,
            deadline,
            _zeroOneV(_signAuthorization(payerPk, zeroOneMandate, deadline)),
            _zeroOneV(_signAcceptance(billerPk, zeroOneMandate, deadline))
        );
        vm.snapshotGasLastCall("FixedMandate", "openMandate.eoa.zeroOneV");
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
        executor.openMandate(
            payerMandate,
            deadline,
            deadline,
            _sign(payerPk, executor.hashMandateAuthorization(payerMandate, deadline)),
            _signAcceptance(billerPk, payerMandate, deadline)
        );
        vm.snapshotGasLastCall("FixedMandate", "openMandate.erc1271.payer");

        MockERC1271Wallet billerWallet = new MockERC1271Wallet(biller);
        IFixedMandate.Mandate memory billerMandate = _defaultMandate(25);
        billerMandate.biller = address(billerWallet);
        executor.openMandate(
            billerMandate,
            deadline,
            deadline,
            _signAuthorization(payerPk, billerMandate, deadline),
            _sign(billerPk, executor.hashMandateAcceptance(billerMandate, deadline))
        );
        vm.snapshotGasLastCall("FixedMandate", "openMandate.erc1271.biller");
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
        assertEq(token.balanceOf(recipient), GROSS, "recipient receives full gross");
        assertEq(token.balanceOf(address(billerWallet)), 0, "submitter receives no protocol funds");

        vm.prank(biller);
        vm.startSnapshotGas("FixedMandate", "cancelMandateAsBiller.wallet.endToEnd");
        billerWallet.execute(address(executor), cancelCallData);
        vm.stopSnapshotGas();
        (, bool cancelled,,) = executor.mandateStates(executor.mandateId(mandate));
        assertTrue(cancelled, "contract biller cancelled directly");
    }

    // Accrual and permissionless settlement

    function test_AnyCallerCanSettleAndRecipientReceivesFullGross() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(30);
        mandate = _openMandate(mandate);
        bytes32 id = executor.mandateId(mandate);

        vm.prank(other);
        executor.settle(mandate, 0);
        vm.snapshotGasLastCall("FixedMandate", "settle.permissionless.first");

        assertEq(token.balanceOf(recipient), GROSS, "recipient full gross");
        assertEq(token.balanceOf(other), 0, "submitter receives no protocol funds");
        assertEq(token.balanceOf(payer), 100_000e6 - GROSS, "payer gross");
        (,,, uint256 settledCount) = executor.mandateStates(id);
        assertEq(settledCount, 1, "one payment settled");
    }

    function test_SettlementSubmitterReceivesNoProtocolFunds() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(45);
        mandate = _openMandate(mandate);
        uint256 submitterBalanceBefore = token.balanceOf(other);

        vm.prank(other);
        executor.settle(mandate, 0);

        assertEq(token.balanceOf(other), submitterBalanceBefore, "submitter balance unchanged");
        assertEq(token.balanceOf(recipient), GROSS, "recipient receives full gross");
    }

    function test_PaymentSettledEmitsSubmitterAndNoFee() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(46);
        mandate = _openMandate(mandate);
        bytes32 id = executor.mandateId(mandate);

        vm.expectEmit(true, true, true, true, address(executor));
        emit IFixedMandate.PaymentSettled(id, 0, payer, biller, recipient, address(token), GROSS, other);
        vm.prank(other);
        executor.settle(mandate, 0);

        assertEq(token.balanceOf(recipient), GROSS, "event gross equals recipient credit");
        assertEq(token.balanceOf(other), 0, "event submitter receives no funds");
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

    function test_MissedPaymentsSettleSequentiallyInOneBlock() public {
        IFixedMandate.Mandate memory mandate = _openMandate(_defaultMandate(32));
        vm.warp(START + 5 * PERIOD);
        assertEq(executor.unlockedPaymentCount(mandate), 6, "six unlocked");

        for (uint256 i; i < 6; ++i) {
            executor.settle(mandate, i);
        }

        vm.expectRevert(IFixedMandate.PaymentNotUnlocked.selector);
        executor.settle(mandate, 6);
        assertEq(token.balanceOf(recipient), 6 * GROSS, "catch-up paid");
    }

    function test_FiniteScheduleCapsUnlocksAndKeepsArrearsCollectible() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(33);
        mandate.totalPayments = 3;
        mandate = _openMandate(mandate);
        vm.warp(START + 100 * PERIOD);

        assertEq(executor.unlockedPaymentCount(mandate), 3, "finite cap");
        for (uint256 i; i < 3; ++i) {
            executor.settle(mandate, i);
        }
        vm.expectRevert(IFixedMandate.PaymentNotUnlocked.selector);
        executor.settle(mandate, 3);
    }

    function test_RevertWhen_IndexIsSkippedStaleOrFuture() public {
        IFixedMandate.Mandate memory mandate = _openMandate(_defaultMandate(34));

        vm.expectRevert(IFixedMandate.UnexpectedPaymentIndex.selector);
        executor.settle(mandate, 1);
        executor.settle(mandate, 0);
        vm.expectRevert(IFixedMandate.UnexpectedPaymentIndex.selector);
        executor.settle(mandate, 0);
        vm.expectRevert(IFixedMandate.PaymentNotUnlocked.selector);
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
        assertEq(token.balanceOf(recipient), 2 * GROSS, "both occurrences pay full gross");
        assertEq(token.balanceOf(biller), 0, "biller submitter receives no funds");
        assertEq(token.balanceOf(other), 0, "other submitter receives no funds");
    }

    function test_BillerSubmissionHasIdenticalEconomicsToAnyCaller() public {
        IFixedMandate.Mandate memory billerSubmitted = _openMandate(_defaultMandate(36));
        IFixedMandate.Mandate memory otherSubmitted = _openMandate(_defaultMandate(37));

        vm.prank(biller);
        executor.settle(billerSubmitted, 0);
        vm.prank(other);
        executor.settle(otherSubmitted, 0);

        assertEq(token.balanceOf(recipient), 2 * GROSS, "each caller delivers full gross");
        assertEq(token.balanceOf(biller), 0, "biller receives no protocol funds");
        assertEq(token.balanceOf(other), 0, "other caller receives no protocol funds");
    }

    function test_SettlementUsesExactlyOneTransferFrom() public {
        ReentrantMockERC20 countingToken = new ReentrantMockERC20();
        IFixedMandate.Mandate memory mandate = _defaultMandate(38);
        mandate.token = address(countingToken);
        mandate = _openMandate(mandate);
        countingToken.mint(payer, GROSS);
        vm.prank(payer);
        countingToken.approve(address(executor), GROSS);

        vm.prank(other);
        executor.settle(mandate, 0);

        assertEq(countingToken.transferFromCount(), 1, "single transfer");
        assertEq(countingToken.balanceOf(recipient), GROSS, "recipient full gross");
        assertEq(countingToken.balanceOf(other), 0, "submitter receives no funds");
    }

    function test_DifferentPermissionlessCallersCanSubmitCatchUpPaymentsWithoutRewards() public {
        IFixedMandate.Mandate memory mandate = _defaultMandate(39);
        mandate = _openMandate(mandate);
        vm.warp(START + 2 * PERIOD);

        vm.prank(biller);
        executor.settle(mandate, 0);
        vm.prank(other);
        executor.settle(mandate, 1);
        executor.settle(mandate, 2);

        assertEq(token.balanceOf(recipient), 3 * GROSS, "recipient full gross per occurrence");
        assertEq(token.balanceOf(biller), 0, "biller receives no protocol funds");
        assertEq(token.balanceOf(other), 0, "other caller receives no protocol funds");
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
        vm.prank(payer);
        executor.cancelMandateAsPayer(payerCancelled);
        vm.snapshotGasLastCall("FixedMandate", "cancelMandate.payer.direct");
        vm.expectRevert(IFixedMandate.MandateCancelled.selector);
        executor.settle(payerCancelled, 0);

        IFixedMandate.Mandate memory billerCancelled = _openMandate(_defaultMandate(51));
        vm.prank(biller);
        executor.cancelMandateAsBiller(billerCancelled);
        vm.snapshotGasLastCall("FixedMandate", "cancelMandateAsBiller.biller.direct");
        vm.expectRevert(IFixedMandate.MandateCancelled.selector);
        executor.settle(billerCancelled, 0);
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
        executor.cancelMandateWithPayerSignature(
            payerMandate, 7, deadline, _signCancel(payerPk, payerId, payer, 7, deadline)
        );
        vm.snapshotGasLastCall("FixedMandate", "cancelMandate.payer.signature.eoa");
        assertTrue(executor.cancellationNonceUsed(payer, 7), "payer nonce used");
        assertFalse(executor.cancellationNonceUsed(biller, 7), "biller nonce separate");
        bytes memory replayedPayerSignature = _signCancel(payerPk, payerId, payer, 7, deadline);
        vm.expectRevert(IFixedMandate.InvalidCancellationNonce.selector);
        executor.cancelMandateWithPayerSignature(payerMandate, 7, deadline, replayedPayerSignature);

        IFixedMandate.Mandate memory billerMandate = _openMandate(_defaultMandate(54));
        bytes32 billerId = executor.mandateId(billerMandate);
        executor.cancelMandateWithBillerSignature(
            billerMandate, 7, deadline, _signCancel(billerPk, billerId, biller, 7, deadline)
        );
        vm.snapshotGasLastCall("FixedMandate", "cancelMandate.biller.signature.eoa");
        assertTrue(executor.cancellationNonceUsed(biller, 7), "biller nonce used");
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
        executor.cancelMandateWithPayerSignature(payerRoute, 10, deadline, payerSignature);

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
        vm.expectRevert(IFixedMandate.InvalidCancellationNonce.selector);
        executor.cancelMandateWithBillerSignature(billerRoute, 10, deadline, billerSignature);
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
        executor.cancelMandateWithBillerSignature(
            mandate, 8, deadline, _compact(_signCancel(billerPk, id, biller, 8, deadline))
        );
        vm.snapshotGasLastCall("FixedMandate", "cancelMandate.biller.signature.compact");
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
        freshToken.approve(address(executor), GROSS);
        vm.expectRevert(bytes("BALANCE"));
        executor.settle(mandate, 0);
        (,,, uint256 countAfterBalanceFailure) = executor.mandateStates(executor.mandateId(mandate));
        assertEq(countAfterBalanceFailure, 0);

        freshToken.mint(payer, GROSS);
        executor.settle(mandate, 0);
        assertEq(freshToken.balanceOf(recipient), GROSS, "retry succeeds");
    }

    function test_FalseReturnAndNoCodeTokensRevertWithoutConsumingPayment() public {
        FalseReturnMockERC20 falseToken = new FalseReturnMockERC20();
        IFixedMandate.Mandate memory falseMandate = _defaultMandate(71);
        falseMandate.token = address(falseToken);
        falseMandate = _openMandate(falseMandate);
        falseToken.mint(payer, GROSS);
        vm.prank(payer);
        falseToken.approve(address(executor), GROSS);
        vm.expectRevert();
        executor.settle(falseMandate, 0);
        (,,, uint256 falseCount) = executor.mandateStates(executor.mandateId(falseMandate));
        assertEq(falseCount, 0);

        IFixedMandate.Mandate memory noCodeMandate = _defaultMandate(72);
        noCodeMandate.token = makeAddr("no-code-token");
        noCodeMandate = _openMandate(noCodeMandate);
        vm.expectRevert();
        executor.settle(noCodeMandate, 0);
        (,,, uint256 noCodeCount) = executor.mandateStates(executor.mandateId(noCodeMandate));
        assertEq(noCodeCount, 0);
    }

    function test_NoReturnTokenIsSupported() public {
        NoReturnMockERC20 noReturnToken = new NoReturnMockERC20();
        IFixedMandate.Mandate memory mandate = _defaultMandate(73);
        mandate.token = address(noReturnToken);
        mandate = _openMandate(mandate);
        noReturnToken.mint(payer, GROSS);
        vm.prank(payer);
        noReturnToken.approve(address(executor), GROSS);
        executor.settle(mandate, 0);
        assertEq(noReturnToken.balanceOf(recipient), GROSS);
    }

    function test_UnsupportedTokenEconomicsRemainExplicit() public {
        FeeOnTransferMockERC20 feeToken = new FeeOnTransferMockERC20();
        IFixedMandate.Mandate memory feeMandate = _defaultMandate(74);
        feeMandate.token = address(feeToken);
        feeMandate = _openMandate(feeMandate);
        feeToken.mint(payer, GROSS);
        vm.prank(payer);
        feeToken.approve(address(executor), GROSS);
        executor.settle(feeMandate, 0);
        assertLt(feeToken.balanceOf(recipient), GROSS, "recipient can receive below nominal");

        ExcessiveDebitMockERC20 debitToken = new ExcessiveDebitMockERC20(1e6);
        IFixedMandate.Mandate memory debitMandate = _defaultMandate(75);
        debitMandate.token = address(debitToken);
        debitMandate = _openMandate(debitMandate);
        debitToken.mint(payer, GROSS + 1e6);
        vm.prank(payer);
        debitToken.approve(address(executor), GROSS);
        executor.settle(debitMandate, 0);
        assertEq(debitToken.balanceOf(payer), 0, "payer can be debited above nominal");
    }

    function test_CallbackSubmitterCanSettleNextUnlockedOccurrence() public {
        ReentrantMockERC20 reentrantToken = new ReentrantMockERC20();
        IFixedMandate.Mandate memory mandate = _defaultMandate(91);
        mandate.token = address(reentrantToken);
        mandate.totalPayments = 2;
        mandate = _openMandate(mandate);
        reentrantToken.mint(payer, 2 * GROSS);
        vm.prank(payer);
        reentrantToken.approve(address(executor), 2 * GROSS);
        vm.warp(START + PERIOD);

        bytes memory callbackData = abi.encodeCall(IFixedMandate.settle, (mandate, 1));
        reentrantToken.configureCallback(address(executor), callbackData, 1, false, false);

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
        assertEq(payerBefore - reentrantToken.balanceOf(payer), 2 * GROSS, "payer debited two full gross payments");
        assertEq(reentrantToken.balanceOf(recipient), 2 * GROSS, "recipient receives both full gross payments");
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
        reentrantToken.mint(payer, 2 * GROSS);
        vm.prank(payer);
        reentrantToken.approve(address(executor), 2 * GROSS);
        vm.warp(START + PERIOD);

        bytes memory callbackData = abi.encodeCall(IFixedMandate.settle, (mandate, 0));
        reentrantToken.configureCallback(address(executor), callbackData, 1, false, false);
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
        assertEq(reentrantToken.balanceOf(recipient), GROSS, "only outer occurrence paid");

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
        reentrantToken.mint(payer, 2 * GROSS);
        vm.prank(payer);
        reentrantToken.approve(address(executor), 2 * GROSS);
        vm.warp(START + PERIOD);

        IFixedMandate.Mandate memory redirected = _defaultMandate(93);
        redirected.token = address(reentrantToken);
        redirected.totalPayments = 2;
        redirected.recipient = other;
        bytes memory callbackData = abi.encodeCall(IFixedMandate.settle, (redirected, 1));
        reentrantToken.configureCallback(address(executor), callbackData, 1, false, false);
        vm.prank(other);
        executor.settle(mandate, 0);

        (,,, uint256 settledPaymentCount) = executor.mandateStates(executor.mandateId(mandate));
        (bool redirectedOpened,,, uint256 redirectedCount) = executor.mandateStates(executor.mandateId(redirected));
        assertEq(settledPaymentCount, 1, "only original occurrence consumed");
        assertFalse(redirectedOpened, "redirected mandate is not open");
        assertEq(redirectedCount, 0, "redirected mandate state unchanged");
        assertFalse(reentrantToken.callbackSucceeded(), "redirected callback rejected");
        assertEq(bytes4(reentrantToken.callbackReturnData()), IFixedMandate.MandateNotOpen.selector);
        assertEq(reentrantToken.balanceOf(recipient), GROSS, "pinned recipient paid");
        assertEq(reentrantToken.balanceOf(other), 0, "replacement recipient and submitter receive nothing");
    }

    function test_OuterTransferFailureRollsBackNestedStateAndEvents() public {
        ReentrantMockERC20 reentrantToken = new ReentrantMockERC20();
        IFixedMandate.Mandate memory mandate = _defaultMandate(94);
        mandate.token = address(reentrantToken);
        mandate.totalPayments = 2;
        mandate = _openMandate(mandate);
        reentrantToken.mint(payer, 2 * GROSS);
        vm.prank(payer);
        reentrantToken.approve(address(executor), 2 * GROSS);
        vm.warp(START + PERIOD);

        bytes memory callbackData = abi.encodeCall(IFixedMandate.settle, (mandate, 1));
        reentrantToken.configureCallback(address(executor), callbackData, 1, false, true);
        uint256 allowanceBefore = reentrantToken.allowance(payer, address(executor));
        bytes32 id = executor.mandateId(mandate);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(reentrantToken)));
        executor.settle(mandate, 0);

        // The exact SafeERC20 failure is returned only after the nested settlement succeeds. The enclosing
        // revert atomically discards both PaymentSettled logs together with the state and token effects below.
        (,,, uint256 settledPaymentCount) = executor.mandateStates(id);
        assertEq(settledPaymentCount, 0, "outer failure rolls back both counts");
        assertEq(reentrantToken.balanceOf(payer), 2 * GROSS, "payer debit rolled back");
        assertEq(reentrantToken.balanceOf(recipient), 0, "recipient credits rolled back");
        assertEq(reentrantToken.balanceOf(other), 0, "outer submitter receives nothing");
        assertEq(reentrantToken.balanceOf(address(reentrantToken)), 0, "callback submitter receives nothing");
        assertEq(reentrantToken.allowance(payer, address(executor)), allowanceBefore, "allowance rolled back");
        assertEq(reentrantToken.transferFromCount(), 0, "token transfer state rolled back");
    }

    // Fuzz coverage

    function testFuzz_UnlockedCountMatchesSchedule(uint32 rawPeriod, uint64 rawElapsed, uint16 rawTotal) public {
        uint256 period = bound(uint256(rawPeriod), 1, 365 days);
        uint256 elapsed = bound(uint256(rawElapsed), 0, 200 * 365 days);
        uint256 total = uint256(rawTotal);
        IFixedMandate.Mandate memory mandate = _defaultMandate(80);
        mandate.periodLength = period;
        mandate.totalPayments = total;
        mandate = _openMandate(mandate);
        vm.warp(START + elapsed);

        uint256 expected = elapsed / period + 1;
        if (total != 0 && expected > total) expected = total;
        assertEq(executor.unlockedPaymentCount(mandate), expected);
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

    function testFuzz_PermissionlessSettlementTransfersFullGross(uint96 rawGross) public {
        uint256 gross = bound(uint256(rawGross), 1, type(uint96).max);
        IFixedMandate.Mandate memory mandate = _defaultMandate(81);
        mandate.payerGrossPerPayment = gross;
        mandate = _openMandate(mandate);
        token.mint(payer, gross);

        uint256 payerBefore = token.balanceOf(payer);
        uint256 submitterBefore = token.balanceOf(other);
        vm.prank(other);
        executor.settle(mandate, 0);
        assertEq(payerBefore - token.balanceOf(payer), gross, "payer gross");
        assertEq(token.balanceOf(recipient), gross, "recipient gross");
        assertEq(token.balanceOf(other), submitterBefore, "submitter receives no funds");
    }

    function testFuzz_SameNonceCannotOpenDifferentFixedMandates(uint8 bitPos, bytes32 alternateTermsHash) public {
        vm.assume(alternateTermsHash != bytes32(0) && alternateTermsHash != TERMS_HASH);
        IFixedMandate.Mandate memory first = _defaultMandate(uint256(bitPos));
        IFixedMandate.Mandate memory second = _defaultMandate(uint256(bitPos));
        second.termsHash = alternateTermsHash;
        _openMandate(first);

        uint256 deadline = START + 1 hours;
        bytes memory payerSignature = _signAuthorization(payerPk, second, deadline);
        bytes memory billerSignature = _signAcceptance(billerPk, second, deadline);
        vm.expectRevert(IUnorderedNonces.InvalidUnorderedNonce.selector);
        executor.openMandate(second, deadline, deadline, payerSignature, billerSignature);
    }

    // Helpers

    function _defaultMandate(uint256 nonce) internal view returns (IFixedMandate.Mandate memory mandate) {
        mandate = IFixedMandate.Mandate({
            payer: payer,
            biller: biller,
            recipient: recipient,
            token: address(token),
            payerGrossPerPayment: GROSS,
            periodLength: PERIOD,
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
                    "Mandate(address payer,address biller,address recipient,address token,uint256 payerGrossPerPayment,uint256 periodLength,uint256 totalPayments,bytes32 termsHash,uint256 nonce)"
                ),
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

    function _eip712Digest(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
