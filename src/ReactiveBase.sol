// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

abstract contract AbstractReactive {
    address public reactor;

    constructor(address _reactor) {
        reactor = _reactor;
    }

    modifier onlyReactor() {
        require(msg.sender == reactor);
        _;
    }

    function setReactor(address _reactor) external onlyReactor {
        require(_reactor != address(0));
        reactor = _reactor;
    }

    function onEvent(bytes32 topic, bytes calldata payload) external virtual;
}
