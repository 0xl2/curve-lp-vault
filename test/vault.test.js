const {
  time,
  mine
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");

const { parseEther, MaxUint256 } = ethers

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
    await expect(this.vault.connect(this.alice).deposit(this.depositAmt)).to.emit(this.vault, "Deposit").withArgs(this.alice.address, this.depositAmt);

    const lpBal = await this.lpToken.balanceOf(this.alice.address);
    expect(lpBal).to.be.eq(this.lpAmt - this.depositAmt)
  });

  it("After 24 hours, bob deposits", async function () {
    await increaseTime(24);

    await this.lpToken.connect(this.bob).approve(this.vaultAddr, this.lpAmt);
    await expect(this.vault.connect(this.bob).deposit(this.depositAmt)).to.emit(this.vault, "Deposit").withArgs(this.bob.address, this.depositAmt);

    const lpBal = await this.lpToken.balanceOf(this.bob.address);
    expect(lpBal).to.be.eq(this.lpAmt - this.depositAmt)
  })

  it("Check Alice's pendingReward and actual reward after claim", async function () {
    const pendingAlice = await this.vault.pendingReward(this.alice.address);

    // call withdraw
    await expect(this.vault.connect(this.alice).claim()).to.emit(this.vault, "Claim");

    const lpBal = await this.lpToken.balanceOf(this.alice.address);
    expect(lpBal).to.be.eq(this.lpAmt - this.depositAmt)

    // check actual reward
    const crvBal = await this.crvToken.balanceOf(this.alice.address);
    const cvxBal = await this.cvxToken.balanceOf(this.alice.address);

    checkRange(crvBal, pendingAlice.crvReward);
    checkRange(cvxBal, pendingAlice.cvxReward);
  })

  it("Tom deposits twice of Alice's deposit amount", async function () {
    const depositAmt = this.depositAmt * 2n
    await this.lpToken.connect(this.tom).approve(this.vaultAddr, this.lpAmt);
    await expect(this.vault.connect(this.tom).deposit(depositAmt)).to.emit(this.vault, "Deposit").withArgs(this.tom.address, depositAmt);

    const lpBal = await this.lpToken.balanceOf(this.tom.address);
    expect(lpBal).to.be.eq(this.lpAmt - depositAmt)
  })

  it("Check Alice and Bob's pendingReward ratio after another 1 day passed", async function () {
    await increaseTime(24);

    const alicePending = await this.vault.pendingReward(this.alice.address);
    const bobPending = await this.vault.pendingReward(this.bob.address);

    expect(alicePending.crvReward).to.be.gt(0);
    checkRange(alicePending.crvReward, bobPending.crvReward);
    checkRange(alicePending.cvxReward, bobPending.cvxReward);
  });

  it("Check Alice and Tom's pendingReward ratio", async function () {
    const alicePending = await this.vault.pendingReward(this.alice.address);
    const tomPending = await this.vault.pendingReward(this.tom.address);

    checkRange(alicePending.crvReward * 2n, tomPending.crvReward);
    checkRange(alicePending.cvxReward * 2n, tomPending.cvxReward);
  })

  it("Check pendingReward with actual pending - Alice", async function () {
    const alicePending = await this.vault.pendingReward(this.alice.address);

    const beforeCRV = await this.crvToken.balanceOf(this.alice.address);
    const beforeCVX = await this.cvxToken.balanceOf(this.alice.address);

    // claim
    await expect(this.vault.connect(this.alice).claim()).to.emit(this.vault, "Claim");

    const afterCRV = await this.crvToken.balanceOf(this.alice.address);
    const afterCVX = await this.cvxToken.balanceOf(this.alice.address);

    checkRange(afterCRV - beforeCRV, alicePending.crvReward);
    checkRange(afterCVX - beforeCVX, alicePending.cvxReward);

    const alicePending1 = await this.vault.pendingReward(this.alice.address);
    expect(alicePending1.crvReward).to.be.eq(0)
    expect(alicePending1.cvxReward).to.be.eq(0)
  })

  it("Check pendingReward with actual pending - Bob", async function () {
    const bobPending = await this.vault.pendingReward(this.bob.address);

    const beforeCRV = await this.crvToken.balanceOf(this.bob.address);
    const beforeCVX = await this.cvxToken.balanceOf(this.bob.address);

    await expect(this.vault.connect(this.bob).claim()).to.emit(this.vault, "Claim");

    const afterCRV = await this.crvToken.balanceOf(this.bob.address);
    const afterCVX = await this.cvxToken.balanceOf(this.bob.address);

    checkRange(afterCRV - beforeCRV, bobPending.crvReward);
    checkRange(afterCVX - beforeCVX, bobPending.cvxReward);

    const bobPending1 = await this.vault.pendingReward(this.bob.address);
    expect(bobPending1.crvReward).to.be.eq(0)
    expect(bobPending1.cvxReward).to.be.eq(0)
  })

  it("Check pendingReward with actual pending - Tom", async function () {
    const tomPending = await this.vault.pendingReward(this.tom.address);

    const beforeCRV = await this.crvToken.balanceOf(this.tom.address);
    const beforeCVX = await this.cvxToken.balanceOf(this.tom.address);

    // claim
    await expect(this.vault.connect(this.tom).claim()).to.emit(this.vault, "Claim");

    const afterCRV = await this.crvToken.balanceOf(this.tom.address);
    const afterCVX = await this.cvxToken.balanceOf(this.tom.address);

    checkRange(afterCRV - beforeCRV, tomPending.crvReward);
    checkRange(afterCVX - beforeCVX, tomPending.cvxReward);

    const tomPending1 = await this.vault.pendingReward(this.tom.address);
    expect(tomPending1.crvReward).to.be.eq(0)
    expect(tomPending1.cvxReward).to.be.eq(0)
  })

  it("Pass other 1 day and check pendingReward", async function () {
    await increaseTime(24);

    const alicePending = await this.vault.pendingReward(this.alice.address);
    const bobPending = await this.vault.pendingReward(this.bob.address);
    const tomPending = await this.vault.pendingReward(this.tom.address);

    expect(alicePending.crvReward).to.be.gt(0);
    checkRange(alicePending.crvReward, bobPending.crvReward);
    checkRange(alicePending.cvxReward, bobPending.cvxReward);
    checkRange(alicePending.crvReward * 2n, tomPending.crvReward);
    checkRange(alicePending.cvxReward * 2n, tomPending.cvxReward);
  })

  it("Alice withdraw his all LP", async function () {
    const alicePending = await this.vault.pendingReward(this.alice.address);
    const beforeCRV = await this.crvToken.balanceOf(this.alice.address);
    const beforeCVX = await this.cvxToken.balanceOf(this.alice.address);

    // withdraw
    await this.vault.connect(this.alice).withdraw(this.depositAmt);

    // check lpamt
    const lpAmt = await this.lpToken.balanceOf(this.alice.address);
    expect(lpAmt).to.be.eq(this.lpAmt);

    const afterCRV = await this.crvToken.balanceOf(this.alice.address);
    const afterCVX = await this.cvxToken.balanceOf(this.alice.address);

    expect(afterCRV - beforeCRV, alicePending.crvReward);
    expect(afterCVX - beforeCVX, alicePending.cvxReward);
  })

  it("Tom withdraw his half LP", async function () {
    const tomPending = await this.vault.pendingReward(this.tom.address);
    const beforeCRV = await this.crvToken.balanceOf(this.tom.address);
    const beforeCVX = await this.cvxToken.balanceOf(this.tom.address);

    // withdraw
    await expect(this.vault.connect(this.tom).withdraw(this.depositAmt)).to.emit(this.vault, "Withdraw").withArgs(this.tom.address, this.depositAmt);

    const lpAmt = await this.lpToken.balanceOf(this.tom.address);
    expect(lpAmt).to.be.eq(this.lpAmt - this.depositAmt);

    const afterCRV = await this.crvToken.balanceOf(this.tom.address);
    const afterCVX = await this.cvxToken.balanceOf(this.tom.address);

    expect(afterCRV - beforeCRV, tomPending.crvReward);
    expect(afterCVX - beforeCVX, tomPending.cvxReward);
  })

  it("Bob just do claim", async function () {
    const bobPending = await this.vault.pendingReward(this.bob.address);
    const beforeCRV = await this.crvToken.balanceOf(this.bob.address);
    const beforeCVX = await this.cvxToken.balanceOf(this.bob.address);

    // withdraw
    await expect(this.vault.connect(this.bob).claim()).to.emit(this.vault, "Claim");

    const lpAmt = await this.lpToken.balanceOf(this.bob.address);
    expect(lpAmt).to.be.eq(this.lpAmt - this.depositAmt);

    const afterCRV = await this.crvToken.balanceOf(this.bob.address);
    const afterCVX = await this.cvxToken.balanceOf(this.bob.address);

    expect(afterCRV - beforeCRV, bobPending.crvReward);
    expect(afterCVX - beforeCVX, bobPending.cvxReward);
  });

  it("Pass other 1 day and check pendingReward", async function () {
    await increaseTime(24);

    const alicePending = await this.vault.pendingReward(this.alice.address);
    const bobPending = await this.vault.pendingReward(this.bob.address);
    const tomPending = await this.vault.pendingReward(this.tom.address);

    expect(alicePending.crvReward).to.be.eq(0);
    checkRange(bobPending.crvReward, tomPending.crvReward);
    checkRange(bobPending.cvxReward, tomPending.cvxReward);
  })

  it("check Alice, Bob and Tom's userinfo", async function () {
    const aliceInfo = await this.vault.userInfo(this.alice.address);
    expect(aliceInfo.amount).to.be.eq(0)

    const bobInfo = await this.vault.userInfo(this.bob.address);
    expect(bobInfo.amount).to.be.eq(this.depositAmt)

    const tomInfo = await this.vault.userInfo(this.tom.address);
    expect(tomInfo.amount).to.be.eq(this.depositAmt)
  })

  it("Bob can withdraw", async function () {
    // withdraw
    await expect(this.vault.connect(this.bob).withdraw(MaxUint256)).to.emit(this.vault, "Withdraw").withArgs(this.bob.address, this.depositAmt);

    // check lpamt
    const lpAmt = await this.lpToken.balanceOf(this.bob.address);
    expect(lpAmt).to.be.eq(this.lpAmt);
  })

  it("Tom can withdraw remaining amount", async function () {
    // withdraw
    await expect(this.vault.connect(this.tom).withdraw(MaxUint256)).to.emit(this.vault, "Withdraw").withArgs(this.tom.address, this.depositAmt);

    // check lpamt
    const lpAmt = await this.lpToken.balanceOf(this.tom.address);
    expect(lpAmt).to.be.eq(this.lpAmt);
  })
})
