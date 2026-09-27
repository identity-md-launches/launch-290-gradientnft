// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {GradientNFT} from "../src/GradientNFT.sol";

/// @dev Exercises the local deployment helper directly; it takes no environment or configuration.
contract DeployTest is Test {
    function test_deployWiresTokenIntoNft() public {
        Deploy deployer = new Deploy();
        (LaunchToken token, GradientNFT nft) = deployer.deploy();

        assertEq(address(nft.token()), address(token));
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(address(deployer)), token.totalSupply(), "deployer holds the launch supply");
        assertEq(token.balanceOf(address(nft)), 0, "the application needs no launch-token balance");
        assertEq(nft.totalMinted(), 0);
    }

    /// @dev Mirrors the factory flow: the token is created by one account (the factory) and the
    ///      application constructor receives the token address, needing nothing else.
    function test_factoryStyleDeploymentFromAnyCaller() public {
        address factory = makeAddr("factory");
        vm.startPrank(factory);
        LaunchToken token = new LaunchToken();
        GradientNFT nft = new GradientNFT(address(token));
        vm.stopPrank();

        assertEq(token.balanceOf(factory), token.totalSupply(), "constructor did not move the launch supply");
        assertEq(address(nft.token()), address(token));
        assertEq(address(nft).code.length > 0, true);
        assertLe(address(nft).code.length, 24_576, "runtime must fit EIP-170");
    }
}
