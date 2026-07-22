// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test fixture mirroring the real DBK NOXA: a recipient-balance max-WALLET
/// cap enforced on every transfer, with an owner-managed exclusion list, plus an
/// optional pair-triggered fee. Used to prove the sharded manager's box routing
/// keeps every shard under the cap so NOXA never reverts (cap-doc §4.4 testing bar:
/// "simulate the cap itself in the mock NOXA").
contract MaxWalletNoxa is ERC20 {
    address internal constant SINK = 0x000000000000000000000000000000000000dEaD;

    uint256 public maxWalletAmount;
    uint256 public feeBps; // optional transfer fee, to exercise fee-on-transfer safety
    address public immutable ownerAddr;
    mapping(address => bool) public excluded;

    error MaxWalletReached(address to, uint256 balance, uint256 cap);
    error NotOwner();

    constructor(address owner_, uint256 cap_, uint256 supply_) ERC20("NOXA", "NOXA") {
        ownerAddr = owner_;
        maxWalletAmount = cap_;
        excluded[owner_] = true; // owner/faucet excluded, like the real token's owner/pairs
        _mint(owner_, supply_);
    }

    function setExcluded(address a, bool e) external {
        if (msg.sender != ownerAddr) revert NotOwner();
        excluded[a] = e;
    }

    function setMaxWallet(uint256 cap_) external {
        if (msg.sender != ownerAddr) revert NotOwner();
        maxWalletAmount = cap_;
    }

    function setFee(uint256 bps) external {
        if (msg.sender != ownerAddr) revert NotOwner();
        require(bps <= 1000, "fee too high");
        feeBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeBps != 0) {
            uint256 fee = (value * feeBps) / 10_000;
            super._update(from, SINK, fee);
            value -= fee;
        }
        super._update(from, to, value);
        if (to != address(0) && !excluded[to] && balanceOf(to) > maxWalletAmount) {
            revert MaxWalletReached(to, balanceOf(to), maxWalletAmount);
        }
    }
}
