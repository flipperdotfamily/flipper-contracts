// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {FlipperBase} from "./utils/FlipperBase.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {V4RouteAdapter} from "../src/adapters/V4RouteAdapter.sol";
import {ILaunchpadVerifier} from "../src/interfaces/ILaunchpadVerifier.sol";
import {ListingPolicy} from "../src/ListingPolicy.sol";
import {IPonsV2Factory} from "../src/interfaces/IPons.sol";
import {IHookitLaunchFactory, IHookitMasterHook} from "../src/interfaces/IHookit.sol";
import {PonsVerifier} from "../src/verifiers/PonsVerifier.sol";
import {CodehashVerifier} from "../src/verifiers/CodehashVerifier.sol";
import {HookitVerifier} from "../src/verifiers/HookitVerifier.sol";
import {CodeTemplate} from "../src/libraries/CodeTemplate.sol";

/// @dev stand-in for PonsV2LauncherToken: OZ ERC20 whose runtime differs per launch only in its immutables
contract MockPonsToken is ERC20 {
    address public immutable deployer;
    address public immutable launchFactory;
    address public immutable curve;

    constructor(address d, address f, address c) ERC20("Pons", "PONSY") {
        deployer = d;
        launchFactory = f;
        curve = c;
        _mint(msg.sender, 1e30);
    }
}

/// @dev a token with the same interface but different code (an owner-switchable blacklist)
contract SwitchToken is ERC20 {
    address public immutable deployer;
    address public immutable launchFactory;
    address public immutable curve;
    mapping(address => bool) public blocked;

    constructor(address d, address f, address c) ERC20("Switch", "SW") {
        deployer = d;
        launchFactory = f;
        curve = c;
        _mint(msg.sender, 1e30);
    }

    function block_(address a) external {
        blocked[a] = true;
    }
}

contract MockPonsFactory {
    mapping(address => IPonsV2Factory.LaunchedToken) internal _l;

    function set(address token, IPonsV2Factory.LaunchedToken memory l) external {
        _l[token] = l;
    }

    function getLaunchedToken(address token) external view returns (IPonsV2Factory.LaunchedToken memory) {
        return _l[token];
    }
}

/// @dev an issuer token with no immutables: every instance shares one codehash (like the Robinhood BeaconProxy)
contract MockStock is ERC20 {
    constructor() ERC20("Stock", "STK") {
        _mint(msg.sender, 1e30);
    }
}

/// @dev stand-in for hookit's LaunchToken
contract MockHookitToken is ERC20 {
    address public immutable creator;
    address public immutable holderTracker;

    constructor(address c, address t) ERC20("Hookit launch", "HLT") {
        creator = c;
        holderTracker = t;
        _mint(msg.sender, 1e30);
    }
}

contract MockHookitFactory {
    mapping(address => uint256) public tokenLaunchId;
    mapping(uint256 => PoolKey) internal _keys;

    function set(address token, uint256 id, PoolKey memory key) external {
        tokenLaunchId[token] = id;
        _keys[id] = key;
    }

    function poolKeyOf(uint256 id) external view returns (PoolKey memory) {
        return _keys[id];
    }
}

contract MockHookitHook {
    mapping(bytes32 => IHookitMasterHook.LaunchState) internal _st;
    mapping(bytes32 => uint256) public configs;

    function set(bytes32 id, IHookitMasterHook.LaunchState memory st, uint256 flags) external {
        _st[id] = st;
        configs[id] = flags;
    }

    function launchState(bytes32 id) external view returns (IHookitMasterHook.LaunchState memory) {
        return _st[id];
    }
}

/// @dev verifiers that misbehave: they must never brick listings
contract RevertingVerifier {
    function verify(address, PoolKey calldata) external pure returns (bool, uint8, bytes32) {
        revert("boom");
    }
}

contract GasBurnerVerifier {
    function verify(address, PoolKey calldata) external view returns (bool, uint8, bytes32) {
        while (gasleft() > 0) {}
        return (true, 0, "burner");
    }
}

contract GarbageVerifier {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 7)
        }
    }
}

