// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseHook} from "lib/v4-periphery/src/utils/BaseHook.sol";
import {ERC1155} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {IERC20} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

// Define MIN_SQRT_RATIO and MAX_SQRT_RATIO if not available in TickMath
uint160 constant MIN_SQRT_RATIO = 4295128739;
uint160 constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

// Use the PoolIdLibrary for PoolKey to add the `.toId()` function on a PoolKey
// which hashes the PoolKey struct into a bytes32 value

contract TakeProfitsHook is BaseHook, ERC1155 {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Create a mapping to store the last known tickLower value for a given Pool
    mapping(PoolId poolId => int24 tickLower) public tickLowerLasts;

    // Create a nested mapping to store the take-profit orders placed by users
    // The mapping is PoolId => tickLower => zeroForOne => amount
    mapping(PoolId poolId => mapping(int24 tick => mapping(bool zeroForOne => int256 amount))) public takeProfitPositions;

    // tokenIdExists is a mapping to store whether a given tokenId (i.e. a take-profit order) exists given a token id
    mapping(uint256 tokenId => bool exists) public tokenIdExists;
    // tokenIdClaimable is a mapping that stores how many swapped tokens are claimable for a given tokenId
    mapping(uint256 tokenId => uint256 claimable) public tokenIdClaimable;
    // tokenIdTotalSupply is a mapping that stores how many tokens need to be sold to execute the take-profit order
    mapping(uint256 tokenId => uint256 supply) public tokenIdTotalSupply;
    // tokenIdData is a mapping that stores the PoolKey, tickLower, and zeroForOne values for a given tokenId
    mapping(uint256 tokenId => TokenData) public tokenIdData;

    struct TokenData {
        PoolKey poolKey;
        int24 tick;
        bool zeroForOne;
    }

    modifier poolManagerOnly() {
        require(msg.sender == address(poolManager), "Not PoolManager");
        _;
    }

    // Initialize BaseHook and ERC1155 parent contracts in the constructor
    constructor(
        IPoolManager _poolManager,
        string memory _uri
    ) BaseHook(_poolManager) ERC1155(_uri) {}

    // Required override function for BaseHook to let the PoolManager know which hooks are implemented
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // Hooks
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick,
        // Add bytes calldata after tick
        bytes calldata

    ) external poolManagerOnly returns (bytes4) {
        _setTickLowerLast(key.toId(), _getTickLower(tick, key.tickSpacing));
        return TakeProfitsHook.afterInitialize.selector;
    }

    // Core Utilities
    function placeOrder(
        PoolKey calldata key,
        int24 tick,
        uint256 amountIn,
        bool zeroForOne
    ) external returns (int24) {
        int24 tickLower = _getTickLower(tick, key.tickSpacing);
        takeProfitPositions[key.toId()][tickLower][zeroForOne] += int256(
            amountIn
        );

        uint256 tokenId = getTokenId(key, tickLower, zeroForOne);
        // If token id doesn't already exist, add it to the mapping
        // Not every order creates a new token id, as it's possible for users to add more tokens to a pre-existing order
        if (!tokenIdExists[tokenId]) {
            tokenIdExists[tokenId] = true;
            tokenIdData[tokenId] = TokenData(key, tickLower, zeroForOne);
        }

        // Mint ERC-1155 tokens to the user
        _mint(msg.sender, tokenId, amountIn, "");
        tokenIdTotalSupply[tokenId] += amountIn;

        // Extract the address of the token the user wants to sell
        address tokenToBeSoldContract = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);

        // Move the tokens to be sold from the user to this contract
        IERC20(tokenToBeSoldContract).transferFrom(
            msg.sender,
            address(this),
            amountIn
        );

        return tickLower;
    }

    function cancelOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) external {
        int24 tickLower = _getTickLower(tick, key.tickSpacing);
        uint256 tokenId = getTokenId(key, tickLower, zeroForOne);

        // Get the amount of tokens the user's ERC-1155 tokens represent
        uint256 amountIn = balanceOf(msg.sender, tokenId);
        require(amountIn > 0, "TakeProfitsHook: No orders to cancel");

        takeProfitPositions[key.toId()][tickLower][zeroForOne] -= int256(
            amountIn
        );
        tokenIdTotalSupply[tokenId] -= amountIn;
        _burn(msg.sender, tokenId, amountIn);

        // Extract the address of the token the user wanted to sell
        Currency tokenToBeSold = zeroForOne ? key.currency0 : key.currency1;
        // Move the tokens to be sold from this contract back to the user
        tokenToBeSold.transfer(msg.sender, amountIn);
    }

    function _handleSwap(
        PoolKey calldata key,
        IPoolManager.SwapParams memory params
    ) internal returns (BalanceDelta) {
        // delta is the BalanceDelta struct that stores the delta balance changes
        // i.e. Change in Token 0 balance and change in Token 1 balance

        BalanceDelta delta = poolManager.swap(key, params, "");

        // If this swap was a swap for Token 0 to Token 1
        if (params.zeroForOne) {
            // If we owe Uniswap Token 0, we need to send them the required amount
            // NOTE: This will be a negative value, as it is a negative balance change from the user's perspective
            if (delta.amount0() < 0) {
                IERC20(Currency.unwrap(key.currency0)).transfer(
                    address(poolManager),
                    // We flip the sign of the amount to make it positive when sending it to the pool manager
                    uint128(-delta.amount0())
                );
                poolManager.settle(); // Removed argument
            }

            // If we are owed Token 1, we need to `take` it from the Pool Manager
            if (delta.amount1() > 0) {
                poolManager.take(
                    key.currency1,
                    address(this),
                    uint128(delta.amount1())
                );
            }
        }
        // Else if this swap was a swap for Token 1 to Token 0
        else {
            // Same as above
            // If we owe Uniswap Token 1, we need to send them the required amount
            if (delta.amount1() < 0) {
                IERC20(Currency.unwrap(key.currency1)).transfer(
                    address(poolManager),
                    uint128(-delta.amount1())
                );
                poolManager.settle(); // Removed argument
            }

            // If we are owed Token 0, we take it from the Pool Manager
            if (delta.amount0() > 0) {
                poolManager.take(
                    key.currency0,
                    address(this),
                    uint128(delta.amount0())
                );
            }
        }

        return delta;
    }

    function fillOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        int256 amountIn
    ) internal {
        // Setup the swapping parameters
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -amountIn,
            // Set the price limit to be the least possible if swapping from Token 0 to Token 1
            // or the maximum possible if swapping from Token 1 to Token 0
            // i.e. infinite slippage allowed
            sqrtPriceLimitX96: zeroForOne
                ? MIN_SQRT_RATIO + 1 // Updated to use defined constant
                : MAX_SQRT_RATIO - 1 // Updated to use defined constant
        });

        BalanceDelta delta = _handleSwap(key, swapParams);

        // Update mapping to reflect that `amountIn` worth of tokens have been swapped from this order
        takeProfitPositions[key.toId()][tick][zeroForOne] -= amountIn;

        uint256 tokenId = getTokenId(key, tick, zeroForOne);

        // Tokens we were owed by Uniswap are represented as a positive delta change
        uint256 amountOfTokensReceivedFromSwap = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));

        // Update the amount of tokens claimable for this order
        tokenIdClaimable[tokenId] += amountOfTokensReceivedFromSwap;
    }

    // Getter function for takeProfitPositions
    function getTakeProfitPosition(
        PoolId poolId,
        int24 tick,
        bool zeroForOne
    ) external view returns (int256) {
        return takeProfitPositions[poolId][tick][zeroForOne];
    }

    // ERC-1155 Helpers
    function getTokenId(PoolKey calldata key, int24 tickLower, bool zeroForOne) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(key.toId(), tickLower, zeroForOne)));
    }

    // Utility Helpers
    function _setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function _getTickLower(int24 actualTick, int24 tickSpacing) private pure returns (int24) {
        int24 intervals = actualTick / tickSpacing;
        if (actualTick < 0 && actualTick % tickSpacing != 0) intervals--; // round towards negative infinity
        return intervals * tickSpacing;
    }
}









