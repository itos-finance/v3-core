// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

interface IUniswapV3PoolSingleFee {
    /// @notice Which token should all deployed pools collect fees in?
    function feeToken() external view returns (address);
}
