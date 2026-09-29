// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {FlipperBase} from "./utils/FlipperBase.sol";
import {FlipperHouse} from "../src/FlipperHouse.sol";
import {FlipperHouseBase} from "../src/house/FlipperHouseBase.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {MockVRFWrapper} from "../src/mocks/MockVRFWrapper.sol";
import {IEntropyV2} from "../src/interfaces/IEntropyV2.sol";
import {IVRFV2PlusWrapper} from "../src/interfaces/IVRFV2PlusWrapper.sol";
import {FlipperDeploy} from "../script/lib/FlipperDeploy.sol";
import {RobinhoodAddresses} from "../script/lib/RobinhoodAddresses.sol";
import {InkAddresses} from "../script/lib/InkAddresses.sol";

/// @notice A listed token that turns hostile after the flip: it can burn every gas-capped call the settlement makes
///         into it, make a swap attempt use (almost) its whole cap, or revert with the largest payload it can afford.
contract HostileToken {
    uint256 internal constant BURN_BALANCE = 1; // balanceOf(house) burns all it is given
    uint256 internal constant BURN_PAY = 2; // house → player transfers burn all they are given
    uint256 internal constant BURN_TAKE = 4; // PoolManager → house (a buy's output) burns all it is given
    uint256 internal constant HOG_TAKE = 8; // PoolManager → house burns all but ~40k, then succeeds
    uint256 internal constant BOMB_SETTLE = 16; // house → PoolManager reverts with a payload as large as it can
    uint256 internal constant HOG_SETTLE = 32; // house → PoolManager burns all but ~40k, then succeeds
    uint256 internal constant BURN_SETTLE = 64; // house → PoolManager burns all it is given

    string public constant name = "Hostile";
    string public constant symbol = "HOST";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) internal _bal;
    mapping(address => bool) public isHouse;
    address public pm;
    uint256 public mode;

    function setup(address _house, address _pm) external {
        isHouse[_house] = true;
        pm = _pm;
    }

    function setMode(uint256 m) external {
        mode = m;
    }

    function mint(address to, uint256 amount) external {
        _bal[to] += amount;
        totalSupply += amount;
    }

    function balanceOf(address a) external view returns (uint256) {
        if (mode & BURN_BALANCE != 0 && isHouse[a]) _burnAll();
        return _bal[a];
    }

    function approve(address s, uint256 amount) external returns (bool) {
        allowance[msg.sender][s] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 m = mode;
        if (msg.sender == pm && isHouse[to]) {
            if (m & BURN_TAKE != 0) _burnAll();
            if (m & HOG_TAKE != 0) _hog();
        } else if (isHouse[msg.sender] && to == pm) {
            if (m & BURN_SETTLE != 0) _burnAll();
            if (m & HOG_SETTLE != 0) _hog();
            if (m & BOMB_SETTLE != 0) _bomb();
        } else if (isHouse[msg.sender] && m & BURN_PAY != 0) {
            _burnAll();
        }
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        _bal[from] -= amount;
        _bal[to] += amount;
    }

    function _burnAll() internal pure {
        while (true) {}
    }

    function _hog() internal view {
        while (gasleft() > 40_000) {}
    }

    /// @dev revert with ~1/5 of the remaining gas spent on memory: the frames above can still afford to bubble it
    function _bomb() internal view {
        uint256 words = _sqrt(gasleft() * 512 / 5);
        assembly {
            revert(0, mul(words, 32))
        }
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}

