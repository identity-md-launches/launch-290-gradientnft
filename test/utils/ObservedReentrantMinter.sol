// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {GradientNFT} from "../../src/GradientNFT.sol";

/// @dev Observes accounting inside callbacks, attempts one nested mint (including quantity zero),
/// and can reject a later outer token after a successful nested mint.
contract ObservedReentrantMinter is IERC721Receiver {
    uint256 private constant PRICE = 10_000e18;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    GradientNFT public immutable nft;
    LaunchToken public immutable token;
    uint256 private immutable initialDeadBalance;
    uint256 private immutable initialMinted;

    uint256[] public receivedIds;
    uint256 public firstCallbackSupply;
    uint256 public firstCallbackBurnGain;
    bool public callbackAccountingMismatch;
    bool public attempted;
    bool public succeeded;
    bytes public innerError;
    uint256 private innerQuantity;
    uint256 private rejectId;

    error CallbackRejected(uint256 id);

    constructor(GradientNFT nft_, LaunchToken token_) {
        nft = nft_;
        token = token_;
        initialDeadBalance = token_.balanceOf(DEAD);
        initialMinted = nft_.totalMinted();
    }

    function approve(uint256 amount) external {
        token.approve(address(nft), amount);
    }

    function mint(uint256 outer, uint256 inner, uint256 rejectId_) external {
        delete receivedIds;
        delete innerError;
        attempted = false;
        succeeded = false;
        callbackAccountingMismatch = false;
        innerQuantity = inner;
        rejectId = rejectId_;
        nft.mint(outer);
    }

    function callbackCount() external view returns (uint256) {
        return receivedIds.length;
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        require(msg.sender == address(nft), "unexpected NFT");
        receivedIds.push(id);
        uint256 supply = nft.totalMinted();
        uint256 burnGain = token.balanceOf(DEAD) - initialDeadBalance;
        if (
            supply > 1_000 || burnGain != PRICE * (supply - initialMinted) || nft.burnedTotal() != PRICE * supply
                || token.balanceOf(address(nft)) != 0 || address(nft).balance != 0
        ) callbackAccountingMismatch = true;

        if (!attempted) {
            firstCallbackSupply = supply;
            firstCallbackBurnGain = burnGain;
            attempted = true;
            try nft.mint(innerQuantity) {
                succeeded = true;
            } catch (bytes memory reason) {
                innerError = reason;
            }
        }

        if (id == rejectId) revert CallbackRejected(id);
        return IERC721Receiver.onERC721Received.selector;
    }
}
