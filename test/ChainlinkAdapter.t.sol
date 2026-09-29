// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FlipperBase} from "./utils/FlipperBase.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {ChainlinkVRFAdapter} from "../src/randomness/ChainlinkVRFAdapter.sol";
import {MockVRFWrapper} from "../src/mocks/MockVRFWrapper.sol";
import {IEntropyV2} from "../src/interfaces/IEntropyV2.sol";
import {IVRFV2PlusWrapper} from "../src/interfaces/IVRFV2PlusWrapper.sol";
import {FlipperDeploy} from "../script/lib/FlipperDeploy.sol";

/// @notice The house on the Chainlink VRF v2.5 path (ChainlinkVRFAdapter + a VRFV2PlusWrapper-compatible mock),
///         exactly as the dev stack runs it with RANDOMNESS_MODE=chainlink.
contract ChainlinkAdapterTest is FlipperBase {
    uint256 internal constant ROBINHOOD_GAS_PRICE = 53_718_000; // 0.0537 gwei
    uint256 internal constant ROBINHOOD_L1_COST = 720 * 259_241_824; // (580 B tx + 140 B padding) · L1 wei/byte

    MockVRFWrapper internal wrapper;
    ChainlinkVRFAdapter internal clAdapter;
    FlipperHouse internal clHouse;

    function setUp() public override {
        super.setUp();
        // Arbitrum One's live wrapper config, at Robinhood Chain's gas price and L1 posting cost (2026-09-23)
        vm.txGasPrice(ROBINHOOD_GAS_PRICE);
        wrapper = new MockVRFWrapper(MockVRFWrapper.Config(13_400, 104_500, 435, 60, 0, 2_500_000, ROBINHOOD_L1_COST));
        FlipperDeploy.Config memory c = FlipperDeploy.Config({
            poolManager: manager,
            entropy: IEntropyV2(address(0)),
            entropyProvider: address(0),
            deployer: address(this),
            owner: address(this),
            proxyAdminOwner: proxyAdminOwner,
            params: defaultParams()
        });
        RevenueRouter r = FlipperDeploy.deployRouter(c);
        FlipperDeploy.System memory s = FlipperDeploy.deployCore(
            c, r, IERC20(address(flipperToken)), FlipperDeploy.deployChainlinkAdapter(c, IVRFV2PlusWrapper(address(wrapper)), 1)
        );
        clHouse = s.house;
        clAdapter = ChainlinkVRFAdapter(address(s.randomness));
        clHouse.setTokenRoute(address(tokenT), _route1(tPool, flipperPool));
        flipperToken.approve(address(clHouse), type(uint256).max);
        clHouse.depositTreasury(50_000_000 ether);
        vm.startPrank(alice);
        flipperToken.approve(address(clHouse), type(uint256).max);
        tokenT.approve(address(clHouse), type(uint256).max);
        vm.stopPrank();
    }

    function _clFlip(address token, uint256 amount) internal returns (uint256 id, uint256 requestId) {
        uint256 fee = clHouse.randomnessFeeFor(token);
        vm.prank(alice);
        id = clHouse.flip{value: fee * 12 / 10}(token, amount, 0, block.timestamp); // padded; excess refunded
        (,,,,,,,,,, requestId,) = clHouse.flips(id);
    }

    function _st(uint256 id) internal view returns (FlipperHouseBase.Status st) {
        (,,,, st,,,,,,,) = clHouse.flips(id);
    }

    function test_chainlink_path_settles_token_and_flipper_flips() public {
        (uint256 a, uint256 ra) = _clFlip(address(tokenT), 1_000_000 ether);
        (uint256 b, uint256 rb) = _clFlip(address(flipperToken), 100_000 ether);
        assertTrue(clAdapter.isPending(ra) && clAdapter.isPending(rb));

        uint256 tBefore = tokenT.balanceOf(alice);
        assertTrue(wrapper.fulfillWithWord{gas: 12_000_000}(ra, WIN_WORD));
        assertEq(uint8(_st(a)), uint8(FlipperHouseBase.Status.Won));
        assertEq(tokenT.balanceOf(alice), tBefore + 2_000_000 ether);

        assertTrue(wrapper.fulfillWithWord{gas: 12_000_000}(rb, LOSS_WORD));
        assertEq(uint8(_st(b)), uint8(FlipperHouseBase.Status.Lost));
        assertFalse(clAdapter.isPending(ra) || clAdapter.isPending(rb));
    }

    function test_fee_is_charged_exactly_and_excess_refunded() public {
        uint256 fee = clHouse.randomnessFeeFor(address(tokenT));
        assertEq(fee, wrapper.calculateRequestPriceNative(clHouse.params().callbackGasLimit + 40_000, 1));
        uint256 ethBefore = alice.balance;
        _clFlip(address(tokenT), 1_000_000 ether);
        assertEq(alice.balance, ethBefore - fee);
        assertEq(address(wrapper).balance, fee);
    }

    /// Chainlink never re-delivers: a consumer failure is swallowed by the wrapper. The flip stays Pending with
    /// its randomness revealed, so the player can't cancel it; only the guardian can, after the 30-day emergency
    /// delay (before it, a revealed outcome can't be voided by anyone).
    function test_swallowed_failure_is_guardian_cancellable_only() public {
        (uint256 id, uint256 rid) = _clFlip(address(tokenT), 1_000_000 ether);
        vm.mockCallRevert(address(clHouse), abi.encodeWithSelector(FlipperHouse.onRandomness.selector), "boom");
        assertFalse(wrapper.fulfillWithWord{gas: 12_000_000}(rid, LOSS_WORD));
        vm.clearMockedCalls();
        assertEq(uint8(_st(id)), uint8(FlipperHouseBase.Status.Pending));
        assertFalse(clAdapter.isPending(rid));

        vm.warp(vm.getBlockTimestamp() + 8 days);
        vm.prank(alice);
        vm.expectRevert(FlipperHouseBase.RandomnessRevealed.selector);
        clHouse.cancelFlip(id);
        vm.expectRevert(FlipperHouseBase.RandomnessRevealed.selector);
        clHouse.cancelFlip(id); // this contract is owner/guardian of the second deployment: not yet
        vm.warp(vm.getBlockTimestamp() + 30 days);
        clHouse.cancelFlip(id);
        assertEq(uint8(_st(id)), uint8(FlipperHouseBase.Status.Refunded));
    }

    function test_only_wrapper_can_fulfil() public {
        (, uint256 rid) = _clFlip(address(tokenT), 1_000_000 ether);
        uint256[] memory words = new uint256[](1);
        vm.prank(mallory);
        vm.expectRevert(ChainlinkVRFAdapter.OnlyWrapper.selector);
        clAdapter.rawFulfillRandomWords(rid, words);
        vm.prank(mallory);
        vm.expectRevert(MockVRFWrapper.NotFulfiller.selector);
        wrapper.fulfill(rid, 1);
    }

    /// The fee follows the requester's gas price exactly like VRFV2PlusWrapper 1.0.0 (formula checked against the
    /// live Arbitrum One wrapper's estimateRequestPriceNative), and the house charges it at the flip's tx.gasprice.
    function test_fee_tracks_gas_price_like_the_real_wrapper() public {
        uint32 g = 440_000;
        // Arbitrum One wrapper, l1Cost 4.7546e10: estimateRequestPriceNative(100k, 1, 1e7) = 3_489_033_840_640
        MockVRFWrapper arb = new MockVRFWrapper(MockVRFWrapper.Config(13_400, 104_500, 435, 60, 0, 2_500_000, 47_546_150_400));
        assertEq(arb.estimateRequestPriceNative(100_000, 1, 1e7), 3_489_033_840_640);
        assertEq(arb.estimateRequestPriceNative(2_440_000, 1, 53_718_000), 219_530_004_368_640);

        uint256 low = wrapper.estimateRequestPriceNative(g, 1, ROBINHOOD_GAS_PRICE);
        uint256 high = wrapper.estimateRequestPriceNative(g, 1, ROBINHOOD_GAS_PRICE * 2);
        assertGt(high, low * 19 / 10, "~linear in gas price");
        assertEq(clHouse.randomnessFeeFor(address(tokenT)), wrapper.calculateRequestPriceNative(2_000_000 + 40_000, 1));

        vm.txGasPrice(ROBINHOOD_GAS_PRICE * 2);
        uint256 fee2 = clHouse.randomnessFeeFor(address(tokenT));
        vm.txGasPrice(ROBINHOOD_GAS_PRICE);
        assertGt(fee2, clHouse.randomnessFeeFor(address(tokenT)));
        // a flip priced at the old gas price but sent at a higher one is rejected (the UI must price at its own fee)
        uint256 stale = clHouse.randomnessFeeFor(address(tokenT));
        vm.txGasPrice(ROBINHOOD_GAS_PRICE * 2);
        vm.prank(alice);
        vm.expectRevert();
        clHouse.flip{value: stale}(address(tokenT), 1_000_000 ether, 0, block.timestamp);
    }

    function test_wrapper_gas_cap_is_enforced() public {
        FlipperHouseBase.Params memory p = defaultParams();
        p.callbackGasLimit = 2_500_000; // + adapter overhead > Chainlink's 2.5M cap
        clHouse.setParams(p);
        uint256 fee = wrapper.estimateRequestPriceNative(2_540_000, 1, ROBINHOOD_GAS_PRICE);
        vm.prank(alice);
        vm.expectRevert();
        clHouse.flip{value: fee}(address(tokenT), 1_000_000 ether, 0, block.timestamp);
    }
}
