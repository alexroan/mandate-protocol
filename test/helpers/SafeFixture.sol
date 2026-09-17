// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FixedMandate} from "../../src/FixedMandate.sol";
import {IFixedMandate} from "../../src/interfaces/IFixedMandate.sol";
import {MockERC20} from "./MandateMocks.sol";

library Enum {
    enum Operation {
        Call,
        DelegateCall
    }
}

// Common ABI for the unmodified, published Safe 1.3.0 and 1.4.1 bytecode fixtures.
interface Safe {
    function VERSION() external view returns (string memory);
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
    function nonce() external view returns (uint256);
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function domainSeparator() external view returns (bytes32);
    function signedMessages(bytes32 hash) external view returns (uint256);
    function changeThreshold(uint256 threshold) external;
    function swapOwner(address prevOwner, address oldOwner, address newOwner) external;
    function setFallbackHandler(address handler) external;
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 txNonce
    ) external view returns (bytes32);
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool success);
}

interface SafeHandler {
    function getMessageHashForSafe(Safe safe, bytes memory message) external view returns (bytes32);
}

abstract contract SafeFixture is Test {
    FixedMandate internal executor;
    MockERC20 internal token;
    Safe internal payerSafe;
    Safe internal billerSafe;
    address internal singleton;
    address internal handler;
    address internal multiSend;
    address internal signMessageLib;
    address internal recipient;
    address internal relayer;
    uint256[3] internal ownerKeys;

    uint256 internal constant START = 1_700_000_000;
    uint256 internal constant PERIOD = 30 days;
    uint256 internal constant AMOUNT = 100e6;
    uint256 internal constant DEADLINE = START + 7 days;

    function _safeVersion() internal pure virtual returns (string memory);

    function setUp() public virtual {
        vm.warp(START);
        ownerKeys = [uint256(0xA11CE), uint256(0xB0B), uint256(0xCAFE)];
        for (uint256 i; i < ownerKeys.length; ++i) {
            for (uint256 j = i + 1; j < ownerKeys.length; ++j) {
                if (vm.addr(ownerKeys[j]) < vm.addr(ownerKeys[i])) {
                    (ownerKeys[i], ownerKeys[j]) = (ownerKeys[j], ownerKeys[i]);
                }
            }
        }
        recipient = makeAddr("Safe treasury recipient");
        relayer = makeAddr("Safe transaction relayer");
        executor = new FixedMandate();
        token = new MockERC20();
        singleton = _deployArtifact("Safe", "");
        handler = _deployArtifact("CompatibilityFallbackHandler", "");
        multiSend = _deployArtifact("MultiSend", "");
        signMessageLib = _deployArtifact("SignMessageLib", "");
        payerSafe = _deploySafe(handler);
        billerSafe = _deploySafe(handler);
        token.mint(address(payerSafe), 100_000e6);
    }

    function _deployArtifact(string memory name, bytes memory constructorArgs) internal returns (address deployed) {
        string memory path = string.concat("test/fixtures/safe/", _safeVersion(), "/", name, ".json");
        bytes memory creationCode = abi.encodePacked(vm.parseJsonBytes(vm.readFile(path), ".bytecode"), constructorArgs);
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0) && deployed.code.length != 0, "Safe fixture deployment failed");
    }

    function _deploySafe(address fallbackHandler) internal returns (Safe wallet) {
        wallet = Safe(_deployArtifact("SafeProxy", abi.encode(singleton)));
        address[] memory owners = new address[](3);
        for (uint256 i; i < owners.length; ++i) {
            owners[i] = vm.addr(ownerKeys[i]);
        }
        wallet.setup(owners, 2, address(0), "", fallbackHandler, address(0), 0, payable(address(0)));
        assertEq(wallet.VERSION(), _safeVersion(), "published Safe version");
        assertEq(wallet.getThreshold(), 2, "2-of-3 threshold");
        assertEq(wallet.getOwners(), owners, "real Safe owner configuration");
    }

    function _mandate(uint256 nonce) internal view returns (IFixedMandate.Mandate memory) {
        return IFixedMandate.Mandate({
            payer: address(payerSafe),
            biller: address(billerSafe),
            recipient: recipient,
            token: address(token),
            amountPerPayment: AMOUNT,
            periodLength: PERIOD,
            firstPaymentAt: 0,
            totalPayments: 12,
            termsHash: keccak256("Safe recurring subscription"),
            nonce: nonce
        });
    }

    function _sign(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signOwners(bytes32 digest) internal view returns (bytes memory) {
        return bytes.concat(_sign(ownerKeys[0], digest), _sign(ownerKeys[1], digest));
    }

    function _safeMessageHash(Safe wallet, bytes32 mandateDigest) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(uint256 chainId,address verifyingContract)"), block.chainid, address(wallet)
            )
        );
        bytes32 message =
            keccak256(abi.encode(keccak256("SafeMessage(bytes message)"), keccak256(abi.encode(mandateDigest))));
        return keccak256(abi.encodePacked(hex"1901", domain, message));
    }

    function _safeSign(Safe wallet, bytes32 digest) internal view returns (bytes memory) {
        return _signOwners(_safeMessageHash(wallet, digest));
    }

    function _safeTxHash(Safe wallet, address target, bytes memory data, Enum.Operation operation, uint256 safeTxGas)
        internal
        view
        returns (bytes32)
    {
        return
            wallet.getTransactionHash(
                target, 0, data, operation, safeTxGas, 0, 0, address(0), address(0), wallet.nonce()
            );
    }

    function _execSafe(Safe wallet, address target, bytes memory data, Enum.Operation operation)
        internal
        returns (bool)
    {
        return _execSafeWithGas(wallet, target, data, operation, 0);
    }

    function _execSafeWithGas(
        Safe wallet,
        address target,
        bytes memory data,
        Enum.Operation operation,
        uint256 safeTxGas
    ) internal returns (bool) {
        bytes memory signatures = _signOwners(_safeTxHash(wallet, target, data, operation, safeTxGas));
        vm.prank(relayer);
        return wallet.execTransaction(
            target, 0, data, operation, safeTxGas, 0, 0, address(0), payable(address(0)), signatures
        );
    }

    function _open(IFixedMandate.Mandate memory mandate) internal returns (bytes32) {
        bytes memory payerSignature = _safeSign(payerSafe, executor.hashMandateAuthorization(mandate, DEADLINE));
        bytes memory billerSignature = _safeSign(billerSafe, executor.hashMandateAcceptance(mandate, DEADLINE));
        vm.prank(relayer);
        return executor.openMandate(mandate, DEADLINE, DEADLINE, payerSignature, billerSignature);
    }

    function _assertState(IFixedMandate.Mandate memory mandate, bool opened, bool cancelled, uint256 count)
        internal
        view
    {
        (bool actualOpened, bool actualCancelled, uint256 startedAt, uint256 actualCount) =
            executor.mandateStates(executor.mandateId(mandate));
        assertEq(actualOpened, opened, "mandate opened");
        assertEq(actualCancelled, cancelled, "mandate cancelled");
        assertEq(actualCount, count, "settled payment count");
        assertEq(startedAt, opened ? START : 0, "mandate start time");
    }

    function _batchItem(address target, bytes memory data, Enum.Operation operation)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(uint8(operation), target, uint256(0), data.length, data);
    }

    function _execBatch(Safe wallet, bytes memory transactions) internal returns (bool) {
        return _execSafe(
            wallet, multiSend, abi.encodeWithSignature("multiSend(bytes)", transactions), Enum.Operation.DelegateCall
        );
    }
}
