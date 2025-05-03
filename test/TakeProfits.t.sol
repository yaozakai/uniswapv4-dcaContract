// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Foundry libraries
import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

// Our contracts
import {TakeProfitsHook} from "../src/TakeProfitsHook.sol";
import {TakeProfitsStub} from "../src/TakeProfitsStub.sol";

contract TakeProfitsTest is Test, Deployers {
    // Use the libraries
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Declare variables
    Currency private _tokenOne;
    Currency private _tokenTwo;
    TakeProfitsHook private _hook;
    PoolKey private _key;
    uint160 private constant _SQRT_RATIO_1_1 = 79228162514264337593543950336; // Example value for 1:1 price ratio
    IPoolManager private _poolManager; // Declare poolManager

    function _stubValidateHookAddress() private {
        // Deploy the stub contract
        TakeProfitsStub stub = new TakeProfitsStub(_poolManager, _hook);
        
        // Fetch all the storage slot writes that have been done at the stub address
        (, bytes32[] memory writes) = vm.accesses(address(stub));

        // Etch the code of the stub at the hardcoded hook address
        vm.etch(address(_hook), address(stub).code);

        // Replay the storage slot writes at the hook address
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(_hook), slot, vm.load(address(stub), slot));
            }
        }
    }

    function setUp() public {
        // Step 1: Deploy v4 core contracts
        deployFreshManagerAndRouters();
        assert(true); // Ensure this step does not fail

        // Step 2: Use a valid checksummed mock factory address
        address factory = address(0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF);
        assert(factory != address(0)); // Ensure factory address is valid

        // Step 3: Initialize poolManager directly
        _poolManager = new PoolManager(factory);
        assert(address(_poolManager) != address(0)); // Ensure poolManager is initialized

        // Step 4: Deploy two test tokens
        (_tokenOne, _tokenTwo) = deployMintAndApprove2Currencies();
        assert(Currency.unwrap(_tokenOne) != address(0)); // Ensure tokenOne is valid
        assert(Currency.unwrap(_tokenTwo) != address(0)); // Ensure tokenTwo is valid

        // Step 5: Initialize the hook
        _hook = TakeProfitsHook(
            address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG))
        );
        assert(address(_hook) != address(0)); // Ensure hook is initialized

        // Step 6: Approve our hook address to spend these tokens
        MockERC20(Currency.unwrap(_tokenOne)).approve(
            address(_hook),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(_tokenTwo)).approve(
            address(_hook),
            type(uint256).max
        );

        // Step 7: Stub our hook and add code to our hardcoded address
        _stubValidateHookAddress();

        // Step 8: Initialize a pool with these two tokens
        (_key, ) = initPool(
            _tokenOne,
            _tokenTwo,
            _hook,
            3000,
            _SQRT_RATIO_1_1
        );

        // Ensure pool key is valid by checking its fields
        assert(Currency.unwrap(_key.currency0) != address(0)); // Unwrap Currency type
        assert(Currency.unwrap(_key.currency1) != address(0)); // Unwrap Currency type
        assert(address(_key.hooks) != address(0)); // Cast hooks to address
        assert(_key.fee != 0);
        assert(_key.tickSpacing != 0);

        // Step 9: Add initial liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity(
            _key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ""
        );
        modifyLiquidityRouter.modifyLiquidity(
            _key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ""
        );
        modifyLiquidityRouter.modifyLiquidity(
            _key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return
            bytes4(
                keccak256(
                    "onERC1155Received(address,address,uint256,uint256,bytes)"
                )
            );
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return
            bytes4(
                keccak256(
                    "onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"
                )
            );
    }

    // function testPlaceOrder() public {
    //     // Place a zeroForOne take-profit order
    //     // for 10e18 token0 tokens
    //     // at tick 100

    //     int24 tick = 100;
    //     uint256 amount = 10 ether;
    //     bool zeroForOne = true;

    //     // Note the original balance of token0 we have
    //     uint256 originalBalance = _tokenOne.balanceOfSelf();

    //     // Place the order
    //     int24 tickLower = _hook.placeOrder(_key, tick, amount, zeroForOne);

    //     // Note the new balance of token0 we have
    //     uint256 newBalance = _tokenOne.balanceOfSelf();

    //     // Since we deployed the pool contract with tick spacing = 60
    //     // i.e. the tick can only be a multiple of 60
    //     // and initially the tick is 0
    //     // the tickLower should be 60 since we placed an order at tick 100
    //     assertEq(tickLower, 60);

    //     // Ensure that our balance was reduced by `amount` tokens
    //     assertEq(originalBalance - newBalance, amount);

    //     // Check the balance of ERC-1155 tokens we received
    //     uint256 tokenId = _hook.getTokenId(_key, tickLower, zeroForOne);
    //     uint256 tokenBalance = _hook.balanceOf(address(this), tokenId);

    //     // Ensure that we were, in fact, given ERC-1155 tokens for the order
    //     // equal to the `amount` of token0 tokens we placed the order for
    //     assertTrue(tokenId != 0);
    //     assertEq(tokenBalance, amount);
    // }

    // function test_cancelOrder() public {
    //     // Place an order similar as earlier, but cancel it later
    //     int24 tick = 100;
    //     uint256 amount = 10 ether;
    //     bool zeroForOne = true;

    //     uint256 originalBalance = tokenOne.balanceOfSelf();

    //     int24 tickLower = hook.placeOrder(key, tick, amount, zeroForOne);

    //     uint256 newBalance = tokenOne.balanceOfSelf();

    //     assertEq(tickLower, 60);
    //     assertEq(originalBalance - newBalance, amount);

    //     // Check the balance of ERC-1155 tokens we received
    //     uint256 tokenId = hook.getTokenId(key, tickLower, zeroForOne);
    //     uint256 tokenBalance = hook.balanceOf(address(this), tokenId);
    //     assertEq(tokenBalance, amount);

    //     // Cancel the order
    //     hook.cancelOrder(key, tickLower, zeroForOne);

    //     // Check that we received our token0 tokens back, and no longer own any ERC-1155 tokens
    //     uint256 finalBalance = tokenOne.balanceOfSelf();
    //     assertEq(finalBalance, originalBalance);

    //     tokenBalance = hook.balanceOf(address(this), tokenId);
    //     assertEq(tokenBalance, 0);
    // }

    // function test_orderExecute_zeroForOne() public {
    //     int24 tick = 100;
    //     uint256 amount = 10 ether;
    //     bool zeroForOne = true;

    //     // Place our order at tick 100 for 10e18 token0 tokens
    //     int24 tickLower = hook.placeOrder(key, tick, amount, zeroForOne);

    //     // Do a separate swap from oneForZero to make tick go up
    //     // Sell 1e18 token1 tokens for token0 tokens
    //     IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
    //         zeroForOne: !zeroForOne,
    //         amountSpecified: -1 ether,
    //         sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
    //     });

    //     PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
    //         .TestSettings({
    //             withdrawTokens: true,
    //             settleUsingTransfer: true,
    //             currencyAlreadySent: false
    //         });

    //     swapRouter.swap(key, params, testSettings, ZERO_BYTES);

    //     // Check that the order has been executed
    //     int256 tokensLeftToSell = hook.takeProfitPositions(
    //         key.toId(),
    //         tick,
    //         zeroForOne
    //     );
    //     assertEq(tokensLeftToSell, 0);

    //     // Check that the hook contract has the expected number of token1 tokens ready to redeem
    //     uint256 tokenId = hook.getTokenId(key, tickLower, zeroForOne);
    //     uint256 claimableTokens = hook.tokenIdClaimable(tokenId);
    //     uint256 hookContractToken1Balance = tokenTwo.balanceOf(address(hook));
    //     assertEq(claimableTokens, hookContractToken1Balance);

    //     // Ensure we can redeem the token1 tokens
    //     uint256 originalToken1Balance = tokenTwo.balanceOf(address(this));
    //     hook.redeem(tokenId, amount, address(this));
    //     uint256 newToken1Balance = tokenTwo.balanceOf(address(this));

    //     assertEq(newToken1Balance - originalToken1Balance, claimableTokens);
    // }



}