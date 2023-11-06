require("@nomicfoundation/hardhat-toolbox");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.19",
  networks: {
    hardhat: {
      forking: {
        url: "https://rpc.ankr.com/bsc",
        // url: "https://bscrpc.com",
        // url: "https://bsc-dataseed1.binance.org/",
        enabled: true,
        blockNumber: 25710942,
      },
    }
  },
  solidity: {
    compilers: [
      {
        version: "0.8.4",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    ],
  },
};
