import {set} from "husky";

const {expect, use} = require('chai')
const {ethers, waffle, web3} = require("hardhat");
const {ContractFactory, utils, BigNumber, Signer} = require('ethers');
const {waffleChai} = require('@ethereum-waffle/chai');
const {deployMockContract, provider, solidity} = waffle
const web3Utils = require('web3-utils')
// import { default as BigNumber, default as BN } from "bn.js"

import {PositionHouse} from "../../../typeChain";
import {Amm} from "../../../typeChain";
import {toWei, toWeiWithString, fromWeiWithString, fromWei} from "../../shared/utilities";

const [deployer, sender2, sender3, sender4] = provider.getWallets()


describe('Test Amm Initialize', () => {

    let positionHouse: PositionHouse;
    let amm: Amm;

    beforeEach('setup', async () => {
        const TestPositionHouse = await ethers.getContractFactory("contracts/protocol/position/PositionHouse.sol:PositionHouse");
        const TestAmm = await ethers.getContractFactory("Amm");

        positionHouse = (await TestPositionHouse.deploy() as unknown) as PositionHouse;
        amm = (await TestAmm.deploy() as unknown) as Amm;

    });

    it('should liquidity correct 1', async function () {
        await amm.initialize(
            // price =100000/ 100 = 1000
            //start price
            toWei(100000/100),
            // _quoteAssetReserve
            toWei(100000),
            // _baseAssetReserve
            toWei(100),
            //address quote asset
            '0x55d398326f99059ff775485246999027b3197955'
        );

        const liquidityDetail = await amm.testLiquidityInitialize();

        expect(liquidityDetail[0].liquidity.toString()).to.eq(toWei(100*100000))

        expect(liquidityDetail[1].tick.toString()).to.eq('69081');

        // console.log();
    });

    it('should liquidity correct 2', async function () {
        await amm.initialize(
            // price =100000/ 100 = 1000
            //start price
            toWei(10020/190),
            // _quoteAssetReserve
            toWei(10020),
            // _baseAssetReserve
            toWei(190),
            //address quote asset
            '0x55d398326f99059ff775485246999027b3197955'
        );

        const liquidityDetail = await amm.testLiquidityInitialize();

        console.log(liquidityDetail[0].liquidity.toString());

        expect(liquidityDetail[0].liquidity.toString()).to.eq(toWei(10020*190))

        expect(liquidityDetail[1].tick.toString()).to.eq('39655');

    });


});
