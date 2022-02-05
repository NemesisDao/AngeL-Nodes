// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "./node_modules/openzeppelin/contracts/utils/Context.sol";
import "./node_modules/openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./node_modules/openzeppelin/contracts/access/Ownable.sol";
import "./node_modules/openzeppelin/contracts/utils/math/SafeMath.sol";
import "./node_modules/openzeppelin/contracts/utils/Address.sol";

import "./uniswap/IUniswapV2Router.sol";
import "./uniswap/IUniswapV2Factory.sol";

import "./AngelNodeManager.sol";

contract Angel is ERC20, Ownable {
    using SafeMath for uint256;

    AngelNodeManager private nodeManager;

    // Global Informations
    uint8 private _decimals = 8;
    uint256 private _totalSupply = 10_000_000 * (10**8);

    // Fees
    uint256 public _futurUseSellFee = 15; // 15
    uint256 public _burnSellFee = 0; // 0
    uint256 public _futurUseNodeFee = 7; // 7
    uint256 public _liquidityPoolFee = 20; // 20
    uint256 public _distributionSwapFee = 3; // 3 | 3% of the 73% from rewardsNodeFee

    uint256 public _boosterChildAmount = 3;

    // Pools & Wallets
    address public _futurUsePool = 0x31D0b942b31C8Ecf41d09A178A2F2ec4D3cFbe71;
    address public _distributionPool = 0xFE2B4a02cdbF18be695791A80Fc8CbE1a8297670;
    address public _deadWallet = 0x000000000000000000000000000000000000dEaD;

    // Pancakeswap V2
    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;
    bool private swapping = false;
    uint256 public swapTokensAtAmount = 300 * (10**8);

    // Security
    mapping(address => bool) public _isBlacklisted;
    mapping (address => bool) private _isExcludedFromFees;

    // Events
    event UpdateUniswapV2Router(address indexed newAddress, address indexed oldAddress);
    event ExcludeFromFees(address indexed account, bool isExcluded);
    event LiquidityWalletUpdated(address indexed newLiquidityWallet, address indexed oldLiquidityWallet);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 tokensIntoLiqudity);

    constructor() ERC20("Angel Nodes", "AngeL") {
        nodeManager = new AngelNodeManager();

        uniswapV2Router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory())
            .createPair(address(this), uniswapV2Router.WETH());

        // Exclude from paying fees or having max transaction amount
        excludeFromFees(owner(), true);
        excludeFromFees(_futurUsePool, true);
        excludeFromFees(_distributionPool, true);
        excludeFromFees(address(this), true);

        _mint(owner(), _totalSupply);
    }

    function decimals() public view virtual override returns (uint8) {
      return _decimals;
    }

    receive() external payable {}

    function buyNode(string memory name, uint256 nodeType) external  {
      address sender = safeSender();

      require(bytes(name).length >= 3 && bytes(name).length <= 32,
        "Name size must be between 3 and 32 length");

      uint256 price = nodeManager._getPriceOfNode(nodeType);
      require(balanceOf(sender) >= price,
        "You have not the balance to buy this node");

      uint256 contractAngelBalance = balanceOf(address(this));
      bool canProcess = contractAngelBalance >= swapTokensAtAmount;

      if (canProcess && !swapping) {
          swapping = true;

          // FuturUse
          if(_futurUseNodeFee > 0) {
            uint256 futurUseTokens = contractAngelBalance.mul(_futurUseNodeFee).div(100);
            swapAndSendToFee(_futurUsePool, futurUseTokens);
          }

          // Liquidity
          if(_liquidityPoolFee > 0) {
            uint256 swapTokens = contractAngelBalance.mul(_liquidityPoolFee).div(100);
            swapAndLiquify(swapTokens);
          }

          // Distribution
          if(_distributionSwapFee > 0) {
            uint256 distributionTokensToSwap = balanceOf(address(this)).mul(_distributionSwapFee).div(100);
            swapAndSendToFee(_distributionPool, distributionTokensToSwap);
          }

          super._transfer(address(this), _distributionPool, balanceOf(address(this)));

          swapping = false;
      }

      super._transfer(sender, address(this), price);

      nodeManager._buyNode(msg.sender, name, nodeType);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
      require(from != address(0), "Transfer from the zero address");
      require(to != address(0), "Transfer to the zero address");
      require(from != _deadWallet, "Transfer from the dead wallet address");
      require(!_isBlacklisted[from] && !_isBlacklisted[to], 'Blacklisted address');

      if(amount == 0) {
        super._transfer(from, to, 0);
        return;
      }

      // If any account is inside _isExcludedFromFee then don't take the fee
      bool takeFee = !(_isExcludedFromFees[from] || _isExcludedFromFees[to]);

      // Fees on sell
      if(takeFee && to == uniswapV2Pair) {
        uint256 futurFees = amount.mul(_futurUseSellFee).div(100);
        super._transfer(from, _futurUsePool, futurFees);

        uint256 burnFees = amount.mul(_burnSellFee).div(100);
        super._transfer(from, _deadWallet, burnFees);

        amount = amount.sub(futurFees).sub(burnFees);
      }

      super._transfer(from, to, amount);
    }

    /*
     * Wrapper
     */
    function cashoutNode(uint256 id) external {
      address sender = safeSender();
      uint256 rewards = nodeManager._cashoutNode(sender, id);
      super._transfer(_distributionPool, sender, rewards);
    }

    function cashoutAllNodes() external {
      address sender = safeSender();
      uint256 rewards = nodeManager._cashoutAllNodes(sender);
      super._transfer(_distributionPool, sender, rewards);
    }

    function upgradeNode(uint256 id) external returns (bool) {
      address sender = safeSender();
      return nodeManager._upgradeNode(sender, id);
    }

    function upgradeAllNodes() external returns (uint256) {
      address sender = safeSender();
      return nodeManager._upgradeAllNodes(sender);
    }

    function claimUpgrade(uint256 id) external returns (bool) {
      address sender = safeSender();
      return nodeManager._claimUpgrade(sender, id);
    }

    function setSwapTokensAtAmount(uint256 amount) external onlyOwner {
      swapTokensAtAmount = amount;
    }

    function giveNode(address[] memory users, string memory name, uint256 nodeType) external onlyOwner {
      for (uint256 i = 0; i < users.length; i++)
        nodeManager._createNode(users[i], name, nodeType);
    }

    function getPriceOfNode(uint256 nodeTypeId) external view returns (uint256) {
      return nodeManager._getPriceOfNode(nodeTypeId);
    }

    function setBoosterCode(string memory code) external {
      address sender = safeSender();
      nodeManager._setBoosterCode(sender, code);
    }

    function useBoosterCode(string memory code) external {
      address sender = safeSender();
      nodeManager._useBoosterCode(sender, code);
      super._transfer(_distributionPool, sender, _boosterChildAmount);
    }

    function getClaimableUpgrades(address user) external view returns (uint256[] memory) {
      return nodeManager._getClaimableUpgrades(user);
    }

    function updateGasForProcessing(uint256 newValue) external onlyOwner {
        nodeManager._updateGasForProcessing(newValue);
    }

    function updateClaimingTimestamp(uint256 newValue) external onlyOwner {
        nodeManager._setClaimingTimestamp(newValue);
    }

    function updateMaxNodes(uint256 newValue) external onlyOwner {
        nodeManager._setMaxNodes(newValue);
    }

    function getClaimingTimestamp() external view returns (uint256) {
        return nodeManager._getClaimingTimestamp();
    }

    function getMaxNodes() external view returns (uint256) {
        return nodeManager._getMaxNodes();
    }

    function getTotalEarned() external view returns (uint256) {
        return nodeManager._getTotalEarned();
    }

    function setMinimumNodeUseRef(uint256 nodeId) external onlyOwner {
      return nodeManager._setMinimumNodeUseRef(nodeId);
    }

    function setMinimumNodeSetRef(uint256 nodeId) external onlyOwner {
      return nodeManager._setMinimumNodeSetRef(nodeId);
    }

    function setMaxAmountPerNode(uint256 amount) external onlyOwner {
      return nodeManager._setMaxAmountPerNode(amount);
    }

    function getTotalCreatedNodes() external view returns (uint256) {
        return nodeManager._getTotalCreatedNodes();
    }

    function getNodes(address user) external view returns (AngelNodeManager.Node[] memory) {
      return nodeManager._getNodes(user);
    }

    function getNodeTypes() external onlyOwner view returns (AngelNodeManager.NodeType[] memory) {
      return nodeManager._getNodeTypes();
    }

    function getBoosterDatas(address user) external view returns (AngelNodeManager.BoosterData memory) {
      return nodeManager._getBoosterDatas(user);
    }

    function editNodeType(uint256 nodeTypeId, uint256 rewards, uint256 timeToUpgrade, uint256 typeUpgradeNode,
                           uint256 price, bool buyable, bool upgradable, bool bonus) external onlyOwner {
      nodeManager._editNodeType(nodeTypeId, rewards, timeToUpgrade, typeUpgradeNode, price, buyable, upgradable, bonus);
    }

    function addNodeType(uint256 rewards, uint256 timeToUpgrade, uint256 typeUpgradeNode,
                           uint256 price, bool buyable, bool upgradable, bool bonus) external onlyOwner {
      nodeManager._addNodeType(rewards, timeToUpgrade, typeUpgradeNode, price, buyable, upgradable, bonus);
    }

    function disableNodeType(uint256 id) external onlyOwner {
      nodeManager._disableNodeType(id);
    }

    function enableNodeType(uint256 id) external onlyOwner {
      nodeManager._enableNodeType(id);
    }

    function processDistribution() external onlyOwner {
      nodeManager._processDistribution();
    }

    /*
     * Utils
     */
    function safeSender() private view returns (address) {
      address sender = _msgSender();

      require(sender != address(0), "Cannot cashout from the zero address");
      require(!_isBlacklisted[sender], "Blacklisted address");

      return sender;
    }

    function swapTokensForEth(uint256 tokenAmount) private {
      address[] memory path = new address[](2);
      path[0] = address(this);
      path[1] = uniswapV2Router.WETH();

      _approve(address(this), address(uniswapV2Router), tokenAmount);

      uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
        tokenAmount,
        0,
        path,
        address(this),
        block.timestamp
      );
    }

    function swapAndSendToFee(address destination, uint256 tokens) private {
      uint256 initialETHBalance = address(this).balance;

      swapTokensForEth(tokens);
      uint256 newBalance = (address(this).balance).sub(initialETHBalance);

      payable(destination).transfer(newBalance);
    }

    function swapAndLiquify(uint256 tokens) private {
      uint256 half = tokens.div(2);
      uint256 otherHalf = tokens.sub(half);

      uint256 initialBalance = address(this).balance;

      // Swaping the half
      swapTokensForEth(half);
      uint256 newBalance = address(this).balance.sub(initialBalance);

      // Approving and adding liquidity
      _approve(address(this), address(uniswapV2Router), tokens);
      uniswapV2Router.addLiquidityETH{value: newBalance}(
        address(this),
        tokens,
        0,
        0,
        address(0),
        block.timestamp
      );

      emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    function setFuturUsePool(address payable wallet) external onlyOwner {
       _futurUsePool = wallet;
    }

    function setDistributionPool(address payable wallet) external onlyOwner {
       _distributionPool = wallet;
    }

    function blacklistAddress(address account, bool value) external onlyOwner {
      _isBlacklisted[account] = value;
    }

    function setFuturUseSellFee(uint256 value) external onlyOwner {
      _futurUseSellFee = value;
    }

    function setBurnSellFee(uint256 value) external onlyOwner {
      _burnSellFee = value;
    }

    function setFuturUseNodeFee(uint256 value) external onlyOwner {
      _futurUseNodeFee = value;
    }

    function setLiquidityPoolFee(uint256 value) external onlyOwner {
      _liquidityPoolFee = value;
    }

    function setDistributionSwapFee(uint256 value) external onlyOwner {
      _distributionSwapFee = value;
    }

    function setPairAddress(address pair) external onlyOwner {
        uniswapV2Pair = pair;
    }

    function setBoosterChildAmount(uint256 value) external onlyOwner {
      _boosterChildAmount = value;
    }

    function updateUniswapV2Router(address newAddress) external onlyOwner {
        require(newAddress != address(uniswapV2Router), "The router already has that address");
        emit UpdateUniswapV2Router(newAddress, address(uniswapV2Router));

        uniswapV2Router = IUniswapV2Router02(newAddress);

        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory())
            .createPair(address(this), uniswapV2Router.WETH());
    }

    function excludeFromFees(address account, bool excluded) public onlyOwner {
        _isExcludedFromFees[account] = excluded;
        emit ExcludeFromFees(account, excluded);
    }

    function isExcludedFromFees(address account) public view returns(bool) {
      return _isExcludedFromFees[account];
    }

}