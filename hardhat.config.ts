import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "hardhat-deploy";

let localTestMnemonic = "test test test test test test test test test test test junk";
const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      { version: "0.8.19", settings: { optimizer: { enabled: true, runs: 200 } } },
    ]
  },
  networks: {
    hardhat: {
      accounts: {
        mnemonic: localTestMnemonic,
        accountsBalance: "10000000000000000000000000",
      },
      blockGasLimit: 50_000_000,
      gas: 40_000_000,
    },
    localhost: {
      url: "http://localhost:8545",
      accounts: {
        mnemonic: localTestMnemonic,
        count: 10,
      },
      timeout: 100_000,
      blockGasLimit: 50_000_000,
      gas: 40_000_000,
    },
    tctest: {
      url: "https://tc-regtest.trustless.computer/",
      accounts: {
        mnemonic: localTestMnemonic,
        count: 4,
      },
      // issue: https://github.com/NomicFoundation/hardhat/issues/3136
      // workaround: https://github.com/NomicFoundation/hardhat/issues/2672#issuecomment-1167409582
      timeout: 100_000,
    },
  },
  namedAccounts: {
    deployer: 0,
  },
};

export default config;
