// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

interface IMeroTriHopCvx {
    function setHopImbalanceToleranceIn(uint256 _hopImbalanceToleranceIn) external;

    function setHopImbalanceToleranceOut(uint256 _hopImbalanceToleranceOut) external;

    function changeConvexPool(
        uint256 convexPid_,
        address curvePool_,
        uint256 curveIndex_
    ) external;
}
