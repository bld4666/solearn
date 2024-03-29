import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { ethers } from 'hardhat';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
    const { deployments, getNamedAccounts, network } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    if (network.name === 'hardhat' || network.name === 'localhost') {
        await network.provider.send("evm_setIntervalMining", [3000]);
    }

    await deploy('Test', {
        from: deployer,
        log: true,
    });

};

func.tags = ['4', 'Test'];
export default func;