// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IWETH {
    function withdraw(uint256 amount) external;
}

interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

/// @title RovynLimitOrders
/// @notice Gasless limit / stop orders for Rovyn on Robinhood Chain.
///         The trader signs an order (EIP-712). Funds stay in the trader's wallet until the order fills.
///         When the price is reached, the Rovyn keeper fills it through the Rovyn fee router (or 0x),
///         and this contract checks that the trader receives AT LEAST "minAmountOut", or the whole fill reverts.
/// @dev    - Only the keeper can fill, and only through the two allow-listed swap contracts.
///         - Everything the swap returns goes to the trader (no surplus is kept).
///         - An order can be filled once; the trader can cancel it on-chain at any time with "cancel(nonce)".
///         - Native ETH cannot be pulled with an approval, so ETH buys use WETH as "tokenIn";
///           the contract unwraps it and the swap is paid in native ETH (works for ETH-paired pools too).
///           "tokenOut == address(0)" means the trader receives native ETH.
contract RovynLimitOrders {
    /// Rovyn fee router (Uniswap routes, 0.15% Rovyn fee).
    address public constant FEE_ROUTER = 0xc4C48136d6204009AbA72d3d47dc8d2a60262FDA;
    /// 0x AllowanceHolder (0x routes, 0.05% Rovyn fee).
    address public constant ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;
    /// Wrapped ETH on Robinhood Chain.
    address public constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,address tokenIn,address tokenOut,uint256 amountIn,uint256 minAmountOut,uint256 expiry,uint256 nonce)"
    );
    bytes32 private constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("Rovyn Limit Orders");
    bytes32 private constant VERSION_HASH = keccak256("1");
    uint256 private constant HALF_ORDER =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    struct Order {
        address maker;
        address tokenIn;
        address tokenOut; // address(0) = native ETH
        uint256 amountIn;
        uint256 minAmountOut;
        uint256 expiry; // unix seconds
        uint256 nonce;
    }

    address public owner;
    address public pendingOwner;
    address public keeper;
    bool public paused;
    uint256 private locked = 1;

    /// maker => nonce => filled or cancelled
    mapping(address => mapping(uint256 => bool)) public nonceUsed;

    event OrderFilled(address indexed maker, uint256 indexed nonce, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address target);
    event OrderCancelled(address indexed maker, uint256 indexed nonce);
    event KeeperUpdated(address indexed keeper);
    event PauseUpdated(bool paused);
    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error Unauthorized();
    error InvalidAddress();
    error ContractPaused();
    error Reentrancy();
    error OrderExpired();
    error OrderAlreadyUsed();
    error BadSignature();
    error TargetNotAllowed();
    error SwapFailed(bytes reason);
    error InsufficientOutput(uint256 received, uint256 minimum);
    error TokenCallFailed();
    error InvalidOrder();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    constructor(address owner_, address keeper_) {
        if (owner_ == address(0) || keeper_ == address(0)) revert InvalidAddress();
        owner = owner_;
        keeper = keeper_;
        emit OwnershipTransferred(address(0), owner_);
        emit KeeperUpdated(keeper_);
    }

    /* ------------------------------------------------------------------ orders */

    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    function hashOrder(Order calldata order) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            ORDER_TYPEHASH, order.maker, order.tokenIn, order.tokenOut, order.amountIn, order.minAmountOut, order.expiry, order.nonce
        ));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    /// @notice Keeper fills a signed order. "data" is swap calldata for "target" that sells exactly
    ///         "amountIn" of "tokenIn" from this contract and sends the output to this contract.
    function fill(Order calldata order, bytes calldata signature, address target, bytes calldata data)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        _checkAndUse(order, signature, target);
        amountOut = _execute(order, target, data);
        emit OrderFilled(order.maker, order.nonce, order.tokenIn, order.tokenOut, order.amountIn, amountOut, target);
    }

    function _checkAndUse(Order calldata order, bytes calldata signature, address target) private {
        if (msg.sender != keeper) revert Unauthorized();
        if (paused) revert ContractPaused();
        if (target != FEE_ROUTER && target != ALLOWANCE_HOLDER) revert TargetNotAllowed();
        if (order.tokenIn == address(0) || order.tokenIn == order.tokenOut || order.amountIn == 0 || order.minAmountOut == 0) revert InvalidOrder();
        if (order.tokenIn == WETH && order.tokenOut == address(0)) revert InvalidOrder();
        if (block.timestamp > order.expiry) revert OrderExpired();
        if (nonceUsed[order.maker][order.nonce]) revert OrderAlreadyUsed();
        if (!_validSignature(order.maker, hashOrder(order), signature)) revert BadSignature();
        nonceUsed[order.maker][order.nonce] = true;
    }

    function _execute(Order calldata order, address target, bytes calldata data) private returns (uint256 amountOut) {
        // Pull exactly amountIn from the trader (the only funds this contract ever touches).
        uint256 inBefore = IERC20(order.tokenIn).balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        _safeTransferFrom(order.tokenIn, order.maker, address(this), order.amountIn);
        uint256 outBefore = _balance(order.tokenOut);

        if (order.tokenIn == WETH) {
            // ETH buy: unwrap and pay the swap in native ETH.
            IWETH(WETH).withdraw(order.amountIn);
            _call(target, order.amountIn, data);
        } else {
            _forceApprove(order.tokenIn, target, order.amountIn);
            _call(target, 0, data);
            _forceApprove(order.tokenIn, target, 0);
        }

        amountOut = _balance(order.tokenOut) - outBefore;
        if (amountOut < order.minAmountOut) revert InsufficientOutput(amountOut, order.minAmountOut);

        // Whatever the swap didn't spend goes back to the trader, then the whole output.
        uint256 leftover = IERC20(order.tokenIn).balanceOf(address(this)) - inBefore;
        if (leftover != 0) _safeTransfer(order.tokenIn, order.maker, leftover);
        if (order.tokenOut == address(0)) _sendNative(order.maker, amountOut);
        else _safeTransfer(order.tokenOut, order.maker, amountOut);
        uint256 ethLeft = address(this).balance - ethBefore;
        if (ethLeft != 0) _sendNative(order.maker, ethLeft);
    }

    function _call(address target, uint256 value, bytes calldata data) private {
        (bool ok, bytes memory reason) = target.call{value: value}(data);
        if (!ok) revert SwapFailed(reason);
    }

    /// @notice Trader cancels an order on-chain (the keeper can then never fill it).
    function cancel(uint256 nonce) external {
        nonceUsed[msg.sender][nonce] = true;
        emit OrderCancelled(msg.sender, nonce);
    }

    /* ------------------------------------------------------------------ admin */

    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert InvalidAddress();
        keeper = keeper_;
        emit KeeperUpdated(keeper_);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PauseUpdated(paused_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Recovers assets sent to this contract by mistake (it never holds user funds between fills).
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        if (token == address(0)) _sendNative(to, amount);
        else _safeTransfer(token, to, amount);
    }

    receive() external payable {}

    /* ------------------------------------------------------------------ internals */

    function _validSignature(address signer, bytes32 digest, bytes calldata signature) private view returns (bool) {
        if (signature.length == 65) {
            bytes32 r = bytes32(signature[0:32]);
            bytes32 s = bytes32(signature[32:64]);
            uint8 v = uint8(signature[64]);
            if (v < 27) v += 27;
            if (uint256(s) <= HALF_ORDER && (v == 27 || v == 28)) {
                address recovered = ecrecover(digest, v, r, s);
                if (recovered != address(0) && recovered == signer) return true;
            }
        }
        // Smart-contract wallets (EIP-1271).
        if (signer.code.length == 0) return false;
        (bool ok, bytes memory result) = signer.staticcall(abi.encodeCall(IERC1271.isValidSignature, (digest, signature)));
        return ok && result.length >= 32 && abi.decode(result, (bytes4)) == IERC1271.isValidSignature.selector;
    }

    function _balance(address token) private view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TokenCallFailed();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TokenCallFailed();
    }

    function _forceApprove(address token, address spender, uint256 amount) private {
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC20.approve, (spender, amount)));
        if (success && (data.length == 0 || abi.decode(data, (bool)))) return;
        (success, data) = token.call(abi.encodeCall(IERC20.approve, (spender, 0)));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TokenCallFailed();
        (success, data) = token.call(abi.encodeCall(IERC20.approve, (spender, amount)));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TokenCallFailed();
    }

    function _sendNative(address to, uint256 amount) private {
        (bool success,) = payable(to).call{value: amount}("");
        if (!success) revert TokenCallFailed();
    }
}
