// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockERC20 {
    string public name = "Mock USDC";
    string public symbol = "mUSDC";

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function decimals() public view virtual returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 allowed = allowance[owner][spender];
        require(allowed >= amount, "ALLOWANCE");
        if (allowed != type(uint256).max) allowance[owner][spender] = allowed - amount;
    }

    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(to != address(0), "ZERO_TO");
        require(balanceOf[from] >= amount, "BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

contract ConfigurableDecimalsMockERC20 is MockERC20 {
    uint8 internal immutable configuredDecimals;

    constructor(uint8 decimals_) {
        configuredDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return configuredDecimals;
    }
}

contract ZeroTransferRevertingMockERC20 is MockERC20 {
    function _transfer(address from, address to, uint256 amount) internal override {
        require(amount != 0, "ZERO_TRANSFER");
        super._transfer(from, to, amount);
    }
}

contract FeeOnTransferMockERC20 is MockERC20 {
    function _transfer(address from, address to, uint256 amount) internal override {
        require(to != address(0), "ZERO_TO");
        require(balanceOf[from] >= amount, "BALANCE");
        uint256 transferFee = amount / 100;
        uint256 credited = amount - transferFee;
        balanceOf[from] -= amount;
        balanceOf[to] += credited;
        emit Transfer(from, to, credited);
        if (transferFee != 0) emit Transfer(from, address(0), transferFee);
    }
}

contract ExcessiveDebitMockERC20 is MockERC20 {
    uint256 internal immutable extraDebit;

    constructor(uint256 extraDebit_) {
        extraDebit = extraDebit_;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        require(to != address(0), "ZERO_TO");
        uint256 debited = amount + extraDebit;
        require(balanceOf[from] >= debited, "BALANCE");
        balanceOf[from] -= debited;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        if (extraDebit != 0) emit Transfer(from, address(0), extraDebit);
    }
}

contract MockERC1271Wallet {
    bytes4 internal constant MAGICVALUE = 0x1626ba7e;
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (_recover(hash, signature) == owner) return MAGICVALUE;
        return 0xffffffff;
    }

    function approveToken(address token, address spender, uint256 amount) external {
        require(msg.sender == owner, "ONLY_OWNER");
        MockERC20(token).approve(spender, amount);
    }

    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == owner, "ONLY_OWNER");
        (bool success, bytes memory returnData) = target.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        return returnData;
    }

    function _recover(bytes32 hash, bytes calldata signature) internal pure returns (address) {
        if (signature.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
        return ecrecover(hash, v, r, s);
    }
}

contract RevertingERC1271Wallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        revert("SIGNATURE_CALLBACK");
    }
}

contract FalseReturnMockERC20 is MockERC20 {
    function transferFrom(address, address, uint256) external pure override returns (bool) {
        return false;
    }
}

contract NoReturnMockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ALLOWANCE");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        require(balanceOf[from] >= amount, "BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

contract ReentrantMockERC20 is MockERC20 {
    address public callbackTarget;
    bytes public callbackData;
    uint256 public callbackTransferNumber;
    uint256 public transferFromCount;
    bool public bubbleCallbackFailure;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes public callbackReturnData;

    function configureCallback(address target, bytes calldata data, uint256 transferNumber, bool bubbleFailure)
        external
    {
        callbackTarget = target;
        callbackData = data;
        callbackTransferNumber = transferNumber;
        bubbleCallbackFailure = bubbleFailure;
        transferFromCount = 0;
        callbackAttempted = false;
        callbackSucceeded = false;
        delete callbackReturnData;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        transferFromCount += 1;

        if (!callbackAttempted && transferFromCount == callbackTransferNumber) {
            callbackAttempted = true;
            (bool success, bytes memory returnData) = callbackTarget.call(callbackData);
            callbackSucceeded = success;
            callbackReturnData = returnData;
            if (!success && bubbleCallbackFailure) {
                assembly ("memory-safe") {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
        }
        return true;
    }
}
