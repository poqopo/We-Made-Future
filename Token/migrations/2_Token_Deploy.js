const We_Made_Future = artifacts.require('We_Made_Future')
const We_Made_Future_USD = artifacts.require('We_Made_Future_USD')

module.exports = async function(deployer, network, accounts) {
  // Deploy WUSD
  await deployer.deploy(We_Made_Future_USD)
  const we_made_future_USD = await We_Made_Future_USD.deployed()

  // Deploy WMF
  await deployer.deploy(We_Made_Future)
  const we_made_future = await We_Made_Future.deployed()


  // Transfer WMF to accounts[1] (1 million)
  await we_made_future.transfer(accounts[1], '1000000000000000000000000')

  // Transfer WUSD to accoutns[2]
  await we_made_future_USD.transfer(accounts[2], '100000000000000000000')
}
