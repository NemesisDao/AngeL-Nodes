// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "./node_modules/openzeppelin/contracts/utils/Context.sol";
import "./node_modules/openzeppelin/contracts/access/Ownable.sol";
import "./node_modules/openzeppelin/contracts/utils/math/SafeMath.sol";
import "./node_modules/openzeppelin/contracts/utils/Address.sol";

import "./uniswap/IUniswapV2Router.sol";
import "./uniswap/IUniswapV2Factory.sol";

import "./IterableMapping.sol";

contract AngelNodeManager is Ownable {
    using SafeMath for uint256;
    using IterableMapping for IterableMapping.Map;

    event GasForProcessingUpdated(uint256 indexed newValue, uint256 indexed oldValue);

    // Nodes
    struct NodeType {
      uint256 rewards; // Rewards of the Node
      uint256 timeToUpgrade; // Time to upgrade to the next Node
      uint256 typeUpgradeNode; // Type of the next Node
      uint256 price; // Price of the Node

      bool buyable;
      bool upgradable;
      bool disabled;
      bool bonus; // Bonus = not calculated in maxNode
    }

    struct Node {
      uint256 id;
      string name;
      uint256 nodeType;

      bool upgrading;

      uint256 createTimestamp;
      uint256 lastClaimTimestamp;
      uint256 angelUpgradeStartTimestamp;

      uint256 availableRewards;
    }

    // Booster
    struct BoosterData {
      address[] boosterChilds;
      address boosterGodFather;
      string boosterCode;

      bool boosterCodeSetup;
      bool boosterCodeUsed;
    }

    struct BoosterCode {
      bool isValid;
      address codeOwner;
      uint256 used;
    }

    // Settings
    uint256 public _maxNodes = 100;
    uint256 public _claimingTimestamp = 86400;
    uint256 public _gasForProcessing = 300000;
    uint256 public _minimumNodeUseRef = 1;
    uint256 public _minimumNodeSetRef = 3;
    uint256 public _maxAmountPerNode = 3;

    // Datas
    uint256 public _totalCreatedNodes = 0;
    uint256 public _totalEarn = 0;
    uint256 public _lastProcessedIndex = 0;
    bool private distributing = false;

    // Nodes
    IterableMapping.Map private nodeOwners;
    mapping(address => Node[]) private usersNodes;
    NodeType[] _nodeTypes;

    // Boosters
    mapping(address => BoosterData) private boosterDatas;
    mapping(string => BoosterCode) private boosterCodes;

    constructor() {
      // Angel
      _nodeTypes.push(NodeType({
        rewards: 0.066 * (10**8),
        timeToUpgrade: 66 * 3600 * 24, // 66 Days
        typeUpgradeNode: 1, // Upgrade possible to 1
        price: 13 * (10**8),
        buyable: true,
        upgradable: true,
        disabled: false,
        bonus: false
      }));

      // Dark Angel
      _nodeTypes.push(NodeType({
        rewards: 0.366 * (10**8),
        timeToUpgrade: 33 * 3600 * 24, // 33 Days
        typeUpgradeNode: 2, // Upgrade possible to 2
        price: 66 * (10**8),
        buyable: true,
        upgradable: true,
        disabled: false,
        bonus: false
      }));

      // Arch Angel
      _nodeTypes.push(NodeType({
        rewards: 0.666 * (10**8),
        timeToUpgrade: 11 * 3600 * 24, // 11 Days
        typeUpgradeNode: 3, // Upgrade possible to 3
        price: 111 * (10**8),
        buyable: true,
        upgradable: true,
        disabled: false,
        bonus: false
      }));

      // Nemesis
      _nodeTypes.push(NodeType({
        rewards: 1 * (10**8),
        timeToUpgrade: 0,
        typeUpgradeNode: 0, // Upgrade impossible
        price: 100000000 * (10**8),
        buyable: false,
        upgradable: false,
        disabled: false,
        bonus: false
      }));

      // Booster
      _nodeTypes.push(NodeType({
        rewards: 0.111 * (10**8),
        timeToUpgrade: 0,
        typeUpgradeNode: 0, // Upgrade impossible
        price: 100000000 * (10**8),
        buyable: false,
        upgradable: false,
        disabled: false,
        bonus: true
      }));
    }

    function _setBoosterCode(address user, string memory code) external onlyOwner {
      require(!boosterCodes[code].isValid, "This code is already exist");
      require(!boosterDatas[user].boosterCodeSetup, "Cannot edit a booster code");
      require(getNumberOfSpecifiedMinNodes(user, _minimumNodeSetRef) > 0, "You need to have a specific node");

      boosterCodes[code].isValid = true;
      boosterCodes[code].codeOwner = user;
      boosterCodes[code].used = 0;

      boosterDatas[user].boosterCodeSetup = true;
      boosterDatas[user].boosterCode = code;
      boosterDatas[user].boosterGodFather = user;
    }

    function _useBoosterCode(address user, string memory code) external onlyOwner returns (address) {
      require(boosterCodes[code].isValid, "This code is not valid");
      require(!boosterDatas[user].boosterCodeUsed, "You already used a code");
      require(getNumberOfSpecifiedMinNodes(user, _minimumNodeUseRef) > 0, "You need to have a specific node");

      address codeOwner = boosterCodes[code].codeOwner;
      require(codeOwner != user, "You cannot use your code");
      require(
        boosterDatas[codeOwner].boosterChilds.length < getNumberOfSpecifiedMinNodes(codeOwner, _minimumNodeSetRef) * _maxAmountPerNode,
        "The code owner has no empty place");

      boosterDatas[codeOwner].boosterChilds.push(user);
      boosterDatas[user].boosterCodeUsed = true;
      boosterDatas[user].boosterGodFather = codeOwner;

      _createNode(codeOwner, "Booster Node", 4);

      return codeOwner;
    }

    function _createNode(address user, string memory name, uint256 nodeTypeId) public onlyOwner {
      require(_getNumberOfNodes(user) < _maxNodes, "Maximum of nodes reached");

      uint256 id = ++_totalCreatedNodes;

      usersNodes[user].push(Node({
        id: id,
        name: name,
        nodeType: nodeTypeId,
        upgrading: false,
        createTimestamp: block.timestamp,
        lastClaimTimestamp: block.timestamp,
        angelUpgradeStartTimestamp: 0,
        availableRewards: 0
      }));

      nodeOwners.set(user, usersNodes[user].length);

      if(!distributing) distributeRewards();
    }

    function _buyNode(address user, string memory name, uint256 nodeTypeId) external onlyOwner {
      NodeType storage nodeType = _nodeTypes[nodeTypeId];
      require(!nodeType.disabled, "Cannot buy a disabled node");
      require(nodeType.buyable, "Cannot buy a non-buyable node");

      _createNode(user, name, nodeTypeId);
    }

    function distributeRewards() private returns (uint256, uint256) {
      distributing = true;
      require(_totalCreatedNodes > 0, "No nodes to distribute");

      uint256 ownersCount = nodeOwners.keys.length;
      uint256 gasUsed = 0;
      uint256 gasLeft = gasleft();
      uint256 newGasLeft;
      uint256 iterations = 0;
      uint256 claims = 0;

      Node[] storage nodes;
      Node storage _node;
      NodeType storage _nodeType;

      while (gasUsed < _gasForProcessing && iterations < ownersCount) {
        if (_lastProcessedIndex >= nodeOwners.keys.length) _lastProcessedIndex = 0;

        nodes = usersNodes[nodeOwners.keys[_lastProcessedIndex]];
        for (uint256 i = 0; i < nodes.length; i++) {
          _node = nodes[i];
          _nodeType = _nodeTypes[_node.nodeType];

          // If we can process a claim, if is not a disabled node and not in upgrade
          if (canClaim(_node) && !_nodeType.disabled && !_node.upgrading) {
            _node.availableRewards += _nodeType.rewards;
            _node.lastClaimTimestamp = block.timestamp;
            _totalEarn += _nodeType.rewards;
            claims++;
          }
        }

        newGasLeft = gasleft();
        if (gasLeft > newGasLeft) gasUsed = gasUsed.add(gasLeft.sub(newGasLeft));
        gasLeft = newGasLeft;

        iterations++;

        _lastProcessedIndex++;
      }

      distributing = false;
      return (iterations, claims);
    }

    function _cashoutNode(address user, uint256 id) external onlyOwner returns (uint256) {
      Node[] storage nodes = usersNodes[user];

      uint256 nodesCount = nodes.length;
      require(nodesCount > 0, "No nodes to cashout");

      (uint256 nodeIndex, bool finded) = getNodeIndexWithId(nodes, id);

      require(finded, "Cannot find the node");

      Node storage node = nodes[nodeIndex];
      uint256 rewards = node.availableRewards;
      node.availableRewards = 0;

      return rewards;
    }

    function _cashoutAllNodes(address user) external onlyOwner returns (uint256) {
      Node[] storage nodes = usersNodes[user];

      uint256 nodesCount = nodes.length;
      require(nodesCount > 0, "No nodes to cashout");

      Node storage _node;
      uint256 rewards = 0;

      for (uint256 i = 0; i < nodesCount; i++) {
        _node = nodes[i];
        rewards += _node.availableRewards;
        _node.availableRewards = 0;
      }

      return rewards;
    }

    function _upgradeNode(address user, uint256 id) external onlyOwner returns (bool) {
      Node[] storage nodes = usersNodes[user];

      uint256 nodesCount = nodes.length;
      require(nodesCount > 0, "No nodes to upgrade");

      (uint256 nodeIndex, bool finded) = getNodeIndexWithId(nodes, id);
      require(finded, "Cannot find the node");

      Node storage node = nodes[nodeIndex];
      require(!node.upgrading, "Already upgrading");

      NodeType storage nodeType = _nodeTypes[node.nodeType];
      require(nodeType.upgradable, "Cannot upgrade this Node");

      node.upgrading = true;
      node.angelUpgradeStartTimestamp = block.timestamp;

      return true;
    }

    function _upgradeAllNodes(address user) external onlyOwner returns (uint256) {
      Node[] storage nodes = usersNodes[user];

      uint256 nodesCount = nodes.length;
      require(nodesCount > 0, "No nodes to cashout");

      Node storage node;
      NodeType storage nodeType;
      uint256 count = 0;

      for (uint256 i = 0; i < nodes.length; i++) {
        node = nodes[i];
        nodeType = _nodeTypes[node.nodeType];

        if(!node.upgrading && nodeType.upgradable) {
          node.upgrading = true;
          node.angelUpgradeStartTimestamp = block.timestamp;
          count++;
        }
      }

      return count;
    }

    function _claimUpgrade(address user, uint256 id) external onlyOwner returns (bool) {
      Node[] storage nodes = usersNodes[user];

      uint256 nodesCount = nodes.length;
      require(nodesCount > 0, "No nodes to cashout");

      (uint256 nodeIndex, bool finded) = getNodeIndexWithId(nodes, id);
      require(finded, "Cannot find the node");

      Node storage node = nodes[nodeIndex];
      require(canClaimUpgrade(node), "Cannot claim the upgrade node");

      node.upgrading = false;
      node.angelUpgradeStartTimestamp = 0;
      node.nodeType = _nodeTypes[node.nodeType].typeUpgradeNode;

      return true;
    }

    function _getClaimableUpgrades(address user) external onlyOwner view returns (uint256[] memory) {
      require(_getNumberOfNodes(user) > 0, "Cannot claim any nodes");

      Node[] storage nodes = usersNodes[user];
      Node storage node;
      NodeType storage nodeType;
      uint256[] memory idsClaimable = new uint256[](nodes.length);

      for (uint256 i = 0; i < nodes.length; i++) {
        node = nodes[i];
        nodeType = _nodeTypes[node.nodeType];

        if(node.upgrading) {
          if(block.timestamp >= node.angelUpgradeStartTimestamp + nodeType.timeToUpgrade) {
            idsClaimable[idsClaimable.length] = node.id;
          }
        }
      }

      return idsClaimable;
    }

    // Utils
    function canClaim(Node memory node) private view returns (bool) {
      return block.timestamp >= node.lastClaimTimestamp + _claimingTimestamp;
    }

    function getNodeIndexWithId(Node[] storage nodes, uint256 id) private view returns (uint256, bool) {
      for (uint256 i = 0; i < nodes.length; i++) {
        if(nodes[i].id == id) return (i, true);
      }
      return (0, false);
    }

    function canClaimUpgrade(Node memory node) private view returns (bool) {
      NodeType storage nodeType = _nodeTypes[node.nodeType];

      return node.upgrading && block.timestamp >= node.angelUpgradeStartTimestamp + nodeType.timeToUpgrade;
    }

    function getNumberOfSpecifiedMinNodes(address user, uint256 nodeTypeId) private view returns (uint256) {
      Node[] storage nodes = usersNodes[user];
      Node storage node;
      uint256 count = 0;

      for (uint256 i = 0; i < nodes.length; i++) {
        node = nodes[i];
        if(node.nodeType >= nodeTypeId && !_nodeTypes[node.nodeType].bonus) count++;
      }

      return count;
    }

    function _processDistribution() external onlyOwner {
      distributeRewards();
    }

    // Getters
    function _getClaimingTimestamp() external view returns (uint256) {
      return _claimingTimestamp;
    }

    function _getMaxNodes() external view returns (uint256) {
      return _maxNodes;
    }

    function _getTotalEarned() external view returns (uint256) {
      return _totalEarn;
    }

    function _getTotalCreatedNodes() external view returns (uint256) {
      return _totalCreatedNodes;
    }

    function _getNumberOfNodes(address user) private view returns (uint256) {
      Node[] storage nodes = usersNodes[user];
      uint256 count = 0;

      for (uint256 i = 0; i < nodes.length; i++) {
        if(!_nodeTypes[nodes[i].nodeType].bonus) count++;
      }

      return count;
    }

    function _isNodeOwner(address user) private view returns (bool) {
      return usersNodes[user].length > 0;
    }

    function _getPriceOfNode(uint256 nodeTypeId) public view returns (uint256) {
      require(nodeTypeId < _nodeTypes.length && nodeTypeId >= 0, "Not valid id of a type of Node");

      return _nodeTypes[nodeTypeId].price;
    }

    function _getNodes(address user) external onlyOwner view returns (Node[] memory) {
      return usersNodes[user];
    }

    function _getNodeTypes() external onlyOwner view returns (NodeType[] memory) {
      return _nodeTypes;
    }

    function _getBoosterDatas(address user) external onlyOwner view returns (BoosterData memory) {
      require(boosterDatas[user].boosterCodeSetup, "Booster code not setup yet");
      return boosterDatas[user];
    }

    function _setMinimumNodeUseRef(uint256 nodeId) external onlyOwner {
      _minimumNodeUseRef = nodeId;
    }

    function _setMinimumNodeSetRef(uint256 nodeId) external onlyOwner {
      _minimumNodeSetRef = nodeId;
    }

    function _setMaxAmountPerNode(uint256 amount) external onlyOwner {
      _maxAmountPerNode = amount;
    }

    // Setters
    function _updateGasForProcessing(uint256 amount) external onlyOwner {
      require(amount >= 200000 && amount <= 500000, "gasForProcessing must be between 200,000 and 500,000");
      require(amount != _gasForProcessing, "Cannot update gasForProcessing to same value");

      emit GasForProcessingUpdated(amount, _gasForProcessing);

      _gasForProcessing = amount;
    }

    function _setClaimingTimestamp(uint256 amount) external onlyOwner {
      _claimingTimestamp = amount;
    }

    function _setMaxNodes(uint256 amount) external onlyOwner {
      _maxNodes = amount;
    }

    function _editNodeType(uint256 nodeTypeId, uint256 rewards, uint256 timeToUpgrade, uint256 typeUpgradeNode,
                           uint256 price, bool buyable, bool upgradable, bool bonus) external onlyOwner {
      require(nodeTypeId < _nodeTypes.length && nodeTypeId >= 0, "Not valid id of a type of Node");

      NodeType storage nodeType = _nodeTypes[nodeTypeId];

      nodeType.rewards = rewards;
      nodeType.timeToUpgrade = timeToUpgrade;
      nodeType.typeUpgradeNode = typeUpgradeNode;
      nodeType.price = price;
      nodeType.buyable = buyable;
      nodeType.upgradable = upgradable;
      nodeType.bonus = bonus;
    }

    function _addNodeType(uint256 rewards, uint256 timeToUpgrade, uint256 typeUpgradeNode,
                           uint256 price, bool buyable, bool upgradable, bool bonus) external onlyOwner {
      _nodeTypes.push(NodeType({
        rewards: rewards,
        timeToUpgrade: timeToUpgrade,
        typeUpgradeNode: typeUpgradeNode,
        price: price,
        buyable: buyable,
        upgradable: upgradable,
        disabled: false,
        bonus: bonus
      }));
    }

    function _disableNodeType(uint256 id) external onlyOwner {
      require(id < _nodeTypes.length && id >= 0, "Not valid id of a type of Node");

      _nodeTypes[id].disabled = true;
    }

    function _enableNodeType(uint256 id) external onlyOwner {
      require(id < _nodeTypes.length && id >= 0, "Not valid id of a type of Node");

      _nodeTypes[id].disabled = false;
    }

}