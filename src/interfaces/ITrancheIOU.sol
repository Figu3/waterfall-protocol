// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ITrancheIOU is IERC20 {
    function vault() external view returns (address);
    function trancheIndex() external view returns (uint8);
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}
