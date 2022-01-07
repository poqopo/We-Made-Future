// SPDX-License-Identifier: MIT
pragma solidity =0.6.6;

import "./We_Made_Future.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";
import "./Oracle/UniswapPairOracle.sol";

contract WUSDStablecoin is ERC20, Ownable {
    using SafeMath for uint256;

    // ========== STATE VARIABLES ========== 
    enum PriceChoice { WUSD, WMF }
    ChainlinkETHUSDPriceConsumer private eth_usd_pricer;
    uint8 private eth_usd_pricer_decimals;
    UniswapPairOracle private WUSDEthOracle;
    UniswapPairOracle private WMFEthOracle;
    address public controller_address; // Controller contract to dynamically adjust system parameters automatically
    address public WMF_address;
    address public WUSD_eth_oracle_address;
    address public WMF_eth_oracle_address;
    address public weth_address;
    address public eth_usd_consumer_address;
    uint256 public constant genesis_supply = 2000000e18; // 2M WUSD (only for testing, genesis supply will be 5k on Mainnet). This is to help with establishing the Uniswap pools, as they need liquidity

    // The addresses in this array are added by the oracle and these contracts are able to mint WUSD
    address[] public WUSD_pools_array;

    // Mapping is also used for faster verification
    mapping(address => bool) public WUSD_pools; 

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e6;
    
    uint256 public global_collateral_ratio; // 6 decimals of precision, e.g. 924102 = 0.924102
    uint256 public redemption_fee; // 6 decimals of precision, divide by 1000000 in calculations for feeredemption_fee
    uint256 public minting_fee; // 6 decimals of precision, divide by 1000000 in calculations for fee
    uint256 public WUSD_step; // Amount to change the collateralization ratio by upon refreshCollateralRatio()
    uint256 public refresh_cooldown; // Seconds to wait before being able to run refreshCollateralRatio() again
    uint256 public price_target; // The price of WUSD at which the collateral ratio will respond to; this value is only used for the collateral ratio mechanism and not for minting and redeeming which are hardcoded at $1
    uint256 public price_band; // The bound above and below the price target at which the refreshCollateralRatio() will not change the collateral ratio

    address public DEFAULT_ADMIN_ADDRESS;
    bool public collateral_ratio_paused = false;

    /* ========== CONSTRUCTOR ========== */

    constructor() public ERC20("We_Made_Future_USD", "WUSD"){
        DEFAULT_ADMIN_ADDRESS = _msgSender();
        _mint(msg.sender, genesis_supply);
        WUSD_step = 2500; // 6 decimals of precision, equal to 0.25%
        global_collateral_ratio = 1000000; // WUSD system starts off fully collateralized (6 decimals of precision)
        refresh_cooldown = 3600; // Refresh cooldown period is set to 1 hour (3600 seconds) at genesis
        price_target = 1000000; // Collateral ratio will adjust according to the $1 price target at genesis
        price_band = 5000; // Collateral ratio will not adjust if between $0.995 and $1.005 at genesis
    }

    /* ========== VIEWS ========== */

    // Choice = 'WUSD' or 'WMF' for now
    function oracle_price(PriceChoice choice) internal view returns (uint256) {
        // Get the ETH / USD price first, and cut it down to 1e6 precision
        uint256 __eth_usd_price = uint256(eth_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** eth_usd_pricer_decimals);
        uint256 price_vs_eth = 0;

        if (choice == PriceChoice.WUSD) {
            price_vs_eth = uint256(WUSDEthOracle.consult(weth_address, PRICE_PRECISION)); // How much WUSD if you put in PRICE_PRECISION WETH
        }
        else if (choice == PriceChoice.WMF) {
            price_vs_eth = uint256(WMFEthOracle.consult(weth_address, PRICE_PRECISION)); // How much WMF if you put in PRICE_PRECISION WETH
        }
        else revert("INVALID PRICE CHOICE. Needs to be either 0 (WUSD) or 1 (WMF)");

        // Will be in 1e6 format
        return __eth_usd_price.mul(PRICE_PRECISION).div(price_vs_eth);
    }

    // Returns X WUSD = 1 USD
    function WUSD_price() public view returns (uint256) {
        return oracle_price(PriceChoice.WUSD);
    }

    // Returns X WMF = 1 USD
    function WMF_price()  public view returns (uint256) {
        return oracle_price(PriceChoice.WMF);
    }

    function eth_usd_price() public view returns (uint256) {
        return uint256(eth_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** eth_usd_pricer_decimals);
    }

    // This is needed to avoid costly repeat calls to different getter functions
    // It is cheaper gas-wise to just dump everything and only use some of the info
    function WUSD_info() public view returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256) {
        return (
            oracle_price(PriceChoice.WUSD), // WUSD_price()
            oracle_price(PriceChoice.WMF), // WMF_price()
            totalSupply(), // totalSupply()
            global_collateral_ratio, // global_collateral_ratio()
            globalCollateralValue(), // globalCollateralValue
            minting_fee, // minting_fee()
            redemption_fee, // redemption_fee()
            uint256(eth_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** eth_usd_pricer_decimals) //eth_usd_price
        );
    }

    /* ========== PUBLIC FUNCTIONS ========== */
    
    // There needs to be a time interval that this can be called. Otherwise it can be called multiple times per expansion.
    uint256 public last_call_time; // Last time the refreshCollateralRatio function was called
    function refreshCollateralRatio() public {
        require(collateral_ratio_paused == false, "Collateral Ratio has been paused");
        uint256 WUSD_price_cur = WUSD_price();
        require(block.timestamp - last_call_time >= refresh_cooldown, "Must wait for the refresh cooldown since last refresh");

        // Step increments are 0.25% (upon genesis, changable by setWUSDStep()) 
        
        if (WUSD_price_cur > price_target.add(price_band)) { //decrease collateral ratio
            if(global_collateral_ratio <= WUSD_step){ //if within a step of 0, go to 0
                global_collateral_ratio = 0;
            } else {
                global_collateral_ratio = global_collateral_ratio.sub(WUSD_step);
            }
        } else if (WUSD_price_cur < price_target.sub(price_band)) { //increase collateral ratio
            if(global_collateral_ratio.add(WUSD_step) >= 1000000){
                global_collateral_ratio = 1000000; // cap collateral ratio at 1.000000
            } else {
                global_collateral_ratio = global_collateral_ratio.add(WUSD_step);
            }
        }

        last_call_time = block.timestamp; // Set the time of the last expansion

        emit CollateralRatioRefreshed(global_collateral_ratio);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // Used by pools when user redeems
    function pool_burn_from(address b_address, uint256 b_amount) public onlyPools {
        super._burnFrom(b_address, b_amount);
        emit WUSDBurned(b_address, msg.sender, b_amount);
    }

    // This function is what other WUSD pools will call to mint new WUSD 
    function pool_mint(address m_address, uint256 m_amount) public onlyPools {
        super._mint(m_address, m_amount);
        emit WUSDMinted(msg.sender, m_address, m_amount);
    }

    // Adds collateral addresses supported, such as tether and busd, must be ERC20 
    function addPool(address pool_address) public onlyByOwnerOrcontroller {
        require(pool_address != address(0), "Zero address detected");

        require(WUSD_pools[pool_address] == false, "Address already exists");
        WUSD_pools[pool_address] = true; 
        WUSD_pools_array.push(pool_address);

        emit PoolAdded(pool_address);
    }

    // Remove a pool 
    function removePool(address pool_address) public onlyByOwnerOrcontroller {
        require(pool_address != address(0), "Zero address detected");
        require(WUSD_pools[pool_address] == true, "Address nonexistant");
        
        // Delete from the mapping
        delete WUSD_pools[pool_address];

        // 'Delete' from the array by setting the address to 0x0
        for (uint i = 0; i < WUSD_pools_array.length; i++){ 
            if (WUSD_pools_array[i] == pool_address) {
                WUSD_pools_array[i] = address(0); // This will leave a null in the array and keep the indices the same
                break;
            }
        }

        emit PoolRemoved(pool_address);
    }

    function setRedemptionFee(uint256 red_fee) public onlyByOwnerOrcontroller {
        redemption_fee = red_fee;

        emit RedemptionFeeSet(red_fee);
    }

    function setMintingFee(uint256 min_fee) public onlyByOwnerOrcontroller {
        minting_fee = min_fee;

        emit MintingFeeSet(min_fee);
    }  

    function setWUSDStep(uint256 _new_step) public onlyByOwnerOrcontroller {
        WUSD_step = _new_step;

        emit WUSDStepSet(_new_step);
    }  

    function setPriceTarget (uint256 _new_price_target) public onlyByOwnerOrcontroller {
        price_target = _new_price_target;

        emit PriceTargetSet(_new_price_target);
    }

    function setRefreshCooldown(uint256 _new_cooldown) public onlyByOwnerOrcontroller {
        refresh_cooldown = _new_cooldown;

        emit RefreshCooldownSet(_new_cooldown);
    }

    function setWMFAddress(address _WMF_address) public onlyByOwnerOrcontroller {
        require(_WMF_address != address(0), "Zero address detected");

        WMF_address = _WMF_address;

        emit WMFAddressSet(_WMF_address);
    }

    function setETHUSDOracle(address _eth_usd_consumer_address) public onlyByOwnerOrcontroller {
        require(_eth_usd_consumer_address != address(0), "Zero address detected");

        eth_usd_consumer_address = _eth_usd_consumer_address;
        eth_usd_pricer = ChainlinkETHUSDPriceConsumer(eth_usd_consumer_address);
        eth_usd_pricer_decimals = eth_usd_pricer.getDecimals();

        emit ETHUSDOracleSet(_eth_usd_consumer_address);
    }


    function setController(address _controller_address) external onlyByOwnerOrcontroller {
        require(_controller_address != address(0), "Zero address detected");

        controller_address = _controller_address;

        emit ControllerSet(_controller_address);
    }

    function setPriceBand(uint256 _price_band) external onlyByOwnerOrcontroller {
        price_band = _price_band;

        emit PriceBandSet(_price_band);
    }

    // Sets the WUSD_ETH Uniswap oracle address 
    function setWUSDEthOracle(address _WUSD_oracle_addr, address _weth_address) public onlyByOwnerOrcontroller {
        require((_WUSD_oracle_addr != address(0)) && (_weth_address != address(0)), "Zero address detected");
        WUSD_eth_oracle_address = _WUSD_oracle_addr;
        WUSDEthOracle = UniswapPairOracle(_WUSD_oracle_addr); 
        weth_address = _weth_address;

        emit WUSDETHOracleSet(_WUSD_oracle_addr, _weth_address);
    }

    // Sets the WMF_ETH Uniswap oracle address 
    function setWMFEthOracle(address _WMF_oracle_addr, address _weth_address) public onlyByOwnerOrcontroller {
        require((_WMF_oracle_addr != address(0)) && (_weth_address != address(0)), "Zero address detected");

        WMF_eth_oracle_address = _WMF_oracle_addr;
        WMFEthOracle = UniswapPairOracle(_WMF_oracle_addr);
        weth_address = _weth_address;

        emit WMFEthOracleSet(_WMF_oracle_addr, _weth_address);
    }

    function toggleCollateralRatio() public onlyCollateralRatioPauser {
        collateral_ratio_paused = !collateral_ratio_paused;

        emit CollateralRatioToggled(collateral_ratio_paused);
    }

    /* ========== EVENTS ========== */

    // Track WUSD burned
    event WUSDBurned(address indexed from, address indexed to, uint256 amount);

    // Track WUSD minted
    event WUSDMinted(address indexed from, address indexed to, uint256 amount);

    event CollateralRatioRefreshed(uint256 global_collateral_ratio);
    event PoolAdded(address pool_address);
    event PoolRemoved(address pool_address);
    event RedemptionFeeSet(uint256 red_fee);
    event MintingFeeSet(uint256 min_fee);
    event WUSDStepSet(uint256 new_step);
    event PriceTargetSet(uint256 new_price_target);
    event RefreshCooldownSet(uint256 new_cooldown);
    event WMFAddressSet(address _WMF_address);
    event ETHUSDOracleSet(address eth_usd_consumer_address);
    event ControllerSet(address controller_address);
    event PriceBandSet(uint256 price_band);
    event WUSDETHOracleSet(address WUSD_oracle_addr, address weth_address);
    event WMFEthOracleSet(address WMF_oracle_addr, address weth_address);
    event CollateralRatioToggled(bool collateral_ratio_paused);
}