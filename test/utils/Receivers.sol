// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GradientNFT} from "../../src/GradientNFT.sol";

/// @dev A minter whose `onERC721Received` re-enters `mint` once, recording the outcome.
contract ReentrantMinter is IERC721Receiver {
    GradientNFT public immutable nft;
    IERC20 public immutable token;

    uint256 public reentryQuantity;
    bool public reentered;
    bool public reentrySucceeded;
    bytes public reentryError;
    uint256 public callbacks;

    constructor(GradientNFT nft_, IERC20 token_) {
        nft = nft_;
        token = token_;
    }

    function approve(uint256 amount) external {
        token.approve(address(nft), amount);
    }

    function mint(uint256 quantity, uint256 reentryQuantity_) external {
        reentryQuantity = reentryQuantity_;
        reentered = false;
        reentrySucceeded = false;
        delete reentryError;
        nft.mint(quantity);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external override returns (bytes4) {
        callbacks++;
        if (!reentered && reentryQuantity != 0) {
            reentered = true;
            try nft.mint(reentryQuantity) {
                reentrySucceeded = true;
            } catch (bytes memory err) {
                reentryError = err;
            }
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev A receiver that always rejects, to show a rejected safe-mint rolls the whole call back.
contract RejectingReceiver is IERC721Receiver {
    GradientNFT public immutable nft;
    IERC20 public immutable token;

    constructor(GradientNFT nft_, IERC20 token_) {
        nft = nft_;
        token = token_;
    }

    function approve(uint256 amount) external {
        token.approve(address(nft), amount);
    }

    function mint(uint256 quantity) external {
        nft.mint(quantity);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        revert("no thanks");
    }
}

/// @dev A contract with no `onERC721Received` at all.
contract NonReceiver {
    GradientNFT public immutable nft;
    IERC20 public immutable token;

    constructor(GradientNFT nft_, IERC20 token_) {
        nft = nft_;
        token = token_;
    }

    function approve(uint256 amount) external {
        token.approve(address(nft), amount);
    }

    function mint(uint256 quantity) external {
        nft.mint(quantity);
    }
}
