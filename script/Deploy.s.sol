// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {GradientNFT} from "../src/GradientNFT.sol";

/// @title Local deployment helper
/// @notice The Sepolia launch is performed by the ProjectFactory from launch.json, not by this
///         script. This script exists so a local chain (anvil) or a test can reproduce the same
///         two-step deployment: the token first, then GradientNFT pointing at it.
/// @dev `deploy()` takes no configuration because neither contract has any: LaunchToken has no
///      constructor arguments and GradientNFT only needs the token address that `deploy()` just
///      created. Tests call `deploy()` directly; `run()` only wraps it in a broadcast.
contract Deploy is Script {
    /// @notice Deploy the token and then the NFT bound to it. The caller receives the token supply.
    function deploy() public returns (LaunchToken token, GradientNFT nft) {
        token = new LaunchToken();
        nft = new GradientNFT(address(token));
    }

    /// @notice Broadcast entry point for a local or development chain only.
    function run() external returns (LaunchToken token, GradientNFT nft) {
        vm.startBroadcast();
        (token, nft) = deploy();
        vm.stopBroadcast();
    }
}
