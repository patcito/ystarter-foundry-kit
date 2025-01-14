// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {VaultAPI} from "@yearnvaults/contracts/BaseStrategy.sol";

/********************
 *
 *   This contract is a POC as an example of a yearn V2 integration meant for instructive purposes.
 *   The donator assigns approves a token to Sugar Contract and can StartSharingYield with a receiver.
 *   The receiver can claim the donated yield that's "streamed" every time yield is realized in vault.
 *   The donator can stopSharingYield() any time and receiver won't be able to claim yield after this.
 *
 *
 *   // TODO: tokenized this into an NFT or two NFT one for donator and one for receiver keeping same IDs
 *   // TODO: add support for migrating yield source as admin. Require token matches
 ********************* */

contract SugarYvault is Ownable {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event StartShare(
        address indexed receiver,
        address indexed donator,
        uint256 amount
    );

    event StopShare(address indexed donator, uint256 amountReturned);

    event Claimed(
        address indexed receiver,
        address indexed donator,
        uint256 claimed,
        uint256 newShareAmount
    );

    /*//////////////////////////////////////////////////////////////
                         METADATA STORAGE/LOGIC
    //////////////////////////////////////////////////////////////*/
    VaultAPI public immutable vault;
    IERC20 public immutable token;
    mapping(address => uint256) public tokenBalances;
    mapping(address => uint256) public shareBalances;
    mapping(address => address) public donatorToReceiver;
    mapping(address => mapping(address => bool)) public receiverToDonator;
    uint256 public dust = 1e16;

    constructor(address _vault) {
        vault = VaultAPI(_vault);
        token = IERC20(vault.token());
        token.approve(address(vault), type(uint256).max);
    }

    function startSharingYield(address receiver, uint256 amount)
        public
        returns (uint256 shares)
    {
        require(receiver != address(0), "ADDRESS_NOT_ZERO");
        require(receiver != msg.sender, "SELF_SHARE");
        require(amount > 0, "AMT_NOT_ZERO");
        require(donatorToReceiver[msg.sender] == address(0), "DONATOR_NOT_SET");
        SafeERC20.safeTransferFrom(token, msg.sender, address(this), amount);
        shares = vault.deposit(amount);
        tokenBalances[msg.sender] += amount;
        shareBalances[msg.sender] += shares;
        // donator can only have one receiver for yield and can switch it here
        donatorToReceiver[msg.sender] = receiver;
        receiverToDonator[receiver][msg.sender] = true;

        emit StartShare(msg.sender, receiver, amount);
    }

    function stopSharingYield() public returns (uint256 amount) {
        uint256 _shares = shareBalances[msg.sender];
        uint256 _tokenBalance = tokenBalances[msg.sender];
        require(_shares > 0, "NO_SHARES");
        require(_tokenBalance > 0, "NO_TOKEN");

        shareBalances[msg.sender] = 0;
        tokenBalances[msg.sender] = 0;
        address _receiver = donatorToReceiver[msg.sender];
        donatorToReceiver[msg.sender] = address(0);
        receiverToDonator[_receiver][msg.sender] = false;

        amount = vault.withdraw(_shares, msg.sender);

        emit StopShare(msg.sender, amount);

        // TODO: add emergency exit to withdraw and realize loss in case it happens
        require(amount >= _tokenBalance, "LOSS");
    }

    function claimYield(address _donator) public returns (uint256 claimed) {
        require(donatorToReceiver[_donator] == msg.sender, "NOT_RECEIVER");
        // NOTE: checks in startSharingYield ensure these values are not zero
        uint256 _shares = shareBalances[_donator];
        uint256 _tokenBalance = tokenBalances[_donator];

        // NOTE: we add dust thresold to assure precision
        require(convertToAssets(_shares) > _tokenBalance + dust, "NO_YIELD");

        uint256 _remainingShares = convertToShares(_tokenBalance + dust);
        require(_shares > _remainingShares, "LOSS");

        uint256 _sharesToClaim = _shares - _remainingShares;

        shareBalances[_donator] = _remainingShares;

        claimed = vault.withdraw(_sharesToClaim, msg.sender);
        // NOTE: ensure donator still has deposited capital after side effect
        require(
            convertToAssets(_remainingShares) >= _tokenBalance,
            "CLAIM_EXCEED"
        );

        emit Claimed(msg.sender, _donator, claimed, _remainingShares);
    }

    function claimable(address _donator, address _receiver)
        external
        view
        returns (uint256 amount)
    {
        if (donatorToReceiver[_donator] != _receiver) return 0;

        // NOTE: checks in startSharingYield ensure these values are not zero
        uint256 _shares = shareBalances[_donator];
        uint256 _tokenBalance = tokenBalances[_donator];
        if (_shares == 0 || _tokenBalance == 0) return 0;

        // NOTE: we add dust thresold to assure precision
        if (convertToAssets(_shares) < _tokenBalance + dust) return 0;

        uint256 _remainingShares = convertToShares(_tokenBalance + dust);
        if (_shares <= _remainingShares) return 0;

        uint256 _sharesToClaim = _shares - _remainingShares;

        amount = convertToAssets(_sharesToClaim);
    }

    /*//////////////////////////////////////////////////////////////
                        HELPER METHODS
    //////////////////////////////////////////////////////////////*/

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return (shares * vault.pricePerShare()) / (10**vault.decimals());
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return (assets * (10**vault.decimals())) / vault.pricePerShare();
    }
}
