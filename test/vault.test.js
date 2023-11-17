const {
  time,
  mine
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");

const { parseEther, ZeroAddress } = ethers

async function unlockAccount(addr) {
  await hre.network.provider.send("hardhat_impersonateAccount", [addr]);
  return hre.ethers.provider.getSigner(addr);
}

async function increaseTime(hrVal) {
  const blockTime = 15;
  await time.increase(3600 * hrVal);
  await mine(Math.ceil(3600 * hrVal / blockTime));
}

function checkRange(checkAmt, valueAmt) {
  expect(checkAmt).to.be.within(valueAmt * 999n / 1000n, valueAmt * 1001n / 1000n)
}

describe.only("Vault test", function () {
  before("Deploy contract", async function () {
    // init users
    [this.owner, this.alice, this.bob, this.tom] = await ethers.getSigners();

    const lpToken = "0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490"; // curve 3USD LP
    const crvToken = "0xD533a949740bb3306d119CC777fa900bA034cd52";
    const cvxToken = "0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B"
    this.weth = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
    const curveRouter = "0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7";

    this.lpPid = 9;
    this.crvToken = await ethers.getContractAt("IERC20", crvToken);
    this.cvxToken = await ethers.getContractAt("IERC20", cvxToken);
    this.wethToken = await ethers.getContractAt("IERC20", this.weth);

    // deploy vault contract
    const VaultContract = await ethers.getContractFactory("CurveLPVault");
    this.vault = await VaultContract.deploy(
      lpToken,
      this.lpPid,
      {
        router: curveRouter,
        lpCnt: 3
      }
    );
    await this.vault.waitForDeployment();
    this.vaultAddr = await this.vault.getAddress();
    console.log(`Vault contract deployed to: ${this.vaultAddr}`);

    // distribute WETH token to users
    const whaleAccount = await unlockAccount("0x57757E3D981446D585Af0D9Ae4d7DF6D64647806")

    this.wethAmt = parseEther("500")
    this.depositAmt = parseEther("10")
    await this.wethToken.connect(whaleAccount).transfer(this.alice.address, this.wethAmt)
    await this.wethToken.connect(whaleAccount).transfer(this.bob.address, this.wethAmt)
    await this.wethToken.connect(whaleAccount).transfer(this.tom.address, this.wethAmt)

    this.booster = await ethers.getContractAt("IBooster", "0xF403C135812408BFbE8713b5A23a04b3D48AAE31")

    // enable WETH and ETH as deposit token
    await this.vault.connect(this.owner).setDepositTokens([ZeroAddress, this.weth], true);
  })

  it("check requires", async function () {
    await expect(this.vault.connect(this.alice).deposit(0, ZeroAddress)).to.be.revertedWithCustomError(this.vault, "ZeroAmount()");
  })

  it("Check Alice can deposit using ETH", async function () {
    // approve token first
    await expect(
      this.vault.connect(this.alice).deposit(
        this.depositAmt,
        ZeroAddress,
        {
          value: this.depositAmt
        }
      )
    ).to.emit(this.vault, "Deposit");

    // check userInfo
    const aliceInfo = await this.vault.userInfo(this.alice.address);
    expect(aliceInfo.amount).to.be.gt(0);
    expect(aliceInfo.crvShare).to.be.eq(0);
    expect(aliceInfo.cvxShare).to.be.eq(0);
    expect(aliceInfo.crvPending).to.be.eq(0);
    expect(aliceInfo.cvxPending).to.be.eq(0);
  });

  it("After 24 hours, bob deposits WETH", async function () {
    await increaseTime(1);

    console.log(this.wethToken.address);
    await this.wethToken.connect(this.bob).approve(this.vaultAddr, this.wethAmt);
    await expect(this.vault.connect(this.bob).deposit(this.depositAmt, this.weth)).to.emit(this.vault, "Deposit");

    const wethBal = await this.wethToken.balanceOf(this.bob.address);
    expect(wethBal).to.be.eq(this.wethAmt - this.depositAmt)
  })

  it("Check Alice's pendingReward and actual reward after claim", async function () {
    // call withdraw and receive as ETH
    await expect(this.vault.connect(this.alice).claim(true, this.weth)).to.emit(this.vault, "Claim");

    const lpBal = await this.wethToken.balanceOf(this.alice.address);
    expect(lpBal).to.be.eq(this.wethAmt)
  })

  it("Pass other 1 day and check pendingReward", async function () {
    await increaseTime(1);

    await this.booster.connect(this.owner).earmarkRewards(this.lpPid);

    const alicePending = await this.vault.pendingReward(this.alice.address);
    const bobPending = await this.vault.pendingReward(this.bob.address);
    const tomPending = await this.vault.pendingReward(this.tom.address);

    expect(alicePending.crvReward).to.be.gt(0);
    checkRange(alicePending.crvReward, bobPending.crvReward);
    checkRange(alicePending.cvxReward, bobPending.cvxReward);
    checkRange(alicePending.crvReward * 2n, tomPending.crvReward);
    checkRange(alicePending.cvxReward * 2n, tomPending.cvxReward);
  })

  it("Alice withdraw and he wants to receive in ETH", async function () {
    const alicePending = await this.vault.pendingReward(this.alice.address);
    const beforeBalance = await ethers.provider.getBalance(this.alice.address);

    // withdraw
    await expect (this.vault.connect(this.alice).withdraw(this.depositAmt, true, ZeroAddress)).to.be.emit(this.vault, "Withdraw");

    // check lpamt
    const lpAmt = await this.lpToken.balanceOf(this.alice.address);
    expect(lpAmt).to.be.eq(this.lpAmt);

    const afterCRV = await this.crvToken.balanceOf(this.alice.address);
    const afterCVX = await this.cvxToken.balanceOf(this.alice.address);

    expect(afterCRV - beforeCRV, alicePending.crvReward);
    expect(afterCVX - beforeCVX, alicePending.cvxReward);
  })
})