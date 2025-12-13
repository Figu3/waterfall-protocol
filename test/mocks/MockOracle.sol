// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockOracle {
    int256 private _price;

    constructor(int256 initialPrice) {
        _price = initialPrice;
    }

    function latestAnswer() external view returns (int256) {
        return _price;
    }

    function setPrice(int256 newPrice) external {
        _price = newPrice;
    }
}
