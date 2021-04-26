// Mainnet Live

//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "./lib/ERC20.sol";
import "./lib/SafeMath.sol";
import "./lib/IERC20.sol";
import "./lib/Ownable.sol";


interface ISorbettiere {
    function pendingIce(uint256 _pid, address _user) external view returns (uint256);
    function deposit(uint256 _pid, uint256 _amount) external;
    function withdraw(uint256 _pid, uint256 _amount) external;
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
}

contract CompoundingIce is ERC20('CompoundingIce','cICE'), Ownable {

  using SafeMath for uint;

  IERC20 public ICE;
  ISorbettiere public stakingContract;

  uint public PID;
  uint public totalDeposits;
  uint256 public MIN_TOKENS_TO_REINVEST = 1000000000000000000;
  address public strategist;                  // dev
  uint public PERFORMANCE_FEE_BIPS =     500; // 5%
  uint public MAX_PERFORMANCE_FEE_BIPS = 500; // 5%
  uint constant private BIPS_DIVISOR = 10000; // 100%

  event Deposit(address account, uint amount);
  event Withdraw(address account, uint amount);
  event Reinvest(uint newTotalDeposits, uint newTotalSupply);
  event Recovered(address token, uint amount);
  event UpdatePerformanceFee(uint oldValue, uint newValue);
  event strategistChanged(address caller, address newStrategist);

  constructor(
    address _strategist,
    address _ICE,
    address _stakingContract,
    uint _pid
  ) {
    strategist = _strategist;
    ICE = IERC20(_ICE);

    stakingContract = ISorbettiere(_stakingContract);
    IERC20(_ICE).approve(_stakingContract, uint(-1)); 
    PID = _pid;
  }

  /**
   * @notice Deposit ICE to receive Compounding Ice🍧 reciept tokens, deposit also calls reinvest which compounds the entire pools earnings <3
   * @param amount Amount of ICE to deposit
   */
  function deposit(uint amount) external {
    _deposit(amount);
  }



  function _deposit(uint amount) internal {
    require(totalDeposits >= totalSupply(), "deposit failed");
    require(ICE.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
    _stakeICE(amount);
    _mint(msg.sender, getSharesPerDepositTokens(amount));
    totalDeposits = totalDeposits.add(amount);
    emit Deposit(msg.sender, amount);
  }

  /**
   * @notice Withdraw ICE by redeeming Compounding Ice🍧 reciept tokens
   * @param amount Amount of Compounding Ice🍧 reciept tokens to redeem
   */
  function withdraw(uint amount) external {
    uint iceRewardAmount = getDepositTokensPerShares(amount);
    if (iceRewardAmount > 0) {
      _withdrawICE(iceRewardAmount);
      require(ICE.transfer(msg.sender, iceRewardAmount), "transfer failed");
      _burn(msg.sender, amount);
      totalDeposits = totalDeposits.sub(iceRewardAmount);
      emit Withdraw(msg.sender, iceRewardAmount);
    }
  }

  /**
   * @notice Calculate Compounding Ice🍧 reciept tokens for a given amount of ICE
   * @dev If contract is empty, use 1:1 ratio
   * @dev Could return zero shares for very low amounts of ICE
   * @param amount of ICE
   * @return amount of Compounding Ice🍧 reciept tokens
   */
  function getSharesPerDepositTokens(uint amount) public view returns (uint) {
    if (totalSupply().mul(totalDeposits) == 0) {
      return amount;
    }
    return amount.mul(totalSupply()).div(totalDeposits);
  }

  /**
   * @notice Calculate ICE for a given amount of Compounding Ice🍧 reciept tokens
   * @param amount of Compounding Ice🍧 reciept tokens
   * @return ICE
   */
  function getDepositTokensPerShares(uint amount) public view returns (uint) {
    if (totalSupply().mul(totalDeposits) == 0) {
      return 0;
    }
    return amount.mul(totalDeposits).div(totalSupply());
  }

  /**
   * @notice Reward token balance that can be reinvested
   * @dev Staking rewards accurue to contract on each deposit/withdrawal
   * @return Unclaimed rewards, plus contract balance
   */
  function checkReward() public view returns (uint) {
    uint pendingReward = stakingContract.pendingIce(PID, address(this));
    uint contractBalance = ICE.balanceOf(address(this));
    return pendingReward.add(contractBalance);
  }

  /**
   * @notice Reinvest rewards from staking contract to ICE
   */
  function reinvest() public {
    uint unclaimedRewards = checkReward();
    // harvest earnings
    stakingContract.deposit(PID, 0);
    // calculate performanceFee
    uint performanceFee = unclaimedRewards.mul(PERFORMANCE_FEE_BIPS).div(BIPS_DIVISOR);
    // sends strategist performance fee, if there is one
    if (performanceFee > 0) {
      require(ICE.transfer(strategist, performanceFee), "performance fee transfer failed");
    }
    uint iceRewardAmount = unclaimedRewards.sub(performanceFee);
    _stakeICE(iceRewardAmount);
    totalDeposits = totalDeposits.add(iceRewardAmount);
    emit Reinvest(totalDeposits, totalSupply());
  }

  /**
   * @notice Stakes ICE in Staking Contract
   * @param amount ICE to stake
   */
  function _stakeICE(uint amount) internal {
    require(amount > 0, "amount too low");
    stakingContract.deposit(PID, amount);
  }

  /**
   * @notice Withdraws ICE from Staking Contract
   * @dev Rewards are not automatically collected from the Staking Contract
   * @param amount ICE to remove;
   */
  function _withdrawICE(uint amount) internal {
    require(amount > 0, "amount too low");
    stakingContract.withdraw(PID, amount);
  }

  /**
   * @notice Update performance fee
   * @dev Total fees cannot be greater than BIPS_DIVISOR (100%), or MAX_PERFORMANCE_FEE_BIPS (5%)
   * @param newValue specified in BIPS
   */
  function updatePerformanceFee(uint newValue) external onlyOwner {
    require(newValue <= MAX_PERFORMANCE_FEE_BIPS);
    require(newValue <= BIPS_DIVISOR, "performance fee too high");
    emit UpdatePerformanceFee(PERFORMANCE_FEE_BIPS, newValue);
    PERFORMANCE_FEE_BIPS = newValue;
  }

  function newStrategist(address _newStrategist) external {
      require(msg.sender == strategist);
      emit strategistChanged(msg.sender, _newStrategist);
      strategist = _newStrategist;
  }
  
  function changeMinReinvestTokens(uint256 _MIN_TOKENS_TO_REINVEST) external {
      require(msg.sender == strategist);
      MIN_TOKENS_TO_REINVEST = _MIN_TOKENS_TO_REINVEST;
  }
}
