// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mutually Assured Destruction
/// @notice Fixed-supply ERC-20: one billion MAD, with 18 decimals.
/// @dev The immediate deployer receives the entire supply. During the launch this is the factory.
/// There are no administrative powers, transfer fees, or externally callable mint/burn functions.
contract MADToken is ERC20 {
    /// @notice The permanent supply, expressed in the token's smallest units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("Mutually Assured Destruction", "MAD") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}

