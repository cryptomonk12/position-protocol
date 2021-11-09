pragma solidity ^0.8.0;

import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "../interfaces/IPositionManager.sol";
import "./libraries/position/Position.sol";
import "hardhat/console.sol";
import "./PositionManager.sol";
import "./libraries/helpers/Quantity.sol";
import "./libraries/position/PositionLimitOrder.sol";
import "../interfaces/IInsuranceFund.sol";
import "../interfaces/IFeePool.sol";


contract PositionHouse is Initializable, ReentrancyGuardUpgradeable, OwnableUpgradeable
{
    using PositionLimitOrder for mapping(address => mapping(address => PositionLimitOrder.Data[]));
    using Quantity for int256;
    using Quantity for int128;

    using Position for Position.Data;
    using Position for Position.LiquidatedData;

    enum PnlCalcOption {
        TWAP,
        SPOT_PRICE,
        ORACLE
    }

    struct PositionResp {

        Position.Data position;
        // NOTICE margin to vault can be negative
        int256 marginToVault;

        int256 realizedPnl;

        int256 unrealizedPnl;

        int256 exchangedPositionSize;

        uint256 exchangedQuoteAssetAmount;

        uint256 fundingPayment;

    }


    struct LimitOrderPending {
        // TODO restruct data
        Position.Side side;
        int256 quantity;
        uint256 openNotional;
        uint256 pip;
        uint256 partialFilled;
        uint256 leverage;
        uint24 blockNumber;
    }


    struct PositionManagerData {
        uint24 blockNumber;
        int256[] cumulativePremiumFraction;
        // Position data of each trader
        mapping(address => Position.Data) positionMap;
        mapping(address => PositionLimitOrder.Data[]) limitOrders;
        mapping(address => PositionLimitOrder.Data[]) reduceLimitOrders;
        // Amount that trader can claim from exchange
        mapping(address => int256) canClaimAmount;
    }
    // TODO change separate mapping to positionManagerMap
    mapping(address => PositionManagerData) public positionManagerMap;

    // Can join positionMap and cumulativePremiumFractionsMap into a map of struct with key is PositionManager's address
    // Mapping from position manager address of each pair to position data of each trader
    mapping(address => mapping(address => Position.Data)) public positionMap;
    mapping(address => int256[]) public cumulativePremiumFractionsMap;

    mapping(address => mapping(address => Position.LiquidatedData)) public debtPosition;


    //can update with index => no need delete array when close all
    mapping(address => mapping(address => PositionLimitOrder.Data[])) public limitOrders;
    mapping(address => mapping(address => PositionLimitOrder.Data[])) public reduceLimitOrders;

    uint256 maintenanceMarginRatio;
    uint256 partialLiquidationRatio;
    uint256 liquidationFeeRatio;
    uint256 liquidationPenaltyRatio;

    IInsuranceFund public insuranceFund;
    IFeePool public feePool;

    modifier whenNotPause(){
        //TODO implement
        _;
    }

    event OpenMarket(
        address trader,
        int256 quantity,
        uint256 leverage,
        uint256 priceMarket,
        IPositionManager positionManager
    );
    event OpenLimit(
        uint64 orderIdOfTrader,
        uint64 orderId,
        address trader,
        int256 quantity,
        uint256 leverage,
        int128 priceLimit,
        IPositionManager positionManager
    );

    event UpdateMaintenanceMarginRatio (
        uint256 newMaintenanceMarginRatio
    );

    event UpdateLiquidationFeeRatio (
        uint256 newLiquidationFeeRatio
    );

    event UpdateLiquidationPenaltyRatio (
        uint256 newLiquidationPenaltyRatio
    );

    event AddMargin(address trader, uint256 marginAdded, IPositionManager positionManager);

    event RemoveMargin(address trader, uint256 marginRemoved, IPositionManager positionManager);


    event Liquidate();

    function initialize(
        uint256 _maintenanceMarginRatio,
        uint256 _partialLiquidationRatio,
        uint256 _liquidationFeeRatio,
        uint256 _liquidationPenaltyRatio
    ) public initializer {
        maintenanceMarginRatio = _maintenanceMarginRatio;
        partialLiquidationRatio = _partialLiquidationRatio;
        liquidationFeeRatio = _liquidationFeeRatio;
        liquidationPenaltyRatio = _liquidationPenaltyRatio;
    }

    /**
     * @notice set liquidation fee ratio
     * @dev only owner can call
     * @param _liquidationFeeRatio new liquidation fee ratio
     */
    function updateLiquidationFeeRatio(uint256 _liquidationFeeRatio) external onlyOwner {
        liquidationFeeRatio = _liquidationFeeRatio;
        emit UpdateLiquidationFeeRatio(liquidationFeeRatio);
    }

    /**
     * @notice set maintenance margin ratio
     * @dev only owner can call
     * @param _maintenanceMarginRatio new maintenance margin ratio
     */
    function updateMaintenanceMarginRatio(uint256 _maintenanceMarginRatio) external onlyOwner {
        maintenanceMarginRatio = _maintenanceMarginRatio;
        emit UpdateMaintenanceMarginRatio(maintenanceMarginRatio);
    }

    /**
     * @notice set liquidation penalty ratio
     * @dev only owner can call
     * @param _liquidationPenaltyRatio new liquidation penalty ratio
     */
    function updateLiquidationPenaltyRatio(uint256 _liquidationPenaltyRatio) external onlyOwner {
        liquidationPenaltyRatio = _liquidationPenaltyRatio;
        emit UpdateLiquidationPenaltyRatio(liquidationPenaltyRatio);
    }

    /**
     * @notice set the margin ratio after deleveraging
     * @dev only owner can call
     */
    function setPartialLiquidationRatio(uint256 _ratio) external onlyOwner {
        // invalid partial liquidation ratio
        require(_ratio > 0, "IPLR");
        partialLiquidationRatio = _ratio;
    }

    /**
    * @notice open position with price market
    * @param _positionManager IPositionManager address
    * @param _side Side of position LONG or SHORT
    * @param _quantity quantity of size after mul with leverage
    * @param _leverage leverage of position
    */
    function openMarketPosition(
        IPositionManager _positionManager,
        Position.Side _side,
        uint256 _quantity,
        uint256 _leverage
    ) public whenNotPause nonReentrant {
        // TODO add require
        address _trader = _msgSender();
        //TODO check is new Position
        Position.Data memory oldPosition = getPosition(address(_positionManager), _trader);
        PositionResp memory positionResp;
        // check if old position quantity is same side with new
        if (oldPosition.quantity == 0 || oldPosition.side() == _side) {
            positionResp = increasePosition(_positionManager, _side, int256(_quantity), _leverage);
        } else {
            // TODO adjust old position
            positionResp = openReversePosition(_positionManager, _side, _side == Position.Side.LONG ? int256(_quantity) : - int256(_quantity), _leverage);
        }
        // update position sate
        positionMap[address(_positionManager)][_trader].update(
            positionResp.position
        );

        address quoteToken = address(_positionManager.getQuoteAsset());
        if (positionResp.marginToVault > 0) {
            //transfer from trader to vault
            insuranceFund.deposit(quoteToken, _trader, positionResp.marginToVault.abs());
        } else if (positionResp.marginToVault < 0) {
            // withdraw from vault to user
            insuranceFund.withdraw(quoteToken, _trader, positionResp.marginToVault.abs());
        }
        emit OpenMarket(_trader, _side == Position.Side.LONG ? int256(_quantity) : - int256(_quantity), _leverage, positionResp.exchangedQuoteAssetAmount / _quantity, _positionManager);
    }

    struct OpenLimitResp {
        uint64 orderId;
        uint256 sizeOut;
        //        uint256 openNotional;
    }

    /**
    * @notice open position with price limit
    * @param _positionManager IPositionManager address
    * @param _side Side of position LONG or SHORT
    * @param _quantity quantity of size after mul with leverage
    * @param _pip is pip converted from limit price of position
    * @param _leverage leverage of position
    */
    function openLimitOrder(
        IPositionManager _positionManager,
        Position.Side _side,
        uint256 _quantity,
        int128 _pip,
        uint256 _leverage
    ) public whenNotPause nonReentrant {
        address _trader = _msgSender();
        uint64 orderIdOfUser;
        OpenLimitResp memory openLimitResp;
        (, openLimitResp.orderId, openLimitResp.sizeOut) = openLimitIncludeMarket(_positionManager, _trader, _pip, int256(_quantity).abs128(), _side == Position.Side.LONG ? true : false, _leverage);
        {

            PositionLimitOrder.Data memory _newOrder = PositionLimitOrder.Data({
            pip : _pip,
            orderId : openLimitResp.orderId,
            leverage : uint16(_leverage),
            isBuy : _side == Position.Side.LONG ? 1 : 2,
            entryPrice : 0,
            reduceQuantity : 0
            });
            orderIdOfUser = handleLimitOrderInOpenLimit(openLimitResp, _newOrder, _positionManager, _trader, _quantity, _side);


        }
        insuranceFund.deposit(address(_positionManager.getQuoteAsset()), _trader, _quantity*_positionManager.pipToPrice(_pip)/_leverage);
        emit OpenLimit(orderIdOfUser, openLimitResp.orderId, _trader, _side == Position.Side.LONG ? int256(_quantity) : - int256(_quantity), _leverage, _pip, _positionManager);
    }

    function handleLimitOrderInOpenLimit(OpenLimitResp memory openLimitResp, PositionLimitOrder.Data memory _newOrder, IPositionManager _positionManager, address _trader, uint256 _quantity, Position.Side _side) internal returns (uint64 orderIdOfUser) {
        Position.Data memory _oldPosition = getPosition(address(_positionManager), _trader);
        if (_oldPosition.quantity == 0 || _side == (_oldPosition.quantity > 0 ? Position.Side.LONG : Position.Side.SHORT)) {
            limitOrders[address(_positionManager)][_trader].push(_newOrder);
            orderIdOfUser = uint64(limitOrders[address(_positionManager)][_trader].length - 1);
        } else {
            // if new limit order is smaller than old position then just reduce old position
            if (_oldPosition.quantity.abs() >= _quantity) {
                _newOrder.reduceQuantity = _quantity - openLimitResp.sizeOut;
                _newOrder.entryPrice = _oldPosition.openNotional / _oldPosition.quantity.abs();
                reduceLimitOrders[address(_positionManager)][_trader].push(_newOrder);
                orderIdOfUser = uint64(reduceLimitOrders[address(_positionManager)][_trader].length - 1);
            }
            // else new limit order is larger than old position then close old position and open new opposite position
            else {
                _newOrder.reduceQuantity = _oldPosition.quantity.abs();
                limitOrders[address(_positionManager)][_trader].push(_newOrder);
                orderIdOfUser = uint64(limitOrders[address(_positionManager)][_trader].length - 1);
                _newOrder.entryPrice = _oldPosition.openNotional / _oldPosition.quantity.abs();
                reduceLimitOrders[address(_positionManager)][_trader].push(_newOrder);
            }
        }
    }

    function cancelLimitOrder(IPositionManager _positionManager, uint64 orderIdOfTrader, int128 pip, uint64 orderId) external {
        address _trader = _msgSender();
        uint256 refundQuantity = _positionManager.cancelLimitOrder(pip, orderId);
        int128 oldOrderPip = limitOrders[address(_positionManager)][_trader][orderIdOfTrader].pip;
        uint64 oldOrderId = limitOrders[address(_positionManager)][_trader][orderIdOfTrader].orderId;
        uint16 leverage;
        if (pip == oldOrderPip && orderId == oldOrderId){
            leverage = limitOrders[address(_positionManager)][_trader][orderIdOfTrader].leverage;
        } else {
            leverage = reduceLimitOrders[address(_positionManager)][_trader][orderIdOfTrader].leverage;
        }


        uint256 refundMargin = refundQuantity * _positionManager.pipToPrice(pip) / uint256(leverage);

        // TODO send back margin to trader
    }

    /**
    * @notice close position with close market
    * @param _positionManager IPositionManager address
    * @param _percentQuantity want to close
    */
    function closePosition(
        IPositionManager _positionManager,
        uint256 _percentQuantity
    ) public {


        // check conditions
        requirePositionManager(_positionManager, true);

        address _trader = _msgSender();
        Position.Data memory positionData = getPosition(address(_positionManager), _trader);
        // IMPORTANT UPDATE FORMULA WITH LEVERAGE
        uint256 oldPositionLeverage = positionData.openNotional / positionData.margin;
        PositionResp memory positionResp;
        if (positionData.quantity > 0) {
            openMarketPosition(_positionManager, Position.Side.SHORT, uint256(positionData.quantity) * _percentQuantity / 100, oldPositionLeverage);
        } else {
            openMarketPosition(_positionManager, Position.Side.LONG, uint256(- positionData.quantity) * _percentQuantity / 100, oldPositionLeverage);
        }

    }


    /**
    * @notice close position with close market
    * @param _positionManager IPositionManager address
    * @param _pip limit price want to close
    * @param _percentQuantity want to close
    */
    function closeLimitPosition(IPositionManager _positionManager, int128 _pip, uint256 _percentQuantity) public {

        // check conditions
        requirePositionManager(_positionManager, true);

        address _trader = _msgSender();
        Position.Data memory positionData = getPosition(address(_positionManager), _trader);

        uint256 oldPositionLeverage = positionData.openNotional / positionData.margin;

        if (positionData.quantity > 0) {
            openLimitOrder(_positionManager, Position.Side.SHORT, uint256(positionData.quantity) * _percentQuantity / 100, _pip, oldPositionLeverage);
        } else {
            openLimitOrder(_positionManager, Position.Side.LONG, uint256(- positionData.quantity) * _percentQuantity / 100, _pip, oldPositionLeverage);
        }
    }

    function claimFund(IPositionManager _positionManager) public {

        address _trader = _msgSender();

        (bool canClaim, int256 amount, int256 realPnL) = canClaimFund(_positionManager, _trader);

        if (canClaim) {

            // TODO transfer amount fund back to _trader and clean limitOrders of _trader

            // TODO check the case close limit partial, should we delete the limit order have been closed

            Position.Data memory positionData = getPosition(address(_positionManager), _trader);

            // ensure no has order any more => after
            if (positionData.quantity == 0) {
                clearPosition(_positionManager, _trader);
            } else {
                PositionLimitOrder.Data[] memory listLimitOrder = limitOrders[address(_positionManager)][_trader];
                for (uint i = 0; i < listLimitOrder.length; i ++) {
                    //                    amount = _positionManager.closeLimitOrder(listLimitOrder[i].pip, listLimitOrder[i].orderId, amount);

                }

                if (amount > 0) {
                    // TODO reduce in market order
                    //                    positionMap[address(_positionManager)][_trader].clear();

                }

            }
        }
    }

    function canClaimFund(IPositionManager _positionManager, address _trader) public view returns (bool canClaim, int256 amount, int256 realPnL){

        PositionLimitOrder.Data[] memory reduceLimitOrder = reduceLimitOrders[address(_positionManager)][_trader];
        Position.Data memory positionData = getPositionWithoutCloseLimitOrder(address(_positionManager), _trader);
        for (uint i = 0; i < reduceLimitOrder.length; i ++) {
            (bool isFilled, bool isBuy, uint256 quantity, uint256 partialFilled) = _positionManager.getPendingOrderDetail(reduceLimitOrder[i].pip, reduceLimitOrder[i].orderId);
            if (isFilled == false) {
                (amount, realPnL, positionData) = _calcRealPnL(_positionManager, positionData, partialFilled, reduceLimitOrder[i].pip, amount, realPnL);
            } else {
                (amount, realPnL, positionData) = _calcRealPnL(_positionManager, positionData, quantity, reduceLimitOrder[i].pip, amount, realPnL);
            }
        }
        return amount + realPnL > 0 ? (true, amount, realPnL) : (false, 0, 0);
    }




    /**
     * @notice liquidate trader's underwater position. Require trader's margin ratio more than partial liquidation ratio
     * @dev liquidator can NOT open any positions in the same block to prevent from price manipulation.
     * @param _positionManager positionManager address
     * @param _trader trader address
     */
    function liquidate(
        IPositionManager _positionManager,
        address _trader
    ) external {
        requirePositionManager(_positionManager, true);
        (uint256 maintenanceMargin, int256 marginBalance, uint256 marginRatio) = getMaintenanceDetail(_positionManager, _trader);

        // TODO before liquidate should we check can claimFund, because trader has close position limit before liquidate

        // require trader's margin ratio higher than partial liquidation ratio
        requireMoreMarginRatio(marginRatio);

        PositionResp memory positionResp;
        uint256 liquidationPenalty;
        {
            uint256 feeToLiquidator;
            uint256 feeToInsuranceFund;
            // partially liquidate position
            if (marginRatio >= partialLiquidationRatio && marginRatio < 100) {
                Position.Data memory positionData = getPosition(address(_positionManager), _trader);
                // TODO define rate of liquidationPenalty
                // calculate amount quantity of position to reduce
                int256 partiallyLiquidateQuantity = positionData.quantity * int256(liquidationPenaltyRatio) / 100;
                uint256 oldPositionLeverage = positionData.openNotional / positionData.margin;
                // partially liquidate position by reduce position's quantity
                if (positionData.quantity > 0) {
                    positionResp = partialLiquidate(_positionManager, Position.Side.SHORT, - partiallyLiquidateQuantity, oldPositionLeverage, _trader);
                } else {
                    positionResp = partialLiquidate(_positionManager, Position.Side.LONG, - partiallyLiquidateQuantity, oldPositionLeverage, _trader);
                }

                // half of the liquidationFee goes to liquidator & another half goes to insurance fund
                liquidationPenalty = uint256(positionResp.marginToVault);
                feeToLiquidator = liquidationPenalty / 2;
                feeToInsuranceFund = liquidationPenalty - feeToLiquidator;
                // TODO take liquidation fee

            } else {
                // fully liquidate trader's position
                liquidationPenalty = getPosition(address(_positionManager), _trader).margin;
                clearPosition(_positionManager, _trader);
                feeToLiquidator = liquidationPenalty * liquidationFeeRatio / 100;
            }

            // count as bad debt, transfer money to insurance fund and liquidator
            // emit event position liquidated
        }

        // emit event
    }



    /**
     * @notice add margin to decrease margin ratio
     * @param _positionManager IPositionManager address
     * @param _marginAdded added margin
     */
    function addMargin(IPositionManager _positionManager, uint256 _marginAdded) external {

        address _trader = _msgSender();
        Position.Data memory positionData = getPosition(address(_positionManager), _trader);
        positionData.margin = positionData.margin + _positionManager.calcAdjustMargin(_marginAdded);

        positionMap[address(_positionManager)][_trader].update(
            positionData
        );

        // TODO transfer money from trader to protocol


        emit AddMargin(_trader, _marginAdded, _positionManager);

    }


    /**
     * @notice add margin to increase margin ratio
     * @param _positionManager IPositionManager address
     * @param _marginRemoved added margin
     */
    function removeMargin(IPositionManager _positionManager, uint256 _marginRemoved) external {

        address _trader = _msgSender();

        Position.Data memory positionData = getPosition(address(_positionManager), _trader);

        _marginRemoved = _positionManager.calcAdjustMargin(_marginRemoved);
        require(positionData.margin > _marginRemoved, "Margin remove not than old margin");
        (uint256 remainMargin,,) =

        calcRemainMarginWithFundingPayment(positionData.margin - _marginRemoved);

        positionData.margin = remainMargin;

        positionMap[address(_positionManager)][_trader].update(
            positionData
        );


        // TODO transfer money back to trader

    }

    /**
     * @notice clear all attribute of
     * @param _positionManager IPositionManager address
     * @param _trader address to clean position
     */
    // IMPORTANT UPDATE CLEAR LIMIT ORDER
    function clearPosition(IPositionManager _positionManager, address _trader) internal {
        positionMap[address(_positionManager)][_trader].clear();
        debtPosition[address(_positionManager)][_trader].clearDebt();
        if (limitOrders[address(_positionManager)][_trader].length > 0) {
            delete limitOrders[address(_positionManager)][_trader];
        }
        if (reduceLimitOrders[address(_positionManager)][_trader].length > 0) {
            delete reduceLimitOrders[address(_positionManager)][_trader];
        }
    }


    function sumQuantityLimitOrder(IPositionManager _positionManager, address _trader) internal view returns (int256 _sumQuantity){

        PositionLimitOrder.Data[] memory listLimitOrder = limitOrders[address(_positionManager)][_trader];
        PositionLimitOrder.Data[] memory reduceOrders = limitOrders[address(_positionManager)][_trader];


        for (uint i = 0; i < listLimitOrder.length; i ++) {
            (bool isFilled, bool isBuy, uint256 quantity, uint256 partialFilled) = _positionManager.getPendingOrderDetail(listLimitOrder[i].pip, listLimitOrder[i].orderId);

            if (isFilled) {
                _sumQuantity += isBuy ? int256(quantity) : - int256(quantity);
            } else if (!isFilled && partialFilled != 0) {
                _sumQuantity += isBuy ? int256(partialFilled) : - int256(partialFilled);
            }
        }
        for (uint i = 0; i < reduceOrders.length; i ++) {
            (bool isFilled, bool isBuy, uint256 quantity, uint256 partialFilled) = _positionManager.getPendingOrderDetail(reduceOrders[i].pip, reduceOrders[i].orderId);

            if (isFilled) {
                _sumQuantity += isBuy ? int256(quantity) : - int256(quantity);
            } else if (!isFilled && partialFilled != 0) {
                _sumQuantity += isBuy ? int256(partialFilled) : - int256(partialFilled);
            }
        }
        return _sumQuantity;
    }

    function increasePosition(
        IPositionManager _positionManager,
        Position.Side _side,
        int256 _quantity,
        uint256 _leverage
    ) internal returns (PositionResp memory positionResp) {
        address _trader = _msgSender();
        Position.Data memory oldPosition = getPosition(address(_positionManager), _trader);
        (positionResp.exchangedPositionSize, positionResp.exchangedQuoteAssetAmount) = openMarketOrder(_positionManager, _quantity.abs(), _side);
        if (positionResp.exchangedPositionSize != 0) {
            int256 _newSize = oldPosition.quantity + positionResp.exchangedPositionSize - oldPosition.sumQuantityLimitOrder;
            uint256 increaseMarginRequirement = positionResp.exchangedQuoteAssetAmount / _leverage;
            // TODO update function latestCumulativePremiumFraction
            // NEW FUNCTION handleMarginInIncrease
            (uint256 remainMargin, uint256 fundingPayment, int256 latestCumulativePremiumFraction) =
            calcRemainMarginWithFundingPayment(handleMarginInIncrease(address(_positionManager), _trader, increaseMarginRequirement));

            (, int256 unrealizedPnl) = getPositionNotionalAndUnrealizedPnl(_positionManager, _trader, PnlCalcOption.SPOT_PRICE);

            // update positionResp
            positionResp.unrealizedPnl = unrealizedPnl;
            positionResp.realizedPnl = 0;
            // checked margin to vault
            positionResp.marginToVault = int256(increaseMarginRequirement);
            positionResp.fundingPayment = fundingPayment;
            positionResp.position = Position.Data(
                _newSize,
                0,
                remainMargin,
            // NEW FUNCTION handleNotionalInIncrease
                handleNotionalInIncrease(address(_positionManager), _trader, positionResp.exchangedQuoteAssetAmount),
                latestCumulativePremiumFraction,
                block.number
            );
        }
    }

    function openReversePosition(
        IPositionManager _positionManager,
        Position.Side _side,
        int256 _quantity,
        uint256 _leverage
    ) internal returns (PositionResp memory positionResp) {

        address _trader = _msgSender();
        PositionResp memory positionResp;
        Position.Data memory oldPosition = getPosition(address(_positionManager), _trader);

        if (_quantity.abs() <= oldPosition.quantity.abs()) {
            uint256 reduceMarginRequirement = oldPosition.margin * _quantity.abs() / oldPosition.quantity.abs();
            // reduce old position only
            (positionResp.exchangedPositionSize,) = openMarketOrder(_positionManager, _quantity.abs(), _side);

            (, int256 unrealizedPnl) = getPositionNotionalAndUnrealizedPnl(_positionManager, _trader, PnlCalcOption.SPOT_PRICE);
            positionResp.realizedPnl = unrealizedPnl * int256(positionResp.exchangedPositionSize) / oldPosition.quantity;
            // NEW FUNCTION handleMarginInOpenReverse
            (uint256 remainMargin, uint256 fundingPayment, int256 latestCumulativePremiumFraction) =
            calcRemainMarginWithFundingPayment(handleMarginInOpenReverse(address(_positionManager), _trader, reduceMarginRequirement));
            positionResp.exchangedQuoteAssetAmount = _quantity.abs() * oldPosition.getEntryPrice();
            positionResp.fundingPayment = fundingPayment;
            // NOTICE margin to vault can be negative
            // checked margin to vault
            positionResp.marginToVault = - (int256(reduceMarginRequirement) + positionResp.realizedPnl);
            // NOTICE calc unrealizedPnl after open reverse
            positionResp.unrealizedPnl = unrealizedPnl - positionResp.realizedPnl;
            positionResp.position = Position.Data(
                oldPosition.quantity + _quantity - oldPosition.sumQuantityLimitOrder,
                0,
                remainMargin,
            // NEW FUNCTION handleNotionalInOpenReverse
                handleNotionalInOpenReverse(address(_positionManager), _trader, positionResp.exchangedQuoteAssetAmount),
                latestCumulativePremiumFraction,
                block.number
            );
            return positionResp;
        }
        // if new position is larger then close old and open new
        return closeAndOpenReversePosition(_positionManager, _side, _quantity, _leverage, oldPosition.openNotional);
    }

    function closeAndOpenReversePosition(
        IPositionManager _positionManager,
        Position.Side _side,
        int256 _quantity,
        uint256 _leverage,
        uint256 _oldOpenNotional
    ) internal returns (PositionResp memory positionResp) {
        address _trader = _msgSender();
        // TODO change to TWAP
        PositionResp memory closePositionResp = internalClosePosition(_positionManager, _trader, PnlCalcOption.SPOT_PRICE);
        // if remainQuantity == 0 means no more quantity to open reverse position
        if (_quantity - closePositionResp.exchangedPositionSize == 0) {
            //        if (openNotional < _leverage) {
            positionResp = closePositionResp;
        } else {
            PositionResp memory increasePositionResp = increasePosition(_positionManager, _side, _quantity - closePositionResp.exchangedPositionSize, _leverage);
            positionResp = PositionResp({
            // IMPORTANT update positionResp include closePositionResp
            position : increasePositionResp.position,
            exchangedQuoteAssetAmount : closePositionResp.exchangedQuoteAssetAmount + increasePositionResp.exchangedQuoteAssetAmount,
            fundingPayment : closePositionResp.fundingPayment + increasePositionResp.fundingPayment,
            exchangedPositionSize : closePositionResp.exchangedPositionSize + increasePositionResp.exchangedPositionSize,
            realizedPnl : closePositionResp.realizedPnl + increasePositionResp.realizedPnl,
            unrealizedPnl : 0,
            // checked margin to vault
            marginToVault : closePositionResp.marginToVault + increasePositionResp.marginToVault
            });
        }
        return positionResp;
    }

    function internalClosePosition(
        IPositionManager _positionManager,
        address _trader,
        PnlCalcOption _pnlCalcOption
    ) internal returns (PositionResp memory positionResp) {
        Position.Data memory oldPosition = getPosition(address(_positionManager), _trader);
        requirePositionSize(oldPosition.quantity);
        if (oldPosition.quantity > 0) {
            // sell
            (positionResp.exchangedPositionSize, positionResp.exchangedQuoteAssetAmount) = openMarketOrder(_positionManager, oldPosition.quantity.abs(), Position.Side.SHORT);
        } else {
            // buy
            (positionResp.exchangedPositionSize, positionResp.exchangedQuoteAssetAmount) = openMarketOrder(_positionManager, oldPosition.quantity.abs(), Position.Side.LONG);
        }

        //        uint256 _currentPrice = _positionManager.getPrice();
        (, int256 unrealizedPnl) = getPositionNotionalAndUnrealizedPnl(_positionManager, _trader, _pnlCalcOption);
        (
        uint256 remainMargin,
        uint256 fundingPayment,
        int256 latestCumulativePremiumFraction
        ) = calcRemainMarginWithFundingPayment(0);

        positionResp.realizedPnl = unrealizedPnl;
        positionResp.fundingPayment = fundingPayment;
        // NOTICE remainMargin can be negative
        // unchecked: should be -(remainMargin + unrealizedPnl) and update remainMargin with fundingPayment
        positionResp.marginToVault = - (int256(remainMargin) + positionResp.realizedPnl);
        positionResp.unrealizedPnl = 0;
        //        positionResp.exchangedQuoteAssetAmount = oldPosition.quantity.abs() * _currentPrice;
        clearPosition(_positionManager, _trader);
    }

    function handleMarketQuantityInLimitOrder(address _positionManager, address _trader, uint256 _newQuantity, uint256 _newNotional, uint256 _leverage, bool _isBuy) internal {
        Position.Data memory newData;
        Position.Data memory marketPositionData = positionMap[_positionManager][_trader];
        Position.Data memory totalPositionData = getPosition(_positionManager, _trader);
        int256 newPositionSide = _isBuy == true ? int256(1) : int256(- 1);
        if (newPositionSide * totalPositionData.quantity >= 0) {
            if (newPositionSide * marketPositionData.quantity >= 0) {
                newData = Position.Data(
                    marketPositionData.quantity > 0 ? marketPositionData.quantity + int256(_newQuantity) : marketPositionData.quantity - int256(_newQuantity),
                    0,
                    handleMarginInIncrease(address(_positionManager), _trader, _newNotional / _leverage),
                    handleNotionalInIncrease(address(_positionManager), _trader, _newNotional),
                // TODO update latest cumulative premium fraction
                    0,
                    0
                );
            } else {
                newData = Position.Data(
                    marketPositionData.quantity < 0 ? marketPositionData.quantity + int256(_newQuantity) : marketPositionData.quantity - int256(_newQuantity),
                    0,
                    handleMarginInIncrease(address(_positionManager), _trader, _newNotional / _leverage),
                    handleNotionalInIncrease(address(_positionManager), _trader, _newNotional),
                // TODO update latest cumulative premium fraction
                    0,
                    0
                );
            }
        } else {
            if (newPositionSide * marketPositionData.quantity >= 0) {
                newData = Position.Data(
                    marketPositionData.quantity > 0 ? marketPositionData.quantity + int256(_newQuantity) : marketPositionData.quantity - int256(_newQuantity),
                    0,
                    handleMarginInOpenReverse(address(_positionManager), _trader, totalPositionData.margin * _newQuantity / totalPositionData.quantity.abs()),
                    handleNotionalInOpenReverse(address(_positionManager), _trader, _newNotional),
                // TODO update latest cumulative premium fraction
                    0,
                    0
                );
            } else {
                newData = Position.Data(
                    marketPositionData.quantity < 0 ? marketPositionData.quantity + int256(_newQuantity) : marketPositionData.quantity - int256(_newQuantity),
                    0,
                    handleMarginInOpenReverse(address(_positionManager), _trader, totalPositionData.margin * _newQuantity / totalPositionData.quantity.abs()),
                    handleNotionalInOpenReverse(address(_positionManager), _trader, _newNotional),
                // TODO update latest cumulative premium fraction
                    0,
                    0
                );
            }
        }
        positionMap[_positionManager][_trader].update(
            newData
        );
    }

    function openLimitIncludeMarket(IPositionManager _positionManager, address _trader, int128 _pip, uint128 _quantity, bool _isBuy, uint256 _leverage) internal returns (PositionResp memory positionResp, uint64 orderId, uint256 sizeOut){
        {
            //            Position.Data memory marketPositionData = positionMap[address(_positionManager)][_trader];
            Position.Data memory totalPositionData = getPosition(address(_positionManager), _trader);
            (int128 currentPip, uint8 isFullBuy) = _positionManager.getCurrentSingleSlot();
            uint256 openNotional;
            //1: buy
            //2: sell
            if (_pip == currentPip && isFullBuy != (_isBuy ? 1 : 2)) {
                uint128 liquidityInCurrentPip = _positionManager.getLiquidityInPip(_pip);
                if (totalPositionData.quantity.abs() <= liquidityInCurrentPip && totalPositionData.quantity.abs() <= _quantity && totalPositionData.quantity.abs() != 0) {
                    {
                        PositionResp memory closePositionResp = internalClosePosition(_positionManager, _trader, PnlCalcOption.SPOT_PRICE);
                        if (_quantity - closePositionResp.exchangedPositionSize == 0) {
                            positionResp = closePositionResp;
                        } else {
                            (orderId, sizeOut, openNotional) = _positionManager.openLimitPosition(_pip, _quantity - (closePositionResp.exchangedPositionSize).abs128(), _isBuy);
                        }
                    }
                } else {
                    (orderId, sizeOut, openNotional) = _positionManager.openLimitPosition(_pip, _quantity, _isBuy);
                }
                handleMarketQuantityInLimitOrder(address(_positionManager), _trader, sizeOut, openNotional, _leverage, _isBuy);
            } else {
                (orderId, sizeOut, openNotional) = _positionManager.openLimitPosition(_pip, _quantity, _isBuy);
            }
        }

    }

    function handleNotionalInOpenReverse(address _positionManager, address _trader, uint256 exchangedQuoteAmount) internal returns (uint256 openNotional) {
        Position.Data memory marketPositionData = positionMap[_positionManager][_trader];
        Position.Data memory totalPositionData = getPosition(_positionManager, _trader);
        int256 newPositionSide = totalPositionData.quantity < 0 ? int256(1) : int256(- 1);
        if (marketPositionData.quantity * totalPositionData.quantity < 0) {
            if (marketPositionData.quantity * newPositionSide > 0) {
                openNotional = marketPositionData.openNotional + exchangedQuoteAmount;
            } else {
                openNotional = marketPositionData.openNotional - exchangedQuoteAmount;
            }
        } else if (marketPositionData.quantity == 0) {
            openNotional = exchangedQuoteAmount;
        } else {
            openNotional = marketPositionData.openNotional > exchangedQuoteAmount ? marketPositionData.openNotional - exchangedQuoteAmount : exchangedQuoteAmount - marketPositionData.openNotional;
        }
    }

    function handleMarginInOpenReverse(address _positionManager, address _trader, uint256 reduceMarginRequirement) internal returns (uint256 margin) {
        Position.Data memory marketPositionData = positionMap[_positionManager][_trader];
        Position.Data memory totalPositionData = getPosition(_positionManager, _trader);
        int256 newPositionSide = totalPositionData.quantity < 0 ? int256(1) : int256(- 1);
        if (marketPositionData.quantity * totalPositionData.quantity < 0) {
            if (marketPositionData.quantity * newPositionSide > 0) {
                margin = marketPositionData.margin + reduceMarginRequirement;
            } else {
                margin = marketPositionData.margin - reduceMarginRequirement;
            }
        } else {
            margin = reduceMarginRequirement > marketPositionData.margin ? reduceMarginRequirement - marketPositionData.margin : marketPositionData.margin - reduceMarginRequirement;
        }
    }

    function handleNotionalInIncrease(address _positionManager, address _trader, uint256 exchangedQuoteAmount) internal returns (uint256 openNotional) {
        Position.Data memory marketPositionData = positionMap[_positionManager][_trader];
        Position.Data memory totalPositionData = getPosition(_positionManager, _trader);
        int256 newPositionSide = totalPositionData.quantity > 0 ? int256(1) : int256(- 1);
        if (marketPositionData.quantity * totalPositionData.quantity < 0) {
            if (marketPositionData.openNotional > exchangedQuoteAmount) {
                openNotional = marketPositionData.openNotional - exchangedQuoteAmount;
            } else {
                openNotional = exchangedQuoteAmount - marketPositionData.openNotional;
            }
        } else {
            openNotional = marketPositionData.openNotional + exchangedQuoteAmount;
        }
    }

    function handleMarginInIncrease(address _positionManager, address _trader, uint256 increaseMarginRequirement) internal returns (uint256 margin) {
        Position.Data memory marketPositionData = positionMap[_positionManager][_trader];
        Position.Data memory totalPositionData = getPosition(_positionManager, _trader);
        int256 newPositionSide = totalPositionData.quantity > 0 ? int256(1) : int256(- 1);
        if (marketPositionData.quantity * totalPositionData.quantity < 0) {
            if (marketPositionData.quantity * newPositionSide > 0) {
                margin = marketPositionData.margin + increaseMarginRequirement;
            } else {
                margin = increaseMarginRequirement > marketPositionData.margin ? increaseMarginRequirement - marketPositionData.margin : marketPositionData.margin - increaseMarginRequirement;
            }
        } else {
            margin = marketPositionData.margin + increaseMarginRequirement;
        }
    }

    function getPendingOrder(
        IPositionManager positionManager,
        int128 pip,
        uint256 orderId
    ) public view returns (
        bool isFilled,
        bool isBuy,
        uint256 size,
        uint256 partialFilled
    ){
        return positionManager.getPendingOrderDetail(pip, uint64(orderId));
    }


    function getListOrderPending(IPositionManager _positionManager) public view returns (LimitOrderPending[] memory listPendingPositionData){
        address _trader = _msgSender();
        PositionLimitOrder.Data[] memory listLimitOrder = limitOrders[address(_positionManager)][_trader];

        uint index = 0;
        for (uint i = 0; i < listLimitOrder.length; i++) {

            (bool isFilled, bool isBuy,
            uint256 quantity, uint256 partialFilled) = _positionManager.getPendingOrderDetail(listLimitOrder[i].pip, listLimitOrder[i].orderId);
            if (!isFilled) {

                listPendingPositionData[index] = LimitOrderPending({
                side : isBuy ? Position.Side.LONG : Position.Side.SHORT,
                quantity : int256(quantity),
                openNotional : quantity * _positionManager.pipToPrice(listLimitOrder[i].pip),
                pip : _positionManager.pipToPrice(listLimitOrder[i].pip),
                partialFilled : partialFilled,
                leverage : listLimitOrder[i].leverage,
                blockNumber : 0
                });
                index++;
            }

        }
    }

    function getPosition(
        address positionManager,
        address _trader
    ) public view returns (Position.Data memory positionData){
        positionData = positionMap[positionManager][_trader];
        int256 quantityMarket = positionData.quantity;
        PositionLimitOrder.Data[] memory _limitOrders = limitOrders[positionManager][_trader];
        PositionLimitOrder.Data[] memory _reduceOrders = reduceLimitOrders[positionManager][_trader];
        IPositionManager _positionManager = IPositionManager(positionManager);
        for (uint i = 0; i < _limitOrders.length; i++) {
            positionData = _accumulateLimitOrderToPositionData(_positionManager, _limitOrders[i], positionData, _limitOrders[i].entryPrice, _limitOrders[i].reduceQuantity);
        }
        for (uint i = 0; i < _reduceOrders.length; i++) {
            positionData = _accumulateLimitOrderToPositionData(_positionManager, _reduceOrders[i], positionData, _reduceOrders[i].entryPrice, _reduceOrders[i].reduceQuantity);
        }
        positionData.sumQuantityLimitOrder = positionData.quantity - quantityMarket;
        Position.LiquidatedData memory _debtPosition = debtPosition[positionManager][_trader];
        if (_debtPosition.margin != 0) {
            positionData.quantity -= _debtPosition.quantity;
            positionData.margin -= _debtPosition.margin;
            positionData.openNotional -= _debtPosition.notional;
        }
    }


    function getPositionNotionalAndUnrealizedPnl(
        IPositionManager positionManager,
        address _trader,
        PnlCalcOption _pnlCalcOption
    ) public view returns
    (
        uint256 positionNotional,
        int256 unrealizedPnl
    ){
        Position.Data memory position = getPosition(address(positionManager), _trader);
        uint256 oldPositionNotional = position.openNotional;
        if (_pnlCalcOption == PnlCalcOption.TWAP) {
            // TODO get twap price
        } else if (_pnlCalcOption == PnlCalcOption.SPOT_PRICE) {
            positionNotional = positionManager.getPrice() * position.quantity.abs();
        } else {
            // TODO get oracle price
        }
        if (position.side() == Position.Side.LONG) {
            unrealizedPnl = int256(positionNotional) - int256(oldPositionNotional);
        } else {
            unrealizedPnl = int256(oldPositionNotional) - int256(positionNotional);
        }

    }

    function getLiquidationPrice(
        IPositionManager positionManager,
        address _trader,
        PnlCalcOption _pnlCalcOption
    ) public view returns (uint256 liquidationPrice){
        Position.Data memory positionData = getPosition(address(positionManager), _trader);
        (uint256 maintenanceMargin,,) = getMaintenanceDetail(positionManager, _trader);
        if (positionData.side() == Position.Side.LONG) {
            liquidationPrice = (maintenanceMargin - positionData.margin + positionData.openNotional) / positionData.quantity.abs();
        } else {
            liquidationPrice = (positionData.openNotional - maintenanceMargin + positionData.margin) / positionData.quantity.abs();
        }
    }

    /**
     * @notice get all information to maintaining position
     * @param _positionManager positionManager address
     * @param _trader trader address
     */
    function getMaintenanceDetail(
        IPositionManager _positionManager,
        address _trader
    ) public view returns (uint256 maintenanceMargin, int256 marginBalance, uint256 marginRatio) {
        Position.Data memory positionData = getPosition(address(_positionManager), _trader);
        maintenanceMargin = positionData.margin * maintenanceMarginRatio / 100;
        (, int256 unrealizedPnl) = getPositionNotionalAndUnrealizedPnl(_positionManager, _trader, PnlCalcOption.SPOT_PRICE);
        marginBalance = int256(positionData.margin) + unrealizedPnl;
        if (marginBalance <= 0) {
            marginRatio = 100;
        } else {
            marginRatio = maintenanceMargin * 100 / uint256(marginBalance);
        }
    }

    // new function
    /**
     * @notice get latest cumulative premium fraction.
     * @param _positionManager IPositionManager address
     * @return latest cumulative premium fraction
     */
    function getLatestCumulativePremiumFraction(IPositionManager _positionManager) public view returns (int256) {
        uint256 len = positionManagerMap[address(_positionManager)].cumulativePremiumFraction.length;
        if (len > 0) {
            return positionManagerMap[address(_positionManager)].cumulativePremiumFraction[len - 1];
        }
        return 0;
    }

    function payFunding(IPositionManager _positionManager) external onlyOwner {
        requirePositionManager(_positionManager, true);

        int256 premiumFraction = _positionManager.settleFunding();
        positionManagerMap[address(_positionManager)].cumulativePremiumFraction.push(premiumFraction + getLatestCumulativePremiumFraction(_positionManager));
    }

    function transferFee(
        address _from,
        IPositionManager _positionManager,
        uint256 _positionNotional
    ) internal returns (uint256) {
        uint256 toll = _positionManager.calcFee(_positionNotional);
        //        bool hasToll = toll.toUint() > 0;
        //        bool hasSpread = spread.toUint() > 0;
        if (toll > 0) {
            IERC20 quoteAsset = _positionManager.getQuoteAsset();

            transferFromTrader(quoteAsset, _from, address(feePool), toll);

            //            // transfer spread to insurance fund
            //            if (hasSpread) {
            //                _transferFrom(quoteAsset, _from, address(insuranceFund), spread);
            //            }
            //
            //            // transfer toll to feePool
            //            if (hasToll) {
            //                require(address(feePool) != address(0), "Invalid feePool");
            //                _transferFrom(quoteAsset, _from, address(feePool), toll);
            //            }

            // fee = spread + toll
            return toll;
        }

        return 0;
    }


    function transferFromTrader(IERC20 quoteToken, address sender, address receiver, uint256 amount) internal {

        uint256 balanceSender = quoteToken.balanceOf(sender);

        require(balanceSender >= amount, 'Not enough balance');

        // solhint-disable avoid-low-level-calls
        (bool success, bytes memory data) =
        address(quoteToken).call(abi.encodeWithSelector(quoteToken.transferFrom.selector, sender, receiver, amount));
    }

    function transferFromVault(IERC20 quoteToken, address sender, address receiver, uint256 amount) internal {

        uint256 balanceSender = quoteToken.balanceOf(sender);


        if (balanceSender < amount) {
            // TODO withdraw from InsuranceFund
        }

        // solhint-disable avoid-low-level-calls
        (bool success, bytes memory data) =
        address(quoteToken).call(abi.encodeWithSelector(quoteToken.transferFrom.selector, sender, receiver, amount));

    }

    //
    // REQUIRE FUNCTIONS
    //
    function requirePositionManager(
        IPositionManager positionManager,
        bool open
    ) private view {

    }

    // TODO define criteria
    function requireMoreMarginRatio(uint256 _marginRatio) private view {
        require(_marginRatio >= partialLiquidationRatio, "Margin ratio not meet criteria");
    }

    function requirePositionSize(
        int256 _quantity
    ) private pure {
        require(_quantity != 0, "positionSize is 0");
    }

    //
    // INTERNAL FUNCTION OF POSITION HOUSE
    //

    function openMarketOrder(
        IPositionManager _positionManager,
        uint256 _quantity,
        Position.Side _side
    ) internal returns (int256 exchangedQuantity, uint256 openNotional){
        uint256 exchangedSize;
        address _trader = _msgSender();
        (exchangedSize, openNotional) = _positionManager.openMarketPosition(_quantity, _side == Position.Side.LONG);
        require(exchangedSize == _quantity, "not enough liquidity to fulfill the order");
        exchangedQuantity = _side == Position.Side.LONG ? int256(exchangedSize) : - int256(exchangedSize);
    }

    function isNewPosition(
        IPositionManager _positionManager,
        address _trader
    ) internal view returns (bool) {
        return positionMap[address(_positionManager)][_trader].quantity != 0;
    }

    // TODO update function parameter to positionManager, oldPositionData, marginDelta
    function calcRemainMarginWithFundingPayment(
        uint256 deltaMargin
    ) internal view returns (uint256 remainMargin, uint256 fundingPayment, int256 latestCumulativePremiumFraction){

        remainMargin = uint256(deltaMargin);
        fundingPayment = 0;
        latestCumulativePremiumFraction = 0;
    }

    // new function
    function calcRemainMarginWithFundingPaymentNew(
        IPositionManager _positionManager, Position.Data memory oldPosition, int256 deltaMargin
    ) internal view returns (uint256 remainMargin, uint256 badDebt, int256 fundingPayment, int256 latestCumulativePremiumFraction){

        // calculate fundingPayment
        latestCumulativePremiumFraction = getLatestCumulativePremiumFraction(_positionManager);
        if (oldPosition.quantity != 0) {
            fundingPayment = (latestCumulativePremiumFraction - oldPosition.lastUpdatedCumulativePremiumFraction) * oldPosition.quantity;
        }

        // calculate remain margin, if remain margin is negative, set to zero and leave the rest to bad debt
        if (deltaMargin + fundingPayment >= 0) {
            remainMargin = uint256(deltaMargin + fundingPayment);
        } else {
            badDebt = uint256(- fundingPayment - deltaMargin);
        }

        fundingPayment = 0;
        latestCumulativePremiumFraction = 0;
    }

    function partialLiquidate(
        IPositionManager _positionManager,
        Position.Side _side,
        int256 _quantity,
        uint256 _leverage,
        address _trader
    ) internal returns (PositionResp memory positionResp){
        Position.Data memory oldPosition = getPosition(address(_positionManager), _trader);
        (positionResp.exchangedPositionSize,) = openMarketOrder(_positionManager, _quantity.abs(), _side);
        positionResp.exchangedQuoteAssetAmount = _quantity.abs() * (oldPosition.openNotional / oldPosition.quantity.abs());
        (, int256 unrealizedPnl) = getPositionNotionalAndUnrealizedPnl(_positionManager, _trader, PnlCalcOption.SPOT_PRICE);
        // TODO need to calculate remain margin with funding payment
        uint256 remainMargin = oldPosition.margin * (100 - liquidationFeeRatio) / 100;
        // unchecked
        positionResp.marginToVault = int256(oldPosition.margin) - int256(remainMargin);
        positionResp.unrealizedPnl = unrealizedPnl;
        debtPosition[address(_positionManager)][_trader].updateDebt(
            - _quantity,
            oldPosition.margin - remainMargin,
            positionResp.exchangedQuoteAssetAmount
        );
        return positionResp;
    }

    function getPositionWithoutCloseLimitOrder(
        address positionManager,
        address _trader
    ) internal view returns (Position.Data memory positionData){
        positionData = positionMap[positionManager][_trader];
        PositionLimitOrder.Data[] memory listLimitOrder = limitOrders[positionManager][_trader];
        IPositionManager _positionManager = IPositionManager(positionManager);
        for (uint i = 0; i < listLimitOrder.length; i++) {
            positionData = _accumulateLimitOrderToPositionData(_positionManager, listLimitOrder[i], positionData, listLimitOrder[i].entryPrice, listLimitOrder[i].reduceQuantity);
        }
    }

    function _accumulateLimitOrderToPositionData(IPositionManager _positionManager, PositionLimitOrder.Data memory limitOrder, Position.Data memory positionData, uint256 entryPrice, uint256 reduceQuantity) internal view returns (Position.Data memory) {
        (bool isFilled, bool isBuy,
        uint256 quantity, uint256 partialFilled) = _positionManager.getPendingOrderDetail(limitOrder.pip, limitOrder.orderId);
        if (isFilled) {
            int256 _orderQuantity;
            if (reduceQuantity == 0 && entryPrice == 0) {
                _orderQuantity = isBuy ? int256(quantity) : - int256(quantity);
            } else if (reduceQuantity != 0 && entryPrice == 0) {
                _orderQuantity = isBuy ? int256(quantity - reduceQuantity) : - int256(quantity - reduceQuantity);
            } else {
                _orderQuantity = isBuy ? int256(reduceQuantity) : - int256(reduceQuantity);
            }
            uint256 _orderNotional = _orderQuantity.abs() * (entryPrice == 0 ? _positionManager.pipToPrice(limitOrder.pip) : entryPrice);
            // IMPORTANT UPDATE FORMULA WITH LEVERAGE
            uint256 _orderMargin = _orderNotional / limitOrder.leverage;
            positionData = positionData.accumulateLimitOrder(_orderQuantity, _orderMargin, _orderNotional);
        }
        else if (!isFilled && partialFilled != 0) {// partial filled
            int256 _partialQuantity;
            if (reduceQuantity == 0 && entryPrice == 0) {
                _partialQuantity = isBuy ? int256(partialFilled) : - int256(partialFilled);
            } else if (reduceQuantity != 0 && entryPrice == 0) {
                int256 _partialQuantityTemp = partialFilled > reduceQuantity ? int256(partialFilled - reduceQuantity) : 0;
                _partialQuantity = isBuy ? _partialQuantityTemp : - _partialQuantityTemp;
            } else {
                int256 _partialQuantityTemp = partialFilled > reduceQuantity ? int256(reduceQuantity) : int256(partialFilled);
                _partialQuantity = isBuy ? _partialQuantityTemp : - _partialQuantityTemp;
            }
            uint256 _partialOpenNotional = _partialQuantity.abs() * (entryPrice == 0 ? _positionManager.pipToPrice(limitOrder.pip) : entryPrice);
            // IMPORTANT UPDATE FORMULA WITH LEVERAGE
            uint256 _partialMargin = _partialOpenNotional / limitOrder.leverage;
            positionData = positionData.accumulateLimitOrder(_partialQuantity, _partialMargin, _partialOpenNotional);
        }
        return positionData;
    }

    function _calcRealPnL(IPositionManager _positionManager, Position.Data memory positionData, uint256 amountFilled, int128 pip, int256 amount, int256 realPnL) public view returns (int256, int256, Position.Data memory)  {
        if (positionData.side() == Position.Side.LONG) {
            uint256 notionalWhenFilled = amountFilled * _positionManager.pipToPrice(pip);
            int256 realizedPnl = int256(notionalWhenFilled) - int256(positionData.openNotional) / positionData.quantity * int256(amountFilled);
            int256 realizedMargin = int256(positionData.margin) * int256(amountFilled) / positionData.quantity;
            amount = amount + realizedMargin;
            realPnL = realPnL + realizedPnl;
            positionData.openNotional = (positionData.openNotional / uint256(positionData.quantity)) * uint256(positionData.quantity - int256(amountFilled));
            positionData.quantity = positionData.quantity - int256(amountFilled);
            positionData.margin = positionData.margin - uint256(realizedMargin);
        } else {
            uint256 notionalWhenFilled = amountFilled * _positionManager.pipToPrice(pip);
            int256 realizedPnl = int256(positionData.openNotional) / (- positionData.quantity) * int256(amountFilled) - int256(notionalWhenFilled);
            int256 realizedMargin = int256(positionData.margin) * int256(amountFilled) / (- positionData.quantity);
            amount = amount + realizedMargin;
            realPnL = realPnL + realizedPnl;
            positionData.openNotional = (positionData.openNotional / uint256(- positionData.quantity)) * uint256(- positionData.quantity - int256(amountFilled));
            positionData.quantity = positionData.quantity + int256(amountFilled);
            positionData.margin = positionData.margin - uint256(realizedMargin);

        }
        return (amount, realPnL, positionData);
    }
}