/// @notice Every out-of-gas path of a settlement, at the smallest callback budgets `setParams` accepts and at both
///         chains' defaults: the flipped token burns every capped call, swap attempts burn (or nearly exhaust) their
///         caps and the fallback quote reverts with a returndata bomb. The callback
///         must still complete (Chainlink never re-delivers, so a callback that runs out of gas strands the flip), in
///         a status anyone can resolve.
contract SettlementGasTest is FlipperBase {
    uint256 internal constant BURN_BALANCE = 1;
    uint256 internal constant BURN_PAY = 2;
    uint256 internal constant BURN_TAKE = 4;
    uint256 internal constant HOG_TAKE = 8;
    uint256 internal constant BOMB_SETTLE = 16;
    uint256 internal constant HOG_SETTLE = 32;
    uint256 internal constant BURN_SETTLE = 64;
    uint256 internal constant ROBINHOOD_GAS_PRICE = 55_800_000;

    MockVRFWrapper internal wrapper;
    FlipperHouse internal clHouse;
    HostileToken internal host;
    PoolKey internal hostPool;

    function setUp() public override {
        super.setUp();
        vm.txGasPrice(ROBINHOOD_GAS_PRICE);
        wrapper = new MockVRFWrapper(MockVRFWrapper.Config(13_400, 104_500, 435, 60, 0, 2_500_000, 0));
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
        clHouse = FlipperDeploy.deployCore(
            c, r, IERC20(address(flipperToken)), FlipperDeploy.deployChainlinkAdapter(c, IVRFV2PlusWrapper(address(wrapper)), 1)
        ).house;
        flipperToken.approve(address(clHouse), type(uint256).max);
        clHouse.depositTreasury(50_000_000 ether);

        // 1 ETH = 10,000,000 HOST, hookless pool
        host = new HostileToken();
        host.setup(address(house), address(manager));
        host.setup(address(clHouse), address(manager));
        hostPool = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(host)), FEE, TS, IHooks(address(0)));
        manager.initialize(hostPool, uint160(_sqrt(10_000_000) * 2 ** 96));
        host.mint(address(this), type(uint128).max);
        host.approve(address(lp), type(uint256).max);
        _addFullRange(hostPool, 200 ether, 10_000_000);
        host.mint(alice, 1_000_000_000 ether);

        vm.prank(owner);
        house.setTokenRoute(address(host), _route1(hostPool, flipperPool));
        clHouse.setTokenRoute(address(host), _route1(hostPool, flipperPool));
        vm.startPrank(alice);
        host.approve(address(house), type(uint256).max);
        host.approve(address(clHouse), type(uint256).max);
        vm.stopPrank();
    }

    // ── Chainlink (exact-gas, never re-delivered): Robinhood ────────────────────────────────────────────

    function test_chainlink_minimum_budget_never_strands() public {
        _setBudget(clHouse, 150_000, 150_000 + 350_000); // smallest swap cap, smallest budget
        _allScenariosChainlink();
        _setBudget(clHouse, 500_000, 850_000);
        _allScenariosChainlink();
    }

    function test_chainlink_robinhood_defaults_never_strand() public {
        FlipperHouseBase.Params memory p = RobinhoodAddresses.defaultParams();
        _setBudget(clHouse, p.swapGasLimit, p.callbackGasLimit);
        _allScenariosChainlink();
    }

    // ── Pyth Entropy (first attempt gas-limited; a failure would need a safe-mode recovery): Ink ──────────

    function test_pyth_minimum_budget_never_fails_first_attempt() public {
        FlipperHouseBase.Params memory p = InkAddresses.defaultParams();
        _setBudget(house, p.swapGasLimit, p.swapGasLimit + 350_000);
        _allScenariosPyth();
    }

    function test_pyth_ink_defaults_never_fail_first_attempt() public {
        FlipperHouseBase.Params memory p = InkAddresses.defaultParams();
        _setBudget(house, p.swapGasLimit, p.callbackGasLimit);
        _allScenariosPyth();
    }

    /// The relation `setParams` enforces: one full attempt plus the settlement reserve.
    function test_budget_relation() public {
        FlipperHouseBase.Params memory p = defaultParams();
        p.swapGasLimit = 500_000;
        p.callbackGasLimit = 849_999;
        vm.expectRevert(FlipperHouseBase.InvalidParams.selector);
        clHouse.setParams(p);
        p.callbackGasLimit = 850_000;
        clHouse.setParams(p);
    }

    // ── scenarios ───────────────────────────────────────────────────────────────────────────────────────

    struct Scenario {
        string name;
        uint256 word;
        uint256 mode;
    }

    function _scenarios() internal pure returns (Scenario[6] memory s) {
        uint256 hostile = BURN_BALANCE | BURN_PAY;
        // the buy burns its cap, the fallback quote bombs, the stake refund burns → pending win, stake claimable
        s[0] = Scenario("win: buy burnt, quote bombed", WIN_WORD, hostile | BURN_TAKE | BOMB_SETTLE);
        // the buy burns its cap, the fallback quote burns what it gets → pending win
        s[1] = Scenario("win: buy burnt, quote burnt", WIN_WORD, hostile | BURN_TAKE | BURN_SETTLE);
        // the buy burns its cap, the fallback quote uses nearly all it gets and succeeds → fallback bonus
        s[2] = Scenario("win: buy burnt, quote hogged", WIN_WORD, hostile | BURN_TAKE | HOG_SETTLE);
        // the buy uses nearly its whole cap and succeeds, then every payment burns → won, paid as claimable
        s[3] = Scenario("win: buy hogged", WIN_WORD, hostile | HOG_TAKE);
        // the sale burns its cap → inventory
        s[4] = Scenario("loss: sale burnt", LOSS_WORD, hostile | BURN_SETTLE);
        // the sale uses nearly its whole cap and succeeds → lost, rewards hook burns
        s[5] = Scenario("loss: sale hogged", LOSS_WORD, hostile | HOG_SETTLE);
    }

    function _allScenariosChainlink() internal {
        Scenario[6] memory s = _scenarios();
        for (uint256 i; i < s.length; ++i) {
            host.setMode(0);
            (uint256 id, uint256 rid) = _flipOn(clHouse);
            host.setMode(s[i].mode);
            uint256 g = gasleft();
            bool success = wrapper.fulfillWithWord{gas: 5_000_000}(rid, s[i].word);
            g -= gasleft();
            host.setMode(0);
            FlipperHouseBase.Status st = _st(clHouse, id);
            emit log_named_uint(string.concat(s[i].name, " -> status"), uint8(st));
            emit log_named_uint("   fulfilment gas", g);
            assertTrue(success, string.concat(s[i].name, ": callback ran out of gas"));
            _assertResolvable(st, s[i].word);
        }
    }

    function _allScenariosPyth() internal {
        Scenario[6] memory s = _scenarios();
        for (uint256 i; i < s.length; ++i) {
            host.setMode(0);
            uint256 id = _flipOnPyth();
            host.setMode(s[i].mode);
            uint256 g = gasleft();
            entropy.reveal{gas: 12_000_000}(provider, _seq(id), bytes32(s[i].word));
            g -= gasleft();
            host.setMode(0);
            FlipperHouseBase.Status st = _status(id);
            emit log_named_uint(string.concat(s[i].name, " -> status"), uint8(st));
            emit log_named_uint("   reveal gas", g);
            assertTrue(st != FlipperHouseBase.Status.Pending, string.concat(s[i].name, ": first attempt failed"));
            _assertResolvable(st, s[i].word);
        }
    }

    function _assertResolvable(FlipperHouseBase.Status st, uint256 word) internal pure {
        if (word == WIN_WORD) {
            assertTrue(
                st == FlipperHouseBase.Status.Won || st == FlipperHouseBase.Status.WonFallback
                    || st == FlipperHouseBase.Status.WinPending,
                "win settled"
            );
        } else {
            assertTrue(st == FlipperHouseBase.Status.Lost || st == FlipperHouseBase.Status.LostInventory, "loss settled");
        }
    }

    function _flipOn(FlipperHouse h) internal returns (uint256 id, uint256 requestId) {
        uint256 fee = h.randomnessFeeFor(address(host));
        vm.prank(alice);
        id = h.flip{value: fee}(address(host), 1_000_000 ether, 0, block.timestamp);
        (,,,,,,,,,, requestId,) = h.flips(id);
    }

    function _flipOnPyth() internal returns (uint256 id) {
        uint256 fee = house.randomnessFeeFor(address(host));
        vm.prank(alice);
        id = house.flip{value: fee}(address(host), 1_000_000 ether, 0, block.timestamp);
    }

    function _st(FlipperHouse h, uint256 id) internal view returns (FlipperHouseBase.Status st) {
        (,,,, st,,,,,,,) = h.flips(id);
    }

    function _setBudget(FlipperHouse h, uint32 swapGas, uint32 cbGas) internal {
        FlipperHouseBase.Params memory p = h.params();
        p.swapGasLimit = swapGas;
        p.callbackGasLimit = cbGas;
        vm.prank(h.owner());
        h.setParams(p);
    }
}