/// @notice The listing framework: pool whitelist, attached launchpad verifiers (pons / issuer / hookit logic), token
///         allowlist with pinned hooks, owner override, misbehaving verifiers, and tokens listed before.
contract ListingPolicyTest is FlipperBase {
    using PoolIdLibrary for PoolKey;

    MockPonsFactory internal ponsFactory;
    PonsVerifier internal ponsVerifier;
    ListingPolicy internal policy;

    function setUp() public override {
        super.setUp();
        policy = sys.policy;
        ponsFactory = new MockPonsFactory();
        // the audited template, from a reference launch
        MockPonsToken ref = new MockPonsToken(makeAddr("d0"), address(ponsFactory), makeAddr("c0"));
        uint256 offsets =
            _immutableOffsets(address(ref), _three(makeAddr("d0"), address(ponsFactory), makeAddr("c0")));
        bytes32 template = CodeTemplate.maskedHash(address(ref), address(ref).code.length, offsets);
        // the launchpad's "meme hook" is the ToggleHook the base pools already use
        ponsVerifier = new PonsVerifier(
            IPonsV2Factory(address(ponsFactory)),
            address(toggle),
            address(toggle).codehash,
            template,
            address(ref).code.length,
            offsets
        );
        vm.prank(owner);
        policy.attach(ponsVerifier);
    }

    // ── path 2: launchpad verifiers ─────────────────────────────────────────────────────────────────────

    function test_launchpad_path_lists_and_settles() public {
        (MockPonsToken t, PoolKey memory key) = _ponsLaunch("Launch", 2);
        (uint8 reason, uint8 path, bytes32 id, uint8 detail) = policy.evaluate(address(t), key, address(0));
        assertEq(reason, 0);
        assertEq(path, policy.PATH_LAUNCHPAD());
        assertEq(id, bytes32("pons"));
        assertEq(detail, 0);
        vm.expectEmit(address(sys.v4));
        emit V4RouteAdapter.ListingVetted(address(t), PoolId.unwrap(key.toId()), 2, "pons");
        vm.prank(mallory);
        sys.v4.registerAndList(address(t), key);
        t.transfer(alice, 10_000_000 ether);
        vm.prank(alice);
        t.approve(address(house), type(uint256).max);
        uint256 flipId = _flip(alice, address(t), 1_000_000 ether);
        _reveal(flipId, WIN_WORD);
        assertEq(uint8(_status(flipId)), uint8(FlipperHouseBase.Status.Won));
        _assertSolvent();
    }

    function test_launchpad_refusal_reasons() public {
        (MockPonsToken early, PoolKey memory k1) = _ponsLaunch("Early", 1); // still on the curve
        _expect(address(early), k1, policy.NOT_VETTED(), ponsVerifier.NOT_GRADUATED());
        MockPonsToken stray = new MockPonsToken(makeAddr("d0"), address(ponsFactory), makeAddr("c0"));
        _expect(address(stray), _keyOf(address(stray), address(0)), policy.NOT_VETTED(), ponsVerifier.NOT_A_LAUNCH());
        (MockPonsToken t,) = _ponsLaunch("Launch", 2);
        _expect(address(t), _keyOf(address(t), address(0)), policy.NOT_VETTED(), ponsVerifier.NOT_CANONICAL_POOL());
        vm.expectRevert(
            abi.encodeWithSelector(V4RouteAdapter.NotVetted.selector, policy.NOT_VETTED(), ponsVerifier.NOT_GRADUATED())
        );
        sys.v4.register(address(early), k1);
    }

    /// The registry vouches, but the code isn't the audited template: an upgradeable proxy, or a token with an owner
    /// switch.
    function test_proxy_or_switch_token_is_refused() public {
        MockPonsToken impl = new MockPonsToken(makeAddr("d1"), address(ponsFactory), makeAddr("c1"));
        address proxy = address(new ERC1967Proxy(address(impl), ""));
        ponsFactory.set(proxy, _launched(proxy, 2));
        _expect(proxy, _keyOf(proxy, address(toggle)), policy.NOT_VETTED(), ponsVerifier.TOKEN_CODE());
        SwitchToken sw = new SwitchToken(makeAddr("d2"), address(ponsFactory), makeAddr("c2"));
        ponsFactory.set(address(sw), _launched(address(sw), 2));
        _expect(address(sw), _keyOf(address(sw), address(toggle)), policy.NOT_VETTED(), ponsVerifier.TOKEN_CODE());
    }

    function test_launchpad_hook_code_change_is_refused() public {
        (MockPonsToken t, PoolKey memory key) = _ponsLaunch("Launch", 2);
        vm.etch(address(toggle), abi.encodePacked(address(toggle).code, hex"00"));
        _expect(address(t), key, policy.NOT_VETTED(), ponsVerifier.HOOK_CODE_CHANGED());
    }

    function test_issuer_codehash_verifier() public {
        MockStock a = new MockStock();
        MockStock b = new MockStock();
        CodehashVerifier v = new CodehashVerifier(address(a).codehash, "issuer", address(0));
        vm.prank(owner);
        policy.attach(v);
        (uint8 reason, uint8 path, bytes32 id,) = policy.evaluate(address(b), _keyOf(address(b), address(0)), address(0));
        assertEq(reason, 0, "any instance of the issuer's code");
        assertEq(path, policy.PATH_LAUNCHPAD());
        assertEq(id, bytes32("issuer"));
        _expect(address(b), _keyOf(address(b), address(toggle)), policy.NOT_VETTED(), v.HOOKED_POOL());
    }

    // ── path 1: pool whitelist ──────────────────────────────────────────────────────────────────────────

    function test_pool_whitelist_path() public {
        MockStock s = new MockStock();
        PoolKey memory k = _poolOf(address(s), IHooks(address(0)), FEE, TS);
        assertEq(_reason(address(s), k), policy.NOT_VETTED());
        vm.prank(owner);
        policy.setPoolWhitelisted(k, true);
        (uint8 reason, uint8 path,,) = policy.evaluate(address(s), k, address(0));
        assertEq(reason, 0);
        assertEq(path, policy.PATH_POOL());
        vm.prank(mallory);
        sys.v4.registerAndList(address(s), k);
        // only that exact pool: another pool of the same token isn't whitelisted
        assertEq(_reason(address(s), _keyOf(address(s), address(0))), policy.NOT_VETTED());
        // a whitelisted pool needs no hook pin (the owner vetted it whole)
        PoolKey memory hooked = _keyOf(address(s), address(toggle));
        vm.prank(owner);
        policy.setPoolWhitelisted(hooked, true);
        (reason,,,) = policy.evaluate(address(s), hooked, address(0));
        assertEq(reason, 0);
    }

    // ── path 3: token allowlist + pinned hooks ──────────────────────────────────────────────────────────

    function test_token_allowlist_path_and_hook_pins() public {
        MockStock s = new MockStock();
        vm.prank(owner);
        policy.setTokenAllowlisted(address(s), true);
        (uint8 reason, uint8 path,,) = policy.evaluate(address(s), _keyOf(address(s), address(0)), address(0));
        assertEq(reason, 0);
        assertEq(path, policy.PATH_TOKEN());
        PoolKey memory hooked = _keyOf(address(s), address(toggle));
        assertEq(_reason(address(s), hooked), policy.HOOK_NOT_PINNED());
        vm.prank(owner);
        policy.pinHook(address(toggle), true);
        assertEq(_reason(address(s), hooked), 0);
        // a v3 pool (bridged by our own hook) needs no pin
        (reason,,,) = policy.evaluate(address(s), hooked, makeAddr("v3pool"));
        assertEq(reason, 0);
    }

    // ── attach / detach / misbehaving verifiers ─────────────────────────────────────────────────────────

    function test_attach_detach() public {
        (MockPonsToken t, PoolKey memory key) = _ponsLaunch("Launch", 2);
        assertEq(_reason(address(t), key), 0);
        vm.startPrank(owner);
        vm.expectRevert(ListingPolicy.AlreadyAttached.selector);
        policy.attach(ponsVerifier);
        policy.detach(ponsVerifier);
        assertEq(policy.verifiers().length, 0);
        assertEq(_reason(address(t), key), policy.NOT_VETTED(), "detached: its launches are no longer vetted");
        vm.expectRevert(ListingPolicy.NotAttached.selector);
        policy.detach(ponsVerifier);
        vm.stopPrank();
        vm.prank(mallory);
        vm.expectRevert();
        policy.attach(ponsVerifier);
    }

    /// A verifier that reverts, burns all its gas or returns garbage just doesn't approve; the others still work.
    function test_misbehaving_verifiers_never_brick_listings() public {
        vm.startPrank(owner);
        policy.detach(ponsVerifier);
        policy.attach(ILaunchpadVerifier(address(new RevertingVerifier())));
        policy.attach(ILaunchpadVerifier(address(new GasBurnerVerifier())));
        policy.attach(ILaunchpadVerifier(address(new GarbageVerifier())));
        policy.attach(ponsVerifier);
        vm.stopPrank();
        (MockPonsToken t, PoolKey memory key) = _ponsLaunch("Launch", 2);
        uint256 g = gasleft();
        (uint8 reason, uint8 path, bytes32 id,) = policy.evaluate(address(t), key, address(0));
        emit log_named_uint("evaluate gas with a gas-burning verifier attached", g - gasleft());
        assertEq(reason, 0);
        assertEq(path, policy.PATH_LAUNCHPAD());
        assertEq(id, bytes32("pons"));
        sys.v4.registerAndList(address(t), key);
        MockStock s = new MockStock();
        vm.prank(owner);
        policy.setTokenAllowlisted(address(s), true);
        assertEq(_reason(address(s), _keyOf(address(s), address(0))), 0, "allowlist unaffected");
    }

    // ── owner override, tokens listed before ────────────────────────────────────────────────────────────

    /// Un-vetting doesn't delist: a listed token keeps settling, the guardian can disable it, and a disabled token
    /// can't be re-listed permissionlessly.
    function test_listed_token_stays_listed_and_guardian_can_disable() public {
        MockStock s = new MockStock();
        PoolKey memory k = _poolOf(address(s), IHooks(address(0)), FEE, TS);
        vm.prank(owner);
        policy.setPoolWhitelisted(k, true);
        sys.v4.registerAndList(address(s), k);
        vm.prank(owner);
        policy.setPoolWhitelisted(k, false);
        s.transfer(alice, 10_000_000 ether);
        vm.prank(alice);
        s.approve(address(house), type(uint256).max);
        uint256 id = _flip(alice, address(s), 1_000_000 ether);
        _reveal(id, LOSS_WORD);
        assertEq(uint8(_status(id)), uint8(FlipperHouseBase.Status.Lost), "still settles");
        vm.prank(owner); // also the guardian here
        house.setTokenEnabled(address(s), false);
        assertEq(house.previewFlip(address(s), 1 ether).code, 3, "disabled");
        vm.expectRevert(FlipperHouseBase.TokenBlocked.selector);
        house.listToken(address(s), sys.v4);
    }

    function test_owner_lists_anything_directly() public {
        MockStock s = new MockStock();
        PoolKey memory k = _poolOf(address(s), IHooks(address(0)), FEE, TS);
        assertEq(_reason(address(s), k), policy.NOT_VETTED());
        vm.prank(owner);
        house.setTokenRoute(address(s), _route1(k, flipperPool));
        (bool enabled,, address adapter,) = house.tokenConfig(address(s));
        assertTrue(enabled);
        assertEq(adapter, address(0));
    }

    function test_no_policy_fails_closed() public {
        vm.prank(owner);
        sys.v4.setListingPolicy(ListingPolicy(address(0)));
        (MockPonsToken t, PoolKey memory key) = _ponsLaunch("Launch", 2);
        (uint8 r,) = sys.v4.check(address(t), key);
        assertEq(r, sys.v4.NOT_VETTED(), "adapter without a policy lists nothing");
        vm.expectRevert(abi.encodeWithSelector(V4RouteAdapter.NotVetted.selector, sys.v4.NOT_VETTED(), 0));
        sys.v4.register(address(t), key);
    }

    // ── hookit verifier logic (mocks) ───────────────────────────────────────────────────────────────────

    function test_hookit_verifier_reasons() public {
        (HookitVerifier v, MockHookitHook h, MockHookitToken t, PoolKey memory key) = _hookitWith(address(0));
        _hk(v, address(t), key, true, 0);
        bytes32 pid = PoolId.unwrap(key.toId());
        IHookitMasterHook.LaunchState memory st = h.launchState(pid);
        uint256[3] memory bad = [v.ANTI_MEV(), v.MAX_TX(), v.HOLDER_AIRDROP()];
        for (uint256 i; i < bad.length; ++i) {
            h.set(pid, st, bad[i]);
            _hk(v, address(t), key, false, v.FORBIDDEN_MODULES());
        }
        h.set(pid, st, v.ANTI_SNIPE() | (uint256(600) << 23));
        _hk(v, address(t), key, false, v.SNIPE_WINDOW_LIVE());
        vm.warp(block.timestamp + 601);
        _hk(v, address(t), key, true, 0);
        PoolKey memory other = PoolKey(key.currency0, key.currency1, 3000, 60, IHooks(address(0)));
        _hk(v, address(t), other, false, v.NOT_CANONICAL_POOL());
        _hk(v, makeAddr("nobody"), key, false, v.NOT_A_LAUNCH());
        (HookitVerifier v2,, MockHookitToken tracked, PoolKey memory k2) = _hookitWith(makeAddr("tracker"));
        _hk(v2, address(tracked), k2, false, v2.HOLDER_TRACKER());
        vm.etch(address(h), abi.encodePacked(address(h).code, hex"00"));
        _hk(v, address(t), key, false, v.HOOK_CODE_CHANGED());
    }

    // ── helpers ─────────────────────────────────────────────────────────────────────────────────────────

    function _expect(address token, PoolKey memory key, uint8 reason, uint8 detail) internal view {
        (uint8 r, uint8 path,, uint8 d) = policy.evaluate(token, key, address(0));
        assertEq(r, reason, "reason");
        assertEq(path, 0, "no path");
        assertEq(d, detail, "verifier detail");
    }

    function _hk(HookitVerifier v, address token, PoolKey memory key, bool ok, uint8 reason) internal view {
        (bool o, uint8 r, bytes32 id) = v.verify(token, key);
        assertEq(o, ok, "ok");
        assertEq(r, reason, "hookit reason");
        assertEq(id, bytes32("hookit"));
    }

    function _ponsLaunch(string memory name, uint8 phase) internal returns (MockPonsToken t, PoolKey memory key) {
        t = new MockPonsToken(
            makeAddr(string.concat(name, "-dep")), address(ponsFactory), makeAddr(string.concat(name, "-crv"))
        );
        ponsFactory.set(address(t), _launched(address(t), phase));
        key = _poolOf(address(t), IHooks(address(toggle)), FEE, TS);
    }

    function _launched(address token, uint8 phase) internal pure returns (IPonsV2Factory.LaunchedToken memory l) {
        l.token = token;
        l.poolFee = FEE;
        l.tickSpacing = TS;
        l.phase = phase;
        l.exists = true;
    }

    function _keyOf(address token, address hook) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), 3000, 60, IHooks(hook));
    }

    /// @dev ETH/token pool (1 ETH = 10M token), 200 ETH deep, funded from this contract
    function _poolOf(address token, IHooks hooks, uint24 fee, int24 ts) internal returns (PoolKey memory key) {
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(token), fee, ts, hooks);
        manager.initialize(key, uint160(_sqrt(10_000_000) * 2 ** 96));
        ERC20(token).approve(address(lp), type(uint256).max);
        int256 liq = int256(200 ether * _sqrt(10_000_000));
        lp.modifyLiquidity{value: 202 ether}(
            key, IPoolManager.ModifyLiquidityParams(TickMath.minUsableTick(ts), TickMath.maxUsableTick(ts), liq, 0), ""
        );
    }

    function _hookitWith(address tracker)
        internal
        returns (HookitVerifier v, MockHookitHook h, MockHookitToken t, PoolKey memory key)
    {
        MockHookitFactory f = new MockHookitFactory();
        h = new MockHookitHook();
        // reference launch with a non-zero tracker, so the tracker's words are located and masked too
        MockHookitToken ref = new MockHookitToken(makeAddr("creator0"), makeAddr("t0"));
        uint256 offs = _immutableOffsets(address(ref), _three(makeAddr("creator0"), makeAddr("t0"), address(0)));
        bytes32 tpl = CodeTemplate.maskedHash(address(ref), address(ref).code.length, offs);
        t = new MockHookitToken(makeAddr("creator1"), tracker);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(t)), 0, 60, IHooks(address(h)));
        f.set(address(t), 7, key);
        IHookitMasterHook.LaunchState memory st;
        st.token = address(t);
        st.initialized = true;
        st.launchTimestamp = uint64(block.timestamp);
        h.set(PoolId.unwrap(key.toId()), st, 0);
        HookitVerifier.Rail[] memory rails = new HookitVerifier.Rail[](1);
        rails[0] = HookitVerifier.Rail(IHookitLaunchFactory(address(f)), address(h), address(h).codehash);
        v = new HookitVerifier(rails, (1 << 2) | (1 << 3) | (1 << 145), tpl, address(ref).code.length, offs);
    }

    function _three(address a, address b, address c) internal pure returns (address[] memory r) {
        r = new address[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    /// @dev offsets of every 32-byte word in `t`'s runtime equal to one of `vals` (its immutables), packed
    function _immutableOffsets(address t, address[] memory vals) internal view returns (uint256 packed) {
        bytes memory c = t.code;
        uint256 n;
        for (uint256 i; i + 32 <= c.length; ++i) {
            bytes32 w;
            assembly {
                w := mload(add(add(c, 32), i))
            }
            for (uint256 j; j < vals.length; ++j) {
                if (vals[j] != address(0) && w == bytes32(uint256(uint160(vals[j])))) {
                    packed |= i << (16 * n++);
                }
            }
        }
    }

    function _reason(address token, PoolKey memory key) internal view returns (uint8 r) {
        (r,,,) = policy.evaluate(token, key, address(0));
    }
}
