const {
  time,
  mine
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");

const { parseEther, toBigInt } = ethers

async function unlockAccount(addr) {
  await hre.network.provider.send("hardhat_impersonateAccount", [addr]);
  return hre.ethers.provider.getSigner(addr);
}

async function increaseTime(hrVal) {
  const blockTime = 15;
  await time.increase(3600 * hrVal);
  await mine(Math.ceil(3600 * hrVal / blockTime));
}

function getRange(checkAmt, valueAmt) {
  expect(checkAmt).to.be.within(valueAmt * 999n / 1000n, valueAmt * 1001n / 1000n)
}

describe("Vault test", function () {
  before("Deploy contract", async function () {
    // init users
    [this.owner, this.alice, this.bob, this.tom] = await ethers.getSigners();

    const lpToken = "0xC25a3A3b969415c80451098fa907EC722572917F"; // curve 3USD LP
    const crvToken = "0xD533a949740bb3306d119CC777fa900bA034cd52";
    const cvxToken = "0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B"

    const lpPid = 4;
    this.lpToken = await ethers.getContractAt("IERC20", lpToken);
    this.crvToken = await ethers.getContractAt("IERC20", crvToken);
    this.cvxToken = await ethers.getContractAt("IERC20", cvxToken);

    // deploy vault contract
    const VaultContract = await ethers.getContractFactory("Vault");
    this.vault = await VaultContract.deploy(lpToken, lpPid);
    await this.vault.waitForDeployment();
    this.vaultAddr = await this.vault.getAddress();
    console.log(`Vault contract deployed to: ${this.vaultAddr}`);

    // distribute lp token to users
    const whaleAccount = await unlockAccount("0x9E51BE7071F086d3A1fD5Dc0016177473619b237")
    this.lpAmt = parseEther("500");
    this.depositAmt = parseEther("100")
    this.lpToken.connect(whaleAccount).transfer(this.alice.address, this.lpAmt)
    this.lpToken.connect(whaleAccount).transfer(this.bob.address, this.lpAmt)
    this.lpToken.connect(whaleAccount).transfer(this.tom.address, this.lpAmt)
  })

  it("check requires", async function () {
    await expect(this.vault.connect(this.alice).deposit(0)).to.be.revertedWithCustomError(this.vault, "ZeroAmount()");
  })

  it("Check Alice can deposit lp token", async function () {
    // approve token first
    await this.lpToken.connect(this.alice).approve(this.vaultAddr, this.lpAmt);
    await this.vault.connect(this.alice).deposit(this.depositAmt);

    const lpBal = await this.lpToken.balanceOf(this.alice.address);
    expect(lpBal).to.be.eq(this.lpAmt - this.depositAmt)
  });

  it("After 24 hours, bob deposits", async function () {
    await increaseTime(24);

    await this.lpToken.connect(this.bob).approve(this.vaultAddr, this.lpAmt);
    await this.vault.connect(this.bob).deposit(this.depositAmt);

    const lpBal = await this.lpToken.balanceOf(this.bob.address);
    expect(lpBal).to.be.eq(this.lpAmt - this.depositAmt)
  })

  it("Check Alice's pendingReward and actual reward after withdraw", async function () {
    const pendingAlice = await this.vault.pendingReward(this.alice.address);

    // call withdraw
    await this.vault.connect(this.alice).withdraw(this.lpAmt);

    const lpBal = await this.lpToken.balanceOf(this.alice.address);
    expect(lpBal).to.be.eq(this.lpAmt)

    // check actual reward
    const crvBal = await this.crvToken.balanceOf(this.alice.address);
    const cvxBal = await this.cvxToken.balanceOf(this.alice.address);

    getRange(crvBal, pendingAlice.crvReward);
    getRange(cvxBal, pendingAlice.cvxReward);
  })

  it("Tom deposits twice of Alice's deposit amount", async function () {
    await this.lpToken.connect(this.tom).approve(this.vaultAddr, this.lpAmt);
    await this.vault.connect(this.tom).deposit(this.depositAmt * 2n);

    
  })
})