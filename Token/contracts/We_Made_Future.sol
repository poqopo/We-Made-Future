// SPDX-License-Identifier: MIT
pragma solidity =0.6.6;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";


contract We_Made_Future is ERC20 , Ownable {
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */
    address public WUSDStablecoinAdd;  
    uint256 public constant genesis_supply = 100000000e18; // 100M is printed upon genesis
    address public oracle_address;
    WUSDStablecoin private WUSD;

    /* ========== CONSTRUCTOR ========== */

    constructor () public ERC20("We_Made_Future", "WMF"){
        oracle_address = _oracle_address;
        _mint(msg.sender, genesis_supply);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setOracle(address new_oracle) external onlyByOwnGov {
        require(new_oracle != address(0), "Zero address detected");
        oracle_address = new_oracle;
    }

    function setWUSDAddress(address WUSD_contract_address) external onlyByOwnGov {
        require(WUSD_contract_address != address(0), "Zero address detected");

        WUSD = WUSDStablecoin(WUSD_contract_address);
        emit WUSDAddressSet(WUSD_contract_address);
    }
    
    // This function is what other WUSD pools will call to mint new WMF (similar to the WUSD mint) 
    function pool_mint(address m_address, uint256 m_amount) external onlyPools {        
        super._mint(m_address, m_amount);
        emit WMFMinted(address(this), m_address, m_amount);
    }

    // This function is what other WUSD pools will call to burn WMF 
    function pool_burn_from(address b_address, uint256 b_amount) external onlyPools {

        super._burnFrom(b_address, b_amount);
        emit WMFBurned(b_address, address(this), b_amount);
    }
    /* ========== EVENTS ========== */

    // Track WMF burned
    event WMFBurned(address indexed from, address indexed to, uint256 amount);
    // Track WMF minted
    event WMFMinted(address indexed from, address indexed to, uint256 amount);
    event WUSDAddressSet(address addr);
}