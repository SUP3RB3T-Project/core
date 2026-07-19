// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
                    
                                                                                                        
//  _____                 _____     _             _____     _       _   _____                    _____ ___   
// |   __|_ _ ___ ___ ___| __  |___| |_    ___   |     |___| |_ ___| |_|  _  |___ ___ ___ ___   |  |  |_  |  
// |__   | | | . | -_|  _| __ -| -_|  _|  |___|  | | | | .'|  _|  _|   |     |  _| -_|   | .'|  |  |  |_| |_ 
// |_____|___|  _|___|_| |_____|___|_|           |_|_|_|__,|_| |___|_|_|__|__|_| |___|_|_|__,|   \___/|_____|
//           |_|                                                                                             
//
// Superbet @ MatchArena V1

contract MatchArena is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    address public constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint16 public constant MAX_FEE_BPS = 1000;
    uint64 public constant RESOLVE_GRACE = 1 hours;

    enum Status { None, Open, Active, Resolved, Cancelled }
    enum Outcome { Unresolved, Player1, Player2, Draw }

    struct Match {
        address player1;
        address player2;
        address token;
        uint128 stake;
        uint64  acceptDeadline;
        uint64  playWindow;
        uint64  playDeadline;
        Status  status;
        Outcome outcome;
    }

    address public treasury;
    address public resolver;
    address public manager;
    uint16  public feeBps;

    mapping(address => bool) public whitelisted;
    uint256 public nextMatchId;
    mapping(uint256 => Match) public matches;
    mapping(address => mapping(address => uint256)) public claimable;

    uint256[45] private __gap;

    event TokenWhitelisted(address indexed token, bool allowed);
    event MatchCreated(uint256 indexed id, address indexed player1, address indexed player2, address token, uint128 stake, uint64 acceptDeadline, uint64 playWindow);
    event MatchAccepted(uint256 indexed id, uint64 playDeadline);
    event MatchResolved(uint256 indexed id, Outcome outcome, address winner, uint256 payout, uint256 fee);
    event MatchCancelled(uint256 indexed id, string reason);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event ResolverUpdated(address indexed resolver);
    event ManagerUpdated(address indexed manager);
    event TreasuryUpdated(address indexed treasury);
    event FeeUpdated(uint16 feeBps);

    error NotResolver();
    error NotManager();
    error BadState();
    error NotParticipant();
    error DeadlinePassed();
    error DeadlineNotReached();
    error InvalidParams();
    error TokenNotAllowed();
    error BadValue();
    error NothingToClaim();
    error TransferFailed();

    modifier onlyResolver() {
        if (msg.sender != resolver) revert NotResolver();
        _;
    }

    modifier onlyManager() {
        if (manager == address(0) || msg.sender != manager) revert NotManager();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address _treasury, address _resolver, uint16 _feeBps, address[] calldata initialTokens)
        external
        initializer
    {
        if (_treasury == address(0) || _resolver == address(0) || _feeBps > MAX_FEE_BPS) revert InvalidParams();
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        treasury = _treasury;
        resolver = _resolver;
        feeBps = _feeBps;
        nextMatchId = 1;
        for (uint256 i; i < initialTokens.length; ++i) {
            whitelisted[initialTokens[i]] = true;
            emit TokenWhitelisted(initialTokens[i], true);
        }
    }

    function createMatch(address token, address opponent, uint128 stake, uint64 acceptWindow, uint64 playWindow)
        external payable whenNotPaused nonReentrant returns (uint256 id)
    {
        return _create(msg.sender, token, opponent, stake, acceptWindow, playWindow);
    }

    function createMatchFor(
        address player1, address token, address opponent, uint128 stake, uint64 acceptWindow, uint64 playWindow
    ) external payable onlyManager whenNotPaused nonReentrant returns (uint256 id) {
        return _create(player1, token, opponent, stake, acceptWindow, playWindow);
    }

    function acceptMatch(uint256 id) external payable whenNotPaused nonReentrant {
        _accept(id, msg.sender);
    }

    function acceptMatchFor(address player, uint256 id) external payable onlyManager whenNotPaused nonReentrant {
        _accept(id, player);
    }

    function _create(
        address player1, address token, address opponent, uint128 stake, uint64 acceptWindow, uint64 playWindow
    ) internal returns (uint256 id) {
        if (!whitelisted[token]) revert TokenNotAllowed();
        if (stake == 0 || opponent == address(0) || opponent == player1 || player1 == address(0)
            || acceptWindow == 0 || playWindow == 0) revert InvalidParams();

        id = nextMatchId++;
        matches[id] = Match({
            player1: player1,
            player2: opponent,
            token: token,
            stake: stake,
            acceptDeadline: uint64(block.timestamp) + acceptWindow,
            playWindow: playWindow,
            playDeadline: 0,
            status: Status.Open,
            outcome: Outcome.Unresolved
        });

        _pullStake(token, msg.sender, stake);
        emit MatchCreated(id, player1, opponent, token, stake, matches[id].acceptDeadline, playWindow);
    }

    function _accept(uint256 id, address accepter) internal {
        Match storage m = matches[id];
        if (m.status != Status.Open) revert BadState();
        if (accepter != m.player2) revert NotParticipant();
        if (block.timestamp > m.acceptDeadline) revert DeadlinePassed();

        m.status = Status.Active;
        m.playDeadline = uint64(block.timestamp) + m.playWindow;

        _pullStake(m.token, msg.sender, m.stake);
        emit MatchAccepted(id, m.playDeadline);
    }

    function resolveMatch(uint256 id, Outcome outcome) external onlyResolver nonReentrant {
        Match storage m = matches[id];
        if (m.status != Status.Active) revert BadState();
        if (block.timestamp > uint256(m.playDeadline) + RESOLVE_GRACE) revert DeadlinePassed();
        if (outcome == Outcome.Unresolved) revert InvalidParams();

        m.status = Status.Resolved;
        m.outcome = outcome;

        uint256 pot = uint256(m.stake) * 2;
        if (outcome == Outcome.Draw) {
            _payout(m.token, m.player1, m.stake);
            _payout(m.token, m.player2, m.stake);
            emit MatchResolved(id, outcome, address(0), 0, 0);
            return;
        }
        address winner = outcome == Outcome.Player1 ? m.player1 : m.player2;
        uint256 fee = (pot * feeBps) / 10_000;
        uint256 payout = pot - fee;
        _payout(m.token, treasury, fee);
        _payout(m.token, winner, payout);
        emit MatchResolved(id, outcome, winner, payout, fee);
    }

    function cancelUnaccepted(uint256 id) external nonReentrant {
        Match storage m = matches[id];
        if (m.status != Status.Open) revert BadState();
        if (block.timestamp <= m.acceptDeadline) revert DeadlineNotReached();
        m.status = Status.Cancelled;
        _payout(m.token, m.player1, m.stake);
        emit MatchCancelled(id, "unaccepted");
    }

    function refundStale(uint256 id) external nonReentrant {
        Match storage m = matches[id];
        if (m.status != Status.Active) revert BadState();
        if (block.timestamp <= uint256(m.playDeadline) + RESOLVE_GRACE) revert DeadlineNotReached();
        m.status = Status.Cancelled;
        _payout(m.token, m.player1, m.stake);
        _payout(m.token, m.player2, m.stake);
        emit MatchCancelled(id, "stale");
    }

    function withdraw(address token) external nonReentrant {
        uint256 amt = claimable[token][msg.sender];
        if (amt == 0) revert NothingToClaim();
        claimable[token][msg.sender] = 0;
        _sendRaw(token, msg.sender, amt);
        emit Withdrawn(token, msg.sender, amt);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setTokenWhitelist(address token, bool allowed) external onlyOwner {
        whitelisted[token] = allowed;
        emit TokenWhitelisted(token, allowed);
    }

    function setResolver(address r) external onlyOwner {
        if (r == address(0)) revert InvalidParams();
        resolver = r;
        emit ResolverUpdated(r);
    }

    function setManager(address m) external onlyOwner {
        manager = m;
        emit ManagerUpdated(m);
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert InvalidParams();
        treasury = t;
        emit TreasuryUpdated(t);
    }

    function setFee(uint16 bps) external onlyOwner {
        if (bps > MAX_FEE_BPS) revert InvalidParams();
        feeBps = bps;
        emit FeeUpdated(bps);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function isResolved(uint256 id) external view returns (bool resolved, Outcome outcome) {
        Match storage m = matches[id];
        return (m.status == Status.Resolved, m.outcome);
    }

    function _pullStake(address token, address from, uint256 amount) internal {
        if (token == NATIVE) {
            if (msg.value != amount) revert BadValue();
        } else {
            if (msg.value != 0) revert BadValue();
            IERC20(token).safeTransferFrom(from, address(this), amount);
        }
    }

    function _payout(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == NATIVE) {
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) claimable[token][to] += amount;
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function _sendRaw(address token, address to, uint256 amount) internal {
        if (token == NATIVE) {
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
