pragma solidity ^0.8.0;

import "../helpers/Quantity.sol";
import "hardhat/console.sol";


library Position {

    using Quantity for int256;
    enum Side {LONG, SHORT}
    struct Data {
        // TODO restruct data
        //        Position.Side side;
        int256 quantity;
        int256 sumQuantityLimitOrder;
        uint256 margin;
        uint256 openNotional;
        uint256 lastUpdatedCumulativePremiumFraction;
        uint256 blockNumber;
    }

    struct LiquidatedData {
        int256 quantity;
        uint256 margin;
        uint256 notional;
    }

    function update(
        Position.LiquidatedData storage self,
        int256 _quantity,
        uint256 _margin,
        uint256 _notional
    ) internal {
        self.quantity += _quantity;
        self.margin += _margin;
        self.notional += _notional;
    }

    function update(
        Position.Data storage self,
        Position.Data memory newPosition
    ) internal {
        self.quantity = newPosition.quantity;
        self.margin = newPosition.margin;
        self.openNotional = newPosition.openNotional;
        self.lastUpdatedCumulativePremiumFraction = newPosition.lastUpdatedCumulativePremiumFraction;
        self.blockNumber = newPosition.blockNumber;
    }

    function updatePartialLiquidate(
        Position.Data storage self,
        Position.Data memory newPosition
    ) internal {
        self.quantity += newPosition.quantity;
        self.margin -= newPosition.margin;
        self.openNotional -= newPosition.openNotional;
        self.lastUpdatedCumulativePremiumFraction += newPosition.lastUpdatedCumulativePremiumFraction;
        self.blockNumber += newPosition.blockNumber;
    }

    function clear(Position.LiquidatedData storage self) internal {
        self.quantity = 0;
        self.margin = 0;
        self.notional = 0;
    }

    function clear(
        Position.Data storage self
    ) internal {
        self.quantity = 0;
        self.margin = 0;
        self.openNotional = 0;
        self.lastUpdatedCumulativePremiumFraction = 0;
        // TODO get current block number
        self.blockNumber = 0;
    }

    function side(Position.Data memory self) internal view returns (Position.Side) {
        return self.quantity > 0 ? Position.Side.LONG : Position.Side.SHORT;
    }

    function getEntryPrice(Position.Data memory self) internal view returns (uint256){
        return self.openNotional / self.quantity.abs();
    }

    function accumulateLimitOrder(
        Position.Data memory self,
        int256 quantity,
        uint256 orderMargin,
        uint256 orderNotional
    ) internal view returns (Position.Data memory positionData) {
        // same side
        if (self.quantity * quantity > 0) {
            console.log("line 60 position.sol");
            positionData.margin = self.margin + orderMargin;
            positionData.openNotional = self.openNotional + orderNotional;
        } else {
            positionData.margin = self.margin > orderMargin ? self.margin - orderMargin : orderMargin - self.margin;
            positionData.openNotional = self.openNotional > orderNotional ? self.openNotional - orderNotional : orderNotional - self.openNotional;
//            if (self.quantity.abs() > quantity.abs()) {
//                console.log("line 64 position.sol");
//                positionData.margin = self.margin > orderMargin ? self.margin - orderMargin : orderMargin - self.margin;
//                positionData.openNotional = self.openNotional > orderNotional ? self.openNotional - orderNotional : orderNotional - self.openNotional;
//                //                positionData.margin = self.margin - orderMargin;
//                //                positionData.openNotional = self.openNotional - orderNotional;
//            } else {
//                console.log("line 70 position.sol", orderMargin, self.margin);
//                positionData.margin = orderMargin - self.margin;
//                positionData.openNotional = orderNotional - self.openNotional;
//            }
        }
        positionData.quantity = self.quantity + quantity;
    }

}
