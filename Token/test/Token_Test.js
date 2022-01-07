const We_Made_Future = artifacts.require('We_Made_Future')
const We_Made_Future_USD = artifacts.require('We_Made_Future_USD')

require('chai')
  .use(require('chai-as-promised'))
  .should()

function tokens(n) {
  return web3.utils.toWei(n, 'ether');
}

contract('TokenDeploy', ([owner, investor1, investor2]) => {
  let we_made_future, we_made_future_USDs

  before(async () => {
    // Load Contracts
    we_made_future = await We_Made_Future.new()
    we_made_future_USD = await We_Made_Future_USD.new()

    // Transfer all Dapp tokens to farm (1 million)
    await we_made_future.transfer(investor1, tokens('1000000'))

    // Send tokens to investor
    await we_made_future_USD.transfer(investor2, tokens('100'), { from: owner })
  })

  describe('We_Made_Future deployment', async () => {
    it('has a name', async () => {
      const name = await we_made_future.name()
      assert.equal(name, 'We_Made_Future')
    })
  })

  describe('we_made_future_USD deployment', async () => {
    it('has a name', async () => {
      const name = await we_made_future_USD.name()
      assert.equal(name, 'We_Made_Future_USD')
    })
  })



    it('investor1 has 1000000 we_made_future tokens', async () => {
      let balance = await we_made_future.balanceOf(investor1)
      assert.equal(balance.toString(), tokens('1000000'))
    })

    it('investor2 has 100 we_made_future tokens', async () => {
      let balance = await we_made_future_USD.balanceOf(investor2)
      assert.equal(balance.toString(), tokens('100'))
    })

  })