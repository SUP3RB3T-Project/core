// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";


//  _____                 _____     _             _____         _              _____ ___   
// |   __|_ _ ___ ___ ___| __  |___| |_    ___   | __  |___ _ _| |_ ___ ___   |  |  |_  |  
// |__   | | | . | -_|  _| __ -| -_|  _|  |___|  |    -| . | | |  _| -_|  _|  |  |  |_| |_ 
// |_____|___|  _|___|_| |_____|___|_|           |__|__|___|___|_| |___|_|     \___/|_____|
//           |_|                                                                           
//
// Superbet @ Router V1

interface IArenaManager {
    function createMatchFrom(
        address from, address token, address opponent, uint128 stake, uint64 acceptWindow, uint64 playWindow
    ) external returns (uint256 id);
    function acceptMatchFrom(address from, uint256 id) external;
}

contract Router is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, PausableUpgradeable {
    IArenaManager public manager;
    mapping(address => bool) public operators;

    uint256[48] private __gap;

    event OperatorSet(address indexed operator, bool allowed);
    event RoutedCreate(address indexed from, uint256 indexed id);
    event RoutedAccept(address indexed from, uint256 indexed id);

    error NotOperator();
    error LengthMismatch();

    modifier onlyOperator() {
        if (!operators[msg.sender]) revert NotOperator();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(IArenaManager _manager) external initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);
        __Ownable2Step_init();
        __Pausable_init();
        manager = _manager;
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        operators[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function createMatchFor(
        address from, address token, address opponent, uint128 stake, uint64 acceptWindow, uint64 playWindow
    ) external onlyOperator whenNotPaused returns (uint256 id) {
        id = manager.createMatchFrom(from, token, opponent, stake, acceptWindow, playWindow);
        emit RoutedCreate(from, id);
    }

    function acceptMatchFor(address from, uint256 id) external onlyOperator whenNotPaused {
        manager.acceptMatchFrom(from, id);
        emit RoutedAccept(from, id);
    }

    struct CreateParams {
        address from;
        address token;
        address opponent;
        uint128 stake;
        uint64 acceptWindow;
        uint64 playWindow;
    }

    function batchCreate(CreateParams[] calldata items)
        external onlyOperator whenNotPaused returns (uint256[] memory ids)
    {
        ids = new uint256[](items.length);
        for (uint256 i; i < items.length; ++i) {
            CreateParams calldata p = items[i];
            ids[i] = manager.createMatchFrom(p.from, p.token, p.opponent, p.stake, p.acceptWindow, p.playWindow);
            emit RoutedCreate(p.from, ids[i]);
        }
    }

    function batchAccept(address[] calldata froms, uint256[] calldata matchIds)
        external onlyOperator whenNotPaused
    {
        if (froms.length != matchIds.length) revert LengthMismatch();
        for (uint256 i; i < froms.length; ++i) {
            manager.acceptMatchFrom(froms[i], matchIds[i]);
            emit RoutedAccept(froms[i], matchIds[i]);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
