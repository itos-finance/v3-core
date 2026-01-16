// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import './interfaces/ISwapRouter.sol';
import './interfaces/IUniswapV3Pool.sol';
import './interfaces/IUniswapV3Factory.sol';
import './interfaces/callback/IUniswapV3SwapCallback.sol';
import './interfaces/IERC20Minimal.sol';
import './libraries/TickMath.sol';
import './libraries/SafeCast.sol';
import './libraries/SafeERC20Minimal.sol';

/**
 * @title SimpleSwapRouter
 * @notice Simplified swap router that implements basic Uniswap V3 swap functionality
 * @dev This is a dumbed-down version of the SwapRouter in v3-periphery
 */
contract SimpleSwapRouter is ISwapRouter {
    using SafeERC20Minimal for IERC20Minimal;
    using SafeCast for uint256;

    /// @dev The Uniswap V3 factory address
    address public immutable factory;

    /// @dev The WETH9 address (can be address(0) for testing)
    address public immutable WETH9;

    constructor(address _factory, address _WETH9) {
        factory = _factory;
        WETH9 = _WETH9;
    }

    /// @dev Returns the hardcoded pool for USDC/WETH swaps
    function getPool(address token0, address token1, uint24 fee) public view returns (IUniswapV3Pool) {
        return IUniswapV3Pool(IUniswapV3Factory(factory).getPool(token0, token1, fee));
    }

    /// @dev Callback data structure for swaps
    struct SwapCallbackData {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address payer;
    }

    /// @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        require(amount0Delta > 0 || amount1Delta > 0, 'Invalid swap callback');

        SwapCallbackData memory callbackData = abi.decode(data, (SwapCallbackData));

        // Verify the callback is from the correct pool
        IUniswapV3Pool pool = getPool(callbackData.tokenIn, callbackData.tokenOut, callbackData.fee);
        require(msg.sender == address(pool), 'Invalid callback sender');

        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        // Transfer tokens to the pool
        IERC20Minimal(callbackData.tokenIn).safeTransferFrom(callbackData.payer, msg.sender, amountToPay);
    }

    /// @inheritdoc ISwapRouter
    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable override returns (uint256 amountOut) {
        require(block.timestamp <= params.deadline, 'Transaction too old');

        IUniswapV3Pool pool = getPool(params.tokenIn, params.tokenOut, params.fee);

        // Determine swap direction
        bool zeroForOne = params.tokenIn < params.tokenOut;

        // Prepare callback data
        SwapCallbackData memory callbackData = SwapCallbackData({
            tokenIn: params.tokenIn,
            tokenOut: params.tokenOut,
            fee: params.fee,
            payer: msg.sender
        });

        // Execute the swap
        (int256 amount0, int256 amount1) = pool.swap(
            params.recipient,
            zeroForOne,
            params.amountIn.toInt256(),
            params.sqrtPriceLimitX96 == 0
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : params.sqrtPriceLimitX96,
            abi.encode(callbackData)
        );

        // Calculate amount out
        amountOut = uint256(-(zeroForOne ? amount1 : amount0));

        require(amountOut >= params.amountOutMinimum, 'Too little received');
    }

    /// @inheritdoc ISwapRouter
    function exactInput(ExactInputParams calldata params) external payable override returns (uint256 amountOut) {
        require(block.timestamp <= params.deadline, 'Transaction too old');

        // For simplicity, this implementation only supports single-hop swaps
        // In a full implementation, this would handle multi-hop swaps
        require(params.path.length == 43, 'Only single-hop swaps supported'); // 20 + 3 + 20 bytes

        // Decode path: tokenIn (20) + fee (3) + tokenOut (20)
        address tokenIn = address(bytes20(params.path[0:20]));
        uint24 fee = uint24(bytes3(params.path[20:23]));
        address tokenOut = address(bytes20(params.path[23:43]));

        // Use exactInputSingle for the actual swap
        ExactInputSingleParams memory singleParams = ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: params.recipient,
            deadline: params.deadline,
            amountIn: params.amountIn,
            amountOutMinimum: params.amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        return this.exactInputSingle(singleParams);
    }

    /// @inheritdoc ISwapRouter
    function exactOutputSingle(
        ExactOutputSingleParams calldata params
    ) external payable override returns (uint256 amountIn) {
        require(block.timestamp <= params.deadline, 'Transaction too old');

        IUniswapV3Pool pool = getPool(params.tokenIn, params.tokenOut, params.fee);

        // Determine swap direction
        bool zeroForOne = params.tokenIn < params.tokenOut;

        // Prepare callback data
        SwapCallbackData memory callbackData = SwapCallbackData({
            tokenIn: params.tokenIn,
            tokenOut: params.tokenOut,
            fee: params.fee,
            payer: msg.sender
        });

        // Execute the swap
        (int256 amount0, int256 amount1) = pool.swap(
            params.recipient,
            zeroForOne,
            -params.amountOut.toInt256(),
            params.sqrtPriceLimitX96 == 0
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : params.sqrtPriceLimitX96,
            abi.encode(callbackData)
        );

        // Calculate amount in
        amountIn = zeroForOne ? uint256(amount0) : uint256(amount1);

        require(amountIn <= params.amountInMaximum, 'Too much requested');
    }

    /// @inheritdoc ISwapRouter
    function exactOutput(ExactOutputParams calldata params) external payable override returns (uint256 amountIn) {
        require(block.timestamp <= params.deadline, 'Transaction too old');

        // For simplicity, this implementation only supports single-hop swaps
        // In a full implementation, this would handle multi-hop swaps
        require(params.path.length == 43, 'Only single-hop swaps supported'); // 20 + 3 + 20 bytes

        // Decode path: tokenOut (20) + fee (3) + tokenIn (20) - reversed for exact output
        address tokenOut = address(bytes20(params.path[0:20]));
        uint24 fee = uint24(bytes3(params.path[20:23]));
        address tokenIn = address(bytes20(params.path[23:43]));

        // Use exactOutputSingle for the actual swap
        ExactOutputSingleParams memory singleParams = ExactOutputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: params.recipient,
            deadline: params.deadline,
            amountOut: params.amountOut,
            amountInMaximum: params.amountInMaximum,
            sqrtPriceLimitX96: 0
        });

        return this.exactOutputSingle(singleParams);
    }

    /// @dev Helper function to get pool state for debugging
    function getPoolState(
        address token0,
        address token1,
        uint24 fee
    )
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        // Always return the hardcoded pool state
        IUniswapV3Pool pool = getPool(token0, token1, fee);
        return pool.slot0();
    }

    /// @dev Helper function to check if a pool exists
    function poolExists(address token0, address token1, uint24 fee) external view returns (bool) {
        return address(getPool(token0, token1, fee)) != address(0);
    }
}
