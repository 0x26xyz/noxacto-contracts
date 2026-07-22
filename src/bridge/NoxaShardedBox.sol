// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title NoxaShardedBox — a single dumb NOXA custody shard, driven by its manager
/// @notice One leaf of the sharded-custody fleet (docs/noxa-wallet-cap.md §4.1).
/// The source NOXA enforces a 25,000 max-WALLET cap on every non-excluded address,
/// so no single custody address can hold more than that. This box holds up to that
/// cap; the `NoxaLockboxManager` spawns as many boxes as needed and moves NOXA in
/// (via a plain transfer) and out (via `drain`). All policy — rate limits, replay
/// guards, box selection, the hot/cold split — lives in the manager; the box holds
/// no logic beyond "only my manager may move my NOXA out", which is the on-chain
/// teeth that keep a leaked key from touching a shard directly.
contract NoxaShardedBox {
    using SafeERC20 for IERC20;

    /// @notice The DBK NOXA token this shard custodies.
    IERC20 public immutable noxa;
    /// @notice The manager that alone may drain this shard (set once at deploy).
    address public immutable manager;

    error NotManager();
    error ZeroAddress();

    constructor(address noxa_, address manager_) {
        if (noxa_ == address(0) || manager_ == address(0)) revert ZeroAddress();
        noxa = IERC20(noxa_);
        manager = manager_;
    }

    /// @notice Move `amount` NOXA out of this shard to `to`. Manager only.
    /// NOXA arrives via a plain `transfer` from the manager (no method needed to
    /// receive), so this is the shard's ONLY NOXA-moving entry point.
    function drain(address to, uint256 amount) external {
        if (msg.sender != manager) revert NotManager();
        noxa.safeTransfer(to, amount);
    }

    /// @notice Move a NON-NOXA token off this shard. Manager only; the manager
    /// restricts this to `token != noxa`, so the custodied NOXA is never movable
    /// this way. Lets the owner recover an airdrop/mistaken transfer to a shard.
    function rescueToken(address token, address to, uint256 amount) external {
        if (msg.sender != manager) revert NotManager();
        IERC20(token).safeTransfer(to, amount);
    }
}
