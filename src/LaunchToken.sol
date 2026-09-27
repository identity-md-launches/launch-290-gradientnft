// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Gradients launch token (GRAD)
/// @notice Fixed-supply ERC-20 with no constructor arguments. The entire supply of
///         1,000,000,000 GRAD (10^27 minor units, 18 decimals) is minted once to the
///         deployer, which for the project launch is the ProjectFactory. The factory
///         routes that supply to the ETH/GRAD launch pool and the reward distributor.
/// @dev There is deliberately no owner, mint, burn-by-admin, pause, blocklist, fee or
///      upgrade path. The supply can never change after construction.
contract LaunchToken is ERC20 {
    /// @notice Total and only supply: 1,000,000,000 GRAD in 18-decimal minor units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    constructor() ERC20("Gradients", "GRAD") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
