// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {FlipperBase} from "./utils/FlipperBase.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {PythEntropyAdapter} from "../src/randomness/PythEntropyAdapter.sol";
import {IEntropyV2} from "../src/interfaces/IEntropyV2.sol";
import {TreasuryVault, IVaultHouse} from "../src/TreasuryVault.sol";
import {FlipperHouseV2Mock} from "./mocks/FlipperHouseV2Mock.sol";
import {TreasuryVaultV2Mock} from "./mocks/TreasuryVaultV2Mock.sol";

contract UpgradeTest is FlipperBase {
    function _admin(address proxy) internal view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(proxy, ERC1967Utils.ADMIN_SLOT)))));
    }

    function _impl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    function test_every_contract_is_a_proxy_owned_by_the_admin_owner() public view {
        address[6] memory proxies = [
            address(house),
            address(adapter),
            address(router),
            address(lens),
            address(sys.hookit),
            address(vault)
        ];
        for (uint256 i; i < proxies.length; ++i) {
            assertTrue(_impl(proxies[i]) != address(0), "has implementation");
            assertEq(_admin(proxies[i]).owner(), proxyAdminOwner, "ProxyAdmin owner");
        }
    }

    function test_upgrade_house_preserves_state_and_pending_flips() public {
        // state before: a settled loss, a pending flip, a pending win owed by a keeper
        uint256 settled = _flip(alice, address(flipperToken), 1_000_000 ether);
        _reveal(settled, LOSS_WORD);
        uint256 pending = _flip(bob, address(tokenT), 1_000_000 ether);
        uint256 treasury = house.treasury();
        uint256 reserved = house.reserved();
        FlipperHouseBase.Params memory p = house.params();

        FlipperHouseV2Mock v2 = new FlipperHouseV2Mock(manager, IERC20(address(flipperToken)), adapter, house.module());
        ProxyAdmin admin = _admin(address(house));

        vm.prank(mallory);
        vm.expectRevert();
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(house)), address(v2), "");

        vm.prank(proxyAdminOwner);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(house)), address(v2), "");
        assertEq(_impl(address(house)), address(v2));

        FlipperHouseV2Mock h2 = FlipperHouseV2Mock(payable(address(house)));
        assertEq(h2.version(), 2);
        assertEq(h2.treasury(), treasury);
        assertEq(h2.reserved(), reserved);
        assertEq(h2.owner(), owner);
        assertEq(h2.params().maxBetBps, p.maxBetBps);
        (,,,, FlipperHouseBase.Status st,,,,,,,) = h2.flips(settled);
        assertEq(uint8(st), uint8(FlipperHouseBase.Status.Lost));
        vm.prank(owner);
        h2.setAppended(7);
        assertEq(h2.appendedV2Var(), 7);

        // a flip requested before the upgrade settles after it
        _reveal(pending, WIN_WORD);
        (,,,, st,,,,,,,) = h2.flips(pending);
        assertEq(uint8(st), uint8(FlipperHouseBase.Status.Won));
        _assertSolvent();
    }

    function test_proxies_cannot_be_reinitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        house.initialize(mallory, defaultParams());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        router.initialize(mallory);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        adapter.initialize(IEntropyV2(address(entropy)), mallory, mallory);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(IVaultHouse(address(house)), IERC20(address(flipperToken)), mallory, 0, 0, 0);
    }

    function test_implementations_are_locked() public {
        FlipperHouse impl = FlipperHouse(payable(_impl(address(house))));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(mallory, defaultParams());
        RevenueRouter routerImpl = RevenueRouter(payable(_impl(address(router))));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        routerImpl.initialize(mallory);
        PythEntropyAdapter aImpl = PythEntropyAdapter(_impl(address(adapter)));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        aImpl.initialize(IEntropyV2(address(entropy)), mallory, mallory);
        TreasuryVault vImpl = TreasuryVault(_impl(address(vault)));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vImpl.initialize(IVaultHouse(address(house)), IERC20(address(flipperToken)), mallory, 0, 0, 0);
    }

    function test_upgrade_vault_preserves_positions_and_pol() public {
        vm.startPrank(alice);
        flipperToken.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(10_000_000 ether, 0);
        vm.warp(vault.unlockAt(alice));
        vault.requestWithdraw(shares / 2);
        vm.stopPrank();
        uint256 lost = _flip(bob, address(flipperToken), 1_000_000 ether);
        _reveal(lost, LOSS_WORD); // a gain above the mark: part of alice's becomes protocol-owned
        vault.crystallize();

        (uint256 a, uint256 d, uint256 p, uint256 pps, uint256 h,,) = vault.stats();
        (, uint256 value, uint256 unlocksAt, uint256 pend, uint256 ready) = vault.positionOf(alice);
        assertGt(p, 100_000_000 ether, "fee shares minted");

        TreasuryVaultV2Mock v2 = new TreasuryVaultV2Mock();
        ProxyAdmin admin = _admin(address(vault));
        vm.prank(mallory);
        vm.expectRevert();
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(vault)), address(v2), "");
        vm.prank(proxyAdminOwner);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(vault)), address(v2), "");
        assertEq(_impl(address(vault)), address(v2));

        TreasuryVaultV2Mock vault2 = TreasuryVaultV2Mock(address(vault));
        assertEq(vault2.version(), 2);
        assertEq(vault2.owner(), owner);
        assertEq(vault2.name(), "Staked FLIPPER");
        assertEq(address(vault2.house()), address(house));
        assertEq(vault2.performanceFeeBps(), 8000);
        (uint256 a2, uint256 d2, uint256 p2, uint256 pps2, uint256 h2,,) = vault2.stats();
        assertEq(a2, a);
        assertEq(d2, d);
        assertEq(p2, p);
        assertEq(pps2, pps);
        assertEq(h2, h);
        (, uint256 value2, uint256 unlocksAt2, uint256 pend2, uint256 ready2) = vault2.positionOf(alice);
        assertEq(value2, value);
        assertEq(unlocksAt2, unlocksAt);
        assertEq(pend2, pend);
        assertEq(ready2, ready);
        vm.prank(owner);
        vault2.setAppended(7);
        assertEq(vault2.appendedV2Var(), 7);

        // a withdrawal requested before the upgrade completes after it
        vm.warp(ready);
        uint256 expected = vault2.previewRedeem(pend);
        vm.prank(alice);
        assertEq(vault2.withdraw(0), expected);
        assertEq(vault2.balanceOf(alice), shares - pend);
    }

    function test_adapter_binding_is_one_time() public {
        vm.prank(owner);
        vm.expectRevert(PythEntropyAdapter.AlreadyBound.selector);
        adapter.bind(mallory);
    }
}
