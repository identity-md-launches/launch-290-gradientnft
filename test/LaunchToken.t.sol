// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000e18;

    LaunchToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.prank(deployer);
        token = new LaunchToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Gradients");
        assertEq(token.symbol(), "GRAD");
        assertEq(token.decimals(), 18);
    }

    function test_supplyIsExactlyOneBillionMintedToDeployer() public view {
        assertEq(EXPECTED_SUPPLY, 10 ** 27, "10^27 minor units");
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), alice, EXPECTED_SUPPLY);
        vm.prank(alice);
        new LaunchToken();
    }

    function test_transferMovesExactAmount() public {
        uint256 amount = 123_456e18;
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "transfer must not change supply");
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice) + token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_transferRevertsWhenBalanceInsufficient() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferFromRequiresAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 100e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 50e18));
        token.transferFrom(alice, bob, 50e18);

        vm.prank(alice);
        token.approve(bob, 50e18);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 50e18));
        assertEq(token.balanceOf(bob), 50e18);
        assertEq(token.allowance(alice, bob), 0);
    }

    /// @dev The token exposes no mint, owner or admin selectors; calling them must not change supply.
    function test_noMintOrAdminSelectors() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(address,uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], deployer, uint256(1));
            vm.prank(deployer);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), EXPECTED_SUPPLY, signatures[i]);
        }
    }

    function test_rejectsEth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "token must not accept ETH");
        assertEq(address(token).balance, 0);
    }
}
