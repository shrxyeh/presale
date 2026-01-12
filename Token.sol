// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BigRockToken is ERC20, ERC20Burnable, ERC20Pausable, Ownable {

    uint256 public constant TOTAL_SUPPLY = 10_000_000_000 * 10**18;

    constructor() ERC20("BigRock Exchange", "BRK") Ownable(msg.sender) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    ///  Pause all token transfers
    function pause() external onlyOwner {
        _pause();
    }

    /// Unpause token transfers
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Required override for ERC20Pausable
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Pausable) {
        super._update(from, to, value);
    }
}
