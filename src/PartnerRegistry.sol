// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/// @title PartnerRegistry
/// @notice Partners (wallets, apps, widgets) that bring flips to the house earn a share of each attributed flip's
///         expected profit, part of which they can hand back to their players as better odds.
///
///   - Registration is approval-gated: anyone registers a code (`register`), the owner approves it into a tier
///     (`approve`), and may re-tier or suspend it later. Each tier's cut (`tierCutBps`) is a share of the flip's
///     expected house profit; the house caps it so its own edge never drops below `minHouseEdgeBps`.
///   - The partner's controller sets the payout address and `discountBps`: the share of the cut returned to the
///     player as win chance. Changes apply to new flips only (the house captures everything at flip time).
///   - Attribution: flips carry an ERC-8021 data suffix after their arguments — `codes ‖ codesLength (1 byte) ‖
///     schemaId (1 byte) ‖ 0x80218021802180218021802180218021`, schema 0: ASCII codes separated by commas. The
///     house hands that tail to `resolve`; the first approved code wins. A player can't attribute their own flips
///     (player == payout or controller) unless the owner allows it for that partner.
///   - The registry holds no funds: the house accrues each partner's share and pays it to the payout address
///     (`FlipperHouse.claimPartner`).
///
///   Deployed behind a TransparentUpgradeableProxy; storage is append-only.
contract PartnerRegistry is Ownable2StepUpgradeable {
    enum Status {
        None,
        Pending,
        Approved,
        Suspended
    }

    struct Partner {
        address controller;
        address payout;
        uint16 discountBps;
        uint8 tier;
        Status status;
        bool allowSelf;
        string code;
    }

    bytes16 internal constant ERC8021_MARKER = 0x80218021802180218021802180218021;
    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_CODE_LENGTH = 32;
    /// the most a tier may take of a flip's expected house profit
    uint16 public constant MAX_TIER_CUT_BPS = 5000;

    Partner[] internal _partners; // id = index + 1
    mapping(bytes32 codeHash => uint256 id) public idOfCode;
    mapping(uint8 tier => uint16 cutBps) public tierCutBps;

    event PartnerRegistered(uint256 indexed id, string code, address controller, address payout, uint16 discountBps);
    event PartnerApproved(uint256 indexed id, uint8 tier);
    event PartnerSuspended(uint256 indexed id, bool suspended);
    event PartnerUpdated(uint256 indexed id, address payout, uint16 discountBps);
    event PartnerControllerSet(uint256 indexed id, address controller);
    event PartnerSelfAttribution(uint256 indexed id, bool allowed);
    event TierCutSet(uint8 indexed tier, uint16 cutBps);

    error InvalidCode();
    error CodeTaken();
    error InvalidParams();
    error UnknownPartner();
    error NotController();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner) external initializer {
        __Ownable_init(_owner);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Partners
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Register `code` (1–32 chars of [a-z0-9_-]) with the caller as controller. Starts Pending.
    function register(string calldata code, address payout, uint16 discountBps) external returns (uint256 id) {
        bytes memory c = bytes(code);
        if (c.length == 0 || c.length > MAX_CODE_LENGTH) revert InvalidCode();
        for (uint256 i; i < c.length; ++i) {
            bytes1 ch = c[i];
            bool ok = (ch >= 0x61 && ch <= 0x7a) || (ch >= 0x30 && ch <= 0x39) || ch == 0x5f || ch == 0x2d;
            if (!ok) revert InvalidCode();
        }
        bytes32 h = keccak256(c);
        if (idOfCode[h] != 0) revert CodeTaken();
        if (payout == address(0) || discountBps > BPS) revert InvalidParams();
        _partners.push(Partner(msg.sender, payout, discountBps, 0, Status.Pending, false, code));
        id = _partners.length;
        idOfCode[h] = id;
        emit PartnerRegistered(id, code, msg.sender, payout, discountBps);
    }

    function setPayout(uint256 id, address payout) external {
        Partner storage p = _controlled(id);
        if (payout == address(0)) revert InvalidParams();
        p.payout = payout;
        emit PartnerUpdated(id, payout, p.discountBps);
    }

    /// @notice Share of the partner cut returned to players as better odds (0–10000). New flips only.
    function setDiscount(uint256 id, uint16 discountBps) external {
        Partner storage p = _controlled(id);
        if (discountBps > BPS) revert InvalidParams();
        p.discountBps = discountBps;
        emit PartnerUpdated(id, p.payout, discountBps);
    }

    function setController(uint256 id, address controller) external {
        Partner storage p = _controlled(id);
        if (controller == address(0)) revert InvalidParams();
        p.controller = controller;
        emit PartnerControllerSet(id, controller);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // Owner
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function approve(uint256 id, uint8 tier) external onlyOwner {
        Partner storage p = _partner(id);
        p.tier = tier;
        p.status = Status.Approved;
        emit PartnerApproved(id, tier);
    }

    function setSuspended(uint256 id, bool suspended) external onlyOwner {
        Partner storage p = _partner(id);
        if (p.status == Status.Pending && !suspended) revert InvalidParams(); // reinstating needs approval
        p.status = suspended ? Status.Suspended : Status.Approved;
        emit PartnerSuspended(id, suspended);
    }

    function setAllowSelf(uint256 id, bool allowed) external onlyOwner {
        _partner(id).allowSelf = allowed;
        emit PartnerSelfAttribution(id, allowed);
    }

    function setTierCut(uint8 tier, uint16 cutBps) external onlyOwner {
        if (cutBps > MAX_TIER_CUT_BPS) revert InvalidParams();
        tierCutBps[tier] = cutBps;
        emit TierCutSet(tier, cutBps);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────
    // House interface
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Resolve a flip's calldata tail (an ERC-8021 suffix) into the partner it attributes to.
    /// @return partnerId 0 when none (no suffix, unknown / unapproved code, self-attribution)
    function resolve(address player, bytes calldata tail)
        external
        view
        returns (uint256 partnerId, uint256 cutBps, uint256 discountBps)
    {
        uint256 n = tail.length;
        if (n < 18 || bytes16(tail[n - 16:n]) != ERC8021_MARKER || uint8(tail[n - 17]) != 0) return (0, 0, 0);
        uint256 len = uint8(tail[n - 18]);
        if (len == 0 || n < 18 + len) return (0, 0, 0);
        uint256 start = n - 18 - len;
        uint256 end = n - 18;
        uint256 from = start;
        for (uint256 i = start; i <= end; ++i) {
            if (i == end || tail[i] == 0x2c) {
                if (i > from) {
                    uint256 id = idOfCode[keccak256(tail[from:i])];
                    if (id != 0) {
                        Partner storage p = _partners[id - 1];
                        if (p.status == Status.Approved && (p.allowSelf || (player != p.payout && player != p.controller))) {
                            return (id, tierCutBps[p.tier], p.discountBps);
                        }
                    }
                }
                from = i + 1;
            }
        }
    }

    function payoutOf(uint256 id) external view returns (address) {
        if (id == 0 || id > _partners.length) return address(0);
        return _partners[id - 1].payout;
    }

    function partner(uint256 id) external view returns (Partner memory) {
        return _partner(id);
    }

    function partnersLength() external view returns (uint256) {
        return _partners.length;
    }

    /// @notice The ERC-8021 schema-0 suffix for `code` (append it to `flip` calldata).
    function suffixOf(string calldata code) external pure returns (bytes memory) {
        if (bytes(code).length == 0 || bytes(code).length > 255) revert InvalidCode();
        return abi.encodePacked(code, uint8(bytes(code).length), uint8(0), ERC8021_MARKER);
    }

    function _partner(uint256 id) internal view returns (Partner storage) {
        if (id == 0 || id > _partners.length) revert UnknownPartner();
        return _partners[id - 1];
    }

    function _controlled(uint256 id) internal view returns (Partner storage p) {
        p = _partner(id);
        if (msg.sender != p.controller) revert NotController();
    }
}
