// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BarterBase Escrow Protocol
 * @notice Trustless P2P trading for tokens and NFTs on Base. Zero platform fees.
 */
interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface IERC721 {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

contract BarterBase {
    struct Trade {
        address maker;
        address taker;
        address tokenOffered; // 0 for ETH, ERC20 or ERC721 address
        uint256 amountOrIdOffered;
        address tokenWanted;
        uint256 amountOrIdWanted;
        bool isNFT;
        bool active;
    }

    mapping(uint256 => Trade) public trades;
    uint256 public tradeCounter;

    event TradeCreated(uint256 indexed tradeId, address indexed maker, address tokenOffered, uint256 amountOrIdOffered);
    event TradeAccepted(uint256 indexed tradeId, address indexed taker);
    event TradeCancelled(uint256 indexed tradeId);

    function createTrade(
        address _taker,
        address _tokenOffered,
        uint256 _amountOrIdOffered,
        address _tokenWanted,
        uint256 _amountOrIdWanted,
        bool _isNFT
    ) external payable returns (uint256) {
        uint256 tradeId = tradeCounter++;
        
        if (_isNFT) {
            IERC721(_tokenOffered).safeTransferFrom(msg.sender, address(this), _amountOrIdOffered);
        } else if (_tokenOffered == address(0)) {
            require(msg.value == _amountOrIdOffered, "ETH value mismatch");
        } else {
            IERC20(_tokenOffered).transferFrom(msg.sender, address(this), _amountOrIdOffered);
        }

        trades[tradeId] = Trade({
            maker: msg.sender,
            taker: _taker,
            tokenOffered: _tokenOffered,
            amountOrIdOffered: _amountOrIdOffered,
            tokenWanted: _tokenWanted,
            amountOrIdWanted: _amountOrIdWanted,
            isNFT: _isNFT,
            active: true
        });

        emit TradeCreated(tradeId, msg.sender, _tokenOffered, _amountOrIdOffered);
        return tradeId;
    }

    function acceptTrade(uint256 _tradeId) external payable {
        Trade storage trade = trades[_tradeId];
        require(trade.active, "Trade not active");
        require(trade.taker == address(0) || trade.taker == msg.sender, "Not authorized taker");

        trade.active = false;

        // Take asset from taker and send to maker
        if (trade.tokenWanted == address(0)) {
            require(msg.value == trade.amountOrIdWanted, "ETH value mismatch");
            payable(trade.maker).transfer(msg.value);
        } else {
            IERC20(trade.tokenWanted).transferFrom(msg.sender, trade.maker, trade.amountOrIdWanted);
        }

        // Send offered asset from escrow to taker
        if (trade.isNFT) {
            IERC721(trade.tokenOffered).safeTransferFrom(address(this), msg.sender, trade.amountOrIdOffered);
        } else if (trade.tokenOffered == address(0)) {
            payable(msg.sender).transfer(trade.amountOrIdOffered);
        } else {
            IERC20(trade.tokenOffered).transfer(msg.sender, trade.amountOrIdOffered);
        }

        emit TradeAccepted(_tradeId, msg.sender);
    }

    function cancelTrade(uint256 _tradeId) external {
        Trade storage trade = trades[_tradeId];
        require(trade.active, "Trade not active");
        require(trade.maker == msg.sender, "Not maker");

        trade.active = false;

        if (trade.isNFT) {
            IERC721(trade.tokenOffered).safeTransferFrom(address(this), msg.sender, trade.amountOrIdOffered);
        } else if (trade.tokenOffered == address(0)) {
            payable(msg.sender).transfer(trade.amountOrIdOffered);
        } else {
            IERC20(trade.tokenOffered).transfer(msg.sender, trade.amountOrIdOffered);
        }

        emit TradeCancelled(_tradeId);
    }

    // Required for ERC721 receiving
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
