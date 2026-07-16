// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev TEST/TESTNET-ONLY stand-in for the real DBK NOXA: fixed 1M supply + an
/// owner-configurable transfer fee (bps) routed to a sink, so both unit tests and
/// testnet rehearsals exercise the lockbox's balance-delta accounting against a
/// fee-on-transfer token. Fee is skipped on mint/burn (from/to == 0).
contract FeeOnTransferNoxa is ERC20, Ownable {
    uint16 public feeBps;
    address public feeSink;

    constructor(address owner_) ERC20("noxa.fi", "NOXA") Ownable(owner_) {
        feeSink = owner_;
        _mint(owner_, 1_000_000 ether);
    }

    function setFee(uint16 bps) external onlyOwner {
        require(bps <= 10_000, "bad fee");
        feeBps = bps;
    }

    function setFeeSink(address sink) external onlyOwner {
        feeSink = sink;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, feeSink, fee);
        super._update(from, to, value - fee);
    }
}
