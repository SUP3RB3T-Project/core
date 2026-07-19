// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

                                                                                                                  
//  _____                 _____     _             _____                 _____                            _____ ___   
// |   __|_ _ ___ ___ ___| __  |___| |_    ___   |  _  |___ ___ ___ ___|     |___ ___ ___ ___ ___ ___   |  |  |_  |  
// |__   | | | . | -_|  _| __ -| -_|  _|  |___|  |     |  _| -_|   | .'| | | | .'|   | .'| . | -_|  _|  |  |  |_| |_ 
// |_____|___|  _|___|_| |_____|___|_|           |__|__|_| |___|_|_|__,|_|_|_|__,|_|_|__,|_  |___|_|     \___/|_____|
//           |_|                                                                         |___|                       
//
// Superbet @ ArenaManager V1

interface IMatchArena {
    enum Outcome { Unresolved, Player1, Player2, Draw }

    function NATIVE() external view returns (address);
    function matches(uint256 id) external view returns (
        address player1, address player2, address token, uint128 stake,
        uint64 acceptDeadline, uint64 playWindow, uint64 playDeadline,
        uint8 status, uint8 outcome
    );
    function createMatchFor(
        address player1, address token, address opponent, uint128 stake, uint64 acceptWindow, uint64 playWindow
    ) external payable returns (uint256 id);
    function acceptMatchFor(address player, uint256 id) external payable;
}

contract ArenaManager is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    IMatchArena public arena;
    address public NATIVE;
    address public router;

    uint256[47] private __gap;

    event RouterUpdated(address indexed router);

    error TokenNotAllowed();
    error BadValue();
    error NotRouter();
    error NativeNotAllowedHere();

    modifier onlyRouter() {
        if (router == address(0) || msg.sender != router) revert NotRouter();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(IMatchArena _arena) external initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        arena = _arena;
        NATIVE = _arena.NATIVE();
    }

    function createMatch(address token, address opponent, uint128 stake, uint64 acceptWindow, uint64 playWindow)
        external payable whenNotPaused nonReentrant returns (uint256 id)
    {
        uint256 fwd = _pullAndPrep(token, stake);
        id = arena.createMatchFor{value: fwd}(msg.sender, token, opponent, stake, acceptWindow, playWindow);
    }

    function acceptMatch(uint256 id) external payable whenNotPaused nonReentrant {
        (, , address token, uint128 stake, , , , , ) = arena.matches(id);
        uint256 fwd = _pullAndPrep(token, stake);
        arena.acceptMatchFor{value: fwd}(msg.sender, id);
    }

    function createMatchFrom(
        address from, address token, address opponent, uint128 stake, uint64 acceptWindow, uint64 playWindow
    ) external onlyRouter whenNotPaused nonReentrant returns (uint256 id) {
        _pullFrom(from, token, stake);
        id = arena.createMatchFor(from, token, opponent, stake, acceptWindow, playWindow);
    }

    function acceptMatchFrom(address from, uint256 id) external onlyRouter whenNotPaused nonReentrant {
        (, , address token, uint128 stake, , , , , ) = arena.matches(id);
        _pullFrom(from, token, stake);
        arena.acceptMatchFor(from, id);
    }

    function setRouter(address r) external onlyOwner {
        router = r;
        emit RouterUpdated(r);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _pullAndPrep(address token, uint256 stake) internal returns (uint256 nativeToForward) {
        if (token == NATIVE) {
            if (msg.value != stake) revert BadValue();
            return stake;
        }
        if (msg.value != 0) revert BadValue();
        IERC20(token).safeTransferFrom(msg.sender, address(this), stake);
        IERC20(token).forceApprove(address(arena), stake);
        return 0;
    }

    function _pullFrom(address from, address token, uint256 stake) internal {
        if (token == NATIVE) revert NativeNotAllowedHere();
        IERC20(token).safeTransferFrom(from, address(this), stake);
        IERC20(token).forceApprove(address(arena), stake);
    }
}
