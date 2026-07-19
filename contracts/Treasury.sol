// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
           
                                                                                            
//  _____                 _____     _             _____                                _____ ___   
// |   __|_ _ ___ ___ ___| __  |___| |_    ___   |_   _|___ ___ ___ ___ _ _ ___ _ _   |  |  |_  |  
// |__   | | | . | -_|  _| __ -| -_|  _|  |___|    | | |  _| -_| .'|_ -| | |  _| | |  |  |  |_| |_ 
// |_____|___|  _|___|_| |_____|___|_|             |_| |_| |___|__,|___|___|_| |_  |   \___/|_____|
//           |_|                                                               |___|               
//
// Superbet @ Treasury V1

contract Treasury is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    address public constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    uint256[50] private __gap;

    event NativeReceived(address indexed from, uint256 amount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    error InvalidParams();
    error NothingToWithdraw();
    error TransferFailed();

    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);
        __Ownable2Step_init();
        __ReentrancyGuard_init();
    }

    receive() external payable {
        emit NativeReceived(msg.sender, msg.value);
    }

    function balanceOf(address token) public view returns (uint256) {
        return token == NATIVE ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function withdraw(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        _withdraw(token, to, amount);
    }

    function withdrawAll(address token, address to) external onlyOwner nonReentrant {
        _withdraw(token, to, balanceOf(token));
    }

    function sweep(address[] calldata tokens, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidParams();
        for (uint256 i; i < tokens.length; ++i) {
            uint256 bal = balanceOf(tokens[i]);
            if (bal != 0) _send(tokens[i], to, bal);
        }
    }

    function _withdraw(address token, address to, uint256 amount) internal {
        if (to == address(0)) revert InvalidParams();
        if (amount == 0) revert NothingToWithdraw();
        _send(token, to, amount);
    }

    function _send(address token, address to, uint256 amount) internal {
        if (token == NATIVE) {
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Withdrawn(token, to, amount);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
