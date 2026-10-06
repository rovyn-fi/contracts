// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC-20 interface used by RovynFeeRouter.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Permit2 allowance interface used by Uniswap Universal Router.
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @title RovynFeeRouter
/// @notice Collects a 0.15% Rovyn fee, splits it 50/50, and atomically forwards
///         the remaining input to the configured Uniswap Universal Router.
/// @dev Universal Router calldata must name the end user as the output recipient.
///      For ERC-20 swaps its V3/V4 payer flag must treat this contract as payer.
contract RovynFeeRouter {
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant ROVYN_FEE_BPS = 15; // 0.15%
    uint256 public constant REWARDS_SHARE_BPS = 5_000; // 50% of the Rovyn fee
    uint48 private constant ROUTER_ALLOWANCE_TTL = 10 minutes;

    address public immutable universalRouter;
    IPermit2 public immutable permit2;
    address public owner;
    address public pendingOwner;
    address public rewardsVault;
    address public treasury;
    bool public paused;
    uint256 private locked = 1;

    mapping(address token => uint256 amount) public rewardsFeesCollected;
    mapping(address token => uint256 amount) public treasuryFeesCollected;

    event SwapExecuted(address indexed user, address indexed tokenIn, uint256 grossAmount, uint256 feeAmount, uint256 netAmount);
    event FeeRecipientsUpdated(address indexed rewardsVault, address indexed treasury);
    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PauseUpdated(bool paused);

    error Unauthorized();
    error InvalidAddress();
    error InvalidAmount();
    error ContractPaused();
    error Reentrancy();
    error TokenCallFailed();
    error RouterCallFailed(bytes reason);
    error AmountTooLarge();

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

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    constructor(address universalRouter_, address permit2_, address rewardsVault_, address treasury_, address owner_) {
        if (universalRouter_ == address(0) || permit2_ == address(0) || rewardsVault_ == address(0) || treasury_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        universalRouter = universalRouter_;
        permit2 = IPermit2(permit2_);
        rewardsVault = rewardsVault_;
        treasury = treasury_;
        owner = owner_;
        emit FeeRecipientsUpdated(rewardsVault_, treasury_);
        emit OwnershipTransferred(address(0), owner_);
    }

    /// @notice Executes a native-ETH swap. routerCalldata must spend exactly netAmount.
    function executeNative(bytes calldata routerCalldata) external payable nonReentrant whenNotPaused returns (bytes memory result) {
        if (msg.value == 0) revert InvalidAmount();
        uint256 startingBalance = address(this).balance - msg.value;
        (uint256 fee, uint256 netAmount) = quoteFee(msg.value);

        (bool success, bytes memory response) = universalRouter.call{value: netAmount}(routerCalldata);
        if (!success) revert RouterCallFailed(response);

        _distributeNativeFee(fee);
        uint256 refund = address(this).balance - startingBalance;
        if (refund != 0) _sendNative(msg.sender, refund);

        emit SwapExecuted(msg.sender, address(0), msg.value, fee, netAmount);
        return response;
    }

    /// @notice Executes an ERC-20 swap. routerCalldata must spend exactly netAmount
    ///         from this contract through Permit2 and send output directly to msg.sender.
    function executeERC20(address tokenIn, uint256 grossAmount, bytes calldata routerCalldata) external nonReentrant whenNotPaused returns (bytes memory result) {
        if (tokenIn == address(0) || grossAmount == 0) revert InvalidAmount();
        uint256 startingBalance = IERC20(tokenIn).balanceOf(address(this));
        _safeTransferFrom(tokenIn, msg.sender, address(this), grossAmount);
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - startingBalance;
        if (received == 0) revert InvalidAmount();

        (uint256 fee, uint256 netAmount) = quoteFee(received);
        if (netAmount > type(uint160).max) revert AmountTooLarge();
        _distributeTokenFee(tokenIn, fee);

        _forceApprove(tokenIn, address(permit2), netAmount);
        permit2.approve(tokenIn, universalRouter, uint160(netAmount), uint48(block.timestamp) + ROUTER_ALLOWANCE_TTL);

        (bool success, bytes memory response) = universalRouter.call(routerCalldata);
        if (!success) revert RouterCallFailed(response);

        permit2.approve(tokenIn, universalRouter, 0, uint48(block.timestamp));
        _forceApprove(tokenIn, address(permit2), 0);

        uint256 refund = IERC20(tokenIn).balanceOf(address(this)) - startingBalance;
        if (refund != 0) _safeTransfer(tokenIn, msg.sender, refund);

        emit SwapExecuted(msg.sender, tokenIn, received, fee, netAmount);
        return response;
    }

    function quoteFee(uint256 grossAmount) public pure returns (uint256 fee, uint256 netAmount) {
        fee = grossAmount * ROVYN_FEE_BPS / BPS_DENOMINATOR;
        netAmount = grossAmount - fee;
    }

    function setFeeRecipients(address rewardsVault_, address treasury_) external onlyOwner {
        if (rewardsVault_ == address(0) || treasury_ == address(0)) revert InvalidAddress();
        rewardsVault = rewardsVault_;
        treasury = treasury_;
        emit FeeRecipientsUpdated(rewardsVault_, treasury_);
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
        address previousOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, msg.sender);
    }

    /// @notice Recovers assets accidentally sent to this contract while paused.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (!paused || to == address(0)) revert Unauthorized();
        _safeTransfer(token, to, amount);
    }

    function rescueNative(address payable to, uint256 amount) external onlyOwner {
        if (!paused || to == address(0)) revert Unauthorized();
        _sendNative(to, amount);
    }

    receive() external payable {}

    function _distributeTokenFee(address token, uint256 fee) private {
        uint256 rewardsAmount = fee * REWARDS_SHARE_BPS / BPS_DENOMINATOR;
        uint256 treasuryAmount = fee - rewardsAmount;
        rewardsFeesCollected[token] += rewardsAmount;
        treasuryFeesCollected[token] += treasuryAmount;
        if (rewardsAmount != 0) _safeTransfer(token, rewardsVault, rewardsAmount);
        if (treasuryAmount != 0) _safeTransfer(token, treasury, treasuryAmount);
    }

    function _distributeNativeFee(uint256 fee) private {
        uint256 rewardsAmount = fee * REWARDS_SHARE_BPS / BPS_DENOMINATOR;
        uint256 treasuryAmount = fee - rewardsAmount;
        rewardsFeesCollected[address(0)] += rewardsAmount;
        treasuryFeesCollected[address(0)] += treasuryAmount;
        if (rewardsAmount != 0) _sendNative(rewardsVault, rewardsAmount);
        if (treasuryAmount != 0) _sendNative(treasury, treasuryAmount);
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
