
// SPDX-License-Identifier: MIT
pragma solidity =0.6.6;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./We_Made_Future.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract We_Made_USD is ERC20, ERC20Burnable, Ownable {

   /* ========== STATE VARIABLES ========== */
    enum PriceChoice { FRAX, FXS }
    address public creator_address;
    address public controller_address; // Controller contract to dynamically adjust system parameters automatically
    address public WMF_address;
    address public USDC_address;
    address public eth_usd_consumer_address;
    uint256 public constant genesis_supply = 2000000e18;

    address[] public frax_pools_array; //WUSD를 민팅 가능한 주소들
    mapping(address => bool) public frax_pools; //W얘가 가능한지 아닌지 매핑
    uint256 private constant PRICE_PRECISION = 1e6;
    
    uint256 public global_collateral_ratio; // 현재 시장 담보비율 (소수점아래 6)
    uint256 public redemption_fee; // redeem fee
    uint256 public minting_fee; // minting fee
    uint256 public frax_step; // 얼만큼의 담보비율이 바뀌어야 하는지
    uint256 public refresh_cooldown; // 담보비율의 쿨타임
    uint256 public price_target; // 담보비율이 바뀌도록 하는 price
    uint256 public price_band; // 담보비율이 안바뀌게하는 영역

    address public DEFAULT_ADMIN_ADDRESS;
    bytes32 public constant COLLATERAL_RATIO_PAUSER = keccak256("COLLATERAL_RATIO_PAUSER");
    bool public collateral_ratio_paused = false;

    constructor (
        address _creator_address,
        address _timelock_address
    ) public Owned(_creator_address){
        require(_timelock_address != address(0), "Zero address detected"); 
        name = _name;
        symbol = _symbol;
        creator_address = _creator_address;
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        DEFAULT_ADMIN_ADDRESS = _msgSender();
        _mint(creator_address, genesis_supply);
        grantRole(COLLATERAL_RATIO_PAUSER, creator_address);
        grantRole(COLLATERAL_RATIO_PAUSER, timelock_address);
        frax_step = 2500; // 6 decimals of precision, equal to 0.25%
        global_collateral_ratio = 1000000; // 100% 담보비율
        refresh_cooldown = 3600; // 3600초(1시간)마다 담보비율 재설정
        price_target = 1000000; // 1달라
        price_band = 5000; // 0.005%의 오차범위 $0.995 and $1.005 at genesis
    }
    

        // ========== VIEWS ==========
    // Choice = 'FRAX' or 'FXS' for now
    function oracle_price(PriceChoice choice) internal view returns (uint256) {
        // 가격 가져오기
        uint256 __eth_usd_price = uint256(eth_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** eth_usd_pricer_decimals);
        uint256 price_vs_eth = 0;

        if (choice == PriceChoice.FRAX) {
            price_vs_eth = uint256(fraxEthOracle.consult(weth_address, PRICE_PRECISION)); // How much FRAX if you put in PRICE_PRECISION WETH
        }
        else if (choice == PriceChoice.FXS) {
            price_vs_eth = uint256(fxsEthOracle.consult(weth_address, PRICE_PRECISION)); // How much FXS if you put in PRICE_PRECISION WETH
        }
        else revert("INVALID PRICE CHOICE. Needs to be either 0 (FRAX) or 1 (FXS)");

        // Will be in 1e6 format
        return __eth_usd_price.mul(PRICE_PRECISION).div(price_vs_eth);
    }

    // Returns X FRAX = 1 USD
    function frax_price() public view returns (uint256) {
        return oracle_price(PriceChoice.FRAX);
    }

    // Returns X FXS = 1 USD
    function fxs_price()  public view returns (uint256) {
        return oracle_price(PriceChoice.FXS);
    }


    function eth_usd_price() public view returns (uint256) {
        return uint256(eth_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** eth_usd_pricer_decimals);
    }

    // - WUSD와 WMF의 가격 알기.

    // This is needed to avoid costly repeat calls to different getter functions
    // It is cheaper gas-wise to just dump everything and only use some of the info
    function frax_info() public view returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256) {
        return (
            oracle_price(PriceChoice.FRAX), // frax_price()
            oracle_price(PriceChoice.FXS), // fxs_price()
            totalSupply(), // totalSupply()
            global_collateral_ratio, // global_collateral_ratio()
            globalCollateralValue(), // globalCollateralValue
            minting_fee, // minting_fee()
            redemption_fee, // redemption_fee()
            uint256(eth_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** eth_usd_pricer_decimals) //eth_usd_price
        );
    }

    // -현재 가격대비 민팅, redeem 비용 및 비율 알기.

    // Iterate through all frax pools and calculate all value of collateral in all pools globally 
    function globalCollateralValue() public view returns (uint256) {
        uint256 total_collateral_value_d18 = 0; 

        for (uint i = 0; i < frax_pools_array.length; i++){ 
            // Exclude null addresses
            if (frax_pools_array[i] != address(0)){
                total_collateral_value_d18 = total_collateral_value_d18.add(FraxPool(frax_pools_array[i]).collatDollarBalance());
            }

        }
        return total_collateral_value_d18;


    // ========== PUBLIC FUNCTIONS ========== 
    
    // There needs to be a time interval that this can be called. Otherwise it can be called multiple times per expansion.
    uint256 public last_call_time; // Last time the refreshCollateralRatio function was called
    function refreshCollateralRatio() public {
        require(collateral_ratio_paused == false, "Collateral Ratio has been paused");
        uint256 frax_price_cur = frax_price(); 현재가격할기.
        require(block.timestamp - last_call_time >= refresh_cooldown, "Must wait for the refresh cooldown since last refresh");

        // Step increments are 0.25% (upon genesis, changable by setFraxStep()) 
        
        if (frax_price_cur > price_target.add(price_band)) { //decrease collateral ratio
            if(global_collateral_ratio <= frax_step){ //if within a step of 0, go to 0
                global_collateral_ratio = 0;
            } else {
                global_collateral_ratio = global_collateral_ratio.sub(frax_step);
            }
        } else if (frax_price_cur < price_target.sub(price_band)) { //increase collateral ratio
            if(global_collateral_ratio.add(frax_step) >= 1000000){
                global_collateral_ratio = 1000000; // cap collateral ratio at 1.000000
            } else {
                global_collateral_ratio = global_collateral_ratio.add(frax_step);
            }
        }

        last_call_time = block.timestamp; // Set the time of the last expansion

        emit CollateralRatioRefreshed(global_collateral_ratio);

    }
    // ========== RESTRICTED FUNCTIONS ========== 

    // Used by pools when user redeems
    function pool_burn_from(address b_address, uint256 b_amount) public onlyPools {
        super._burnFrom(b_address, b_amount);
        emit FRAXBurned(b_address, msg.sender, b_amount);
    }

    // This function is what other frax pools will call to mint new FRAX 
    function pool_mint(address m_address, uint256 m_amount) public onlyPools {
        super._mint(m_address, m_amount);
        emit FRAXMinted(msg.sender, m_address, m_amount);
    }

    // Adds collateral addresses supported, such as tether and busd, must be ERC20 
    function addPool(address pool_address) public onlyByOwnerGovernanceOrController {
        require(pool_address != address(0), "Zero address detected");

        require(frax_pools[pool_address] == false, "Address already exists");
        frax_pools[pool_address] = true; 
        frax_pools_array.push(pool_address);

        emit PoolAdded(pool_address);
    }

    // Remove a pool 
    function removePool(address pool_address) public onlyByOwnerGovernanceOrController {
        require(pool_address != address(0), "Zero address detected");
        require(frax_pools[pool_address] == true, "Address nonexistant");
        
        // Delete from the mapping
        delete frax_pools[pool_address];

        // 'Delete' from the array by setting the address to 0x0
        for (uint i = 0; i < frax_pools_array.length; i++){ 
            if (frax_pools_array[i] == pool_address) {
                frax_pools_array[i] = address(0); // This will leave a null in the array and keep the indices the same
                break;
            }
        }

        emit PoolRemoved(pool_address);
    }

    function setRedemptionFee(uint256 red_fee) public onlyByOwnerGovernanceOrController {
        redemption_fee = red_fee;

        emit RedemptionFeeSet(red_fee);
    }

    function setMintingFee(uint256 min_fee) public onlyByOwnerGovernanceOrController {
        minting_fee = min_fee;

        emit MintingFeeSet(min_fee);
    }  

    function setFraxStep(uint256 _new_step) public onlyByOwnerGovernanceOrController {
        frax_step = _new_step;

        emit FraxStepSet(_new_step);
    }  

    function setPriceTarget (uint256 _new_price_target) public onlyByOwnerGovernanceOrController {
        price_target = _new_price_target;

        emit PriceTargetSet(_new_price_target);
    }

    function setRefreshCooldown(uint256 _new_cooldown) public onlyByOwnerGovernanceOrController {
    	refresh_cooldown = _new_cooldown;

        emit RefreshCooldownSet(_new_cooldown);
    }

    function setFXSAddress(address _fxs_address) public onlyByOwnerGovernanceOrController {
        require(_fxs_address != address(0), "Zero address detected");

        fxs_address = _fxs_address;

        emit FXSAddressSet(_fxs_address);
    }

    function setETHUSDOracle(address _eth_usd_consumer_address) public onlyByOwnerGovernanceOrController {
        require(_eth_usd_consumer_address != address(0), "Zero address detected");

        eth_usd_consumer_address = _eth_usd_consumer_address;
        eth_usd_pricer = ChainlinkETHUSDPriceConsumer(eth_usd_consumer_address);
        eth_usd_pricer_decimals = eth_usd_pricer.getDecimals();

        emit ETHUSDOracleSet(_eth_usd_consumer_address);
    }

    function setTimelock(address new_timelock) external onlyByOwnerGovernanceOrController {
        require(new_timelock != address(0), "Zero address detected");

        timelock_address = new_timelock;

        emit TimelockSet(new_timelock);
    }

    function setController(address _controller_address) external onlyByOwnerGovernanceOrController {
        require(_controller_address != address(0), "Zero address detected");

        controller_address = _controller_address;

        emit ControllerSet(_controller_address);
    }

    function setPriceBand(uint256 _price_band) external onlyByOwnerGovernanceOrController {
        price_band = _price_band;

        emit PriceBandSet(_price_band);
    }

    // Sets the FRAX_ETH Uniswap oracle address 
    function setFRAXEthOracle(address _frax_oracle_addr, address _weth_address) public onlyByOwnerGovernanceOrController {
        require((_frax_oracle_addr != address(0)) && (_weth_address != address(0)), "Zero address detected");
        frax_eth_oracle_address = _frax_oracle_addr;
        fraxEthOracle = UniswapPairOracle(_frax_oracle_addr); 
        weth_address = _weth_address;

        emit FRAXETHOracleSet(_frax_oracle_addr, _weth_address);
    }

    // Sets the FXS_ETH Uniswap oracle address 
    function setFXSEthOracle(address _fxs_oracle_addr, address _weth_address) public onlyByOwnerGovernanceOrController {
        require((_fxs_oracle_addr != address(0)) && (_weth_address != address(0)), "Zero address detected");

        fxs_eth_oracle_address = _fxs_oracle_addr;
        fxsEthOracle = UniswapPairOracle(_fxs_oracle_addr);
        weth_address = _weth_address;

        emit FXSEthOracleSet(_fxs_oracle_addr, _weth_address);
    }

    function toggleCollateralRatio() public onlyCollateralRatioPauser {
        collateral_ratio_paused = !collateral_ratio_paused;

        emit CollateralRatioToggled(collateral_ratio_paused);
    }
    
}
